"""Метрический масштаб фотограмметрии по позам ARKit — без эталона и без печати.

Зачем: SfM-реконструкция (COLMAP, RealityCapture) знает форму, но не размер — масштаб
у неё произвольный. ARKit же отдаёт позы камеры сразу в метрах (VIO + LiDAR), и
приложение пишет их в shots.json. Значит достаточно совместить две траектории:
облако центров камер COLMAP и центры камер ARKit. Совмещение подобием (Umeyama)
даёт ровно тот коэффициент, которого не хватает модели.

Почему это лучше печатного квадрата:
  - ничего не надо печатать и класть в кадр;
  - работает на обычном обходе объекта (кадры сняты с движущейся камеры);
  - ошибка порядка 1 % (столько даёт масштаб ARKit), а не «плюс-минус палец».

Ограничение: на поворотном столе камера стоит, а крутится предмет — траектории
совмещать нечем, там нужен эталон (линейка/карта/квадрат).

    python pc/scale_from_poses.py --model pc/out/recon/dataset/sparse/0-txt --shots scan/shots.json
    python pc/scale_from_poses.py --model ... --shots ... --json pc/out/scale.json
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import sys

import numpy as np

MIN_PAIRS = 6
SCALE_LIMITS = (0.05, 20.0)


def log(message: str = "") -> None:
    print(message, flush=True)


# ---------------------------------------------------------------- COLMAP TXT

def quat_to_rot(qw: float, qx: float, qy: float, qz: float) -> np.ndarray:
    norm = qw * qw + qx * qx + qy * qy + qz * qz
    if norm <= 0:
        return np.eye(3)
    s = 2.0 / norm
    return np.array([
        [1 - s * (qy * qy + qz * qz), s * (qx * qy - qz * qw), s * (qx * qz + qy * qw)],
        [s * (qx * qy + qz * qw), 1 - s * (qx * qx + qz * qz), s * (qy * qz - qx * qw)],
        [s * (qx * qz - qy * qw), s * (qy * qz + qx * qw), 1 - s * (qx * qx + qy * qy)],
    ])


def find_images_txt(model: str) -> str:
    if os.path.isfile(model):
        return model
    for candidate in ("images.txt", os.path.join("sparse", "0.txt", "images.txt")):
        path = os.path.join(model, candidate)
        if os.path.isfile(path):
            return path
    raise SystemExit(f"images.txt not found in {model}")


def read_images_txt(path: str) -> dict[str, np.ndarray]:
    """Центры камер COLMAP: C = -R^T * t."""
    centers: dict[str, np.ndarray] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 10:
                continue
            name = parts[9]
            if not name.lower().endswith((".jpg", ".jpeg", ".png")):
                continue
            try:
                qw, qx, qy, qz = (float(v) for v in parts[1:5])
                tx, ty, tz = (float(v) for v in parts[5:8])
            except ValueError:
                continue
            rot = quat_to_rot(qw, qx, qy, qz)
            centers[name] = -rot.T @ np.array([tx, ty, tz], dtype=float)
    return centers


# ---------------------------------------------------------------- ARKit shots

def read_arkit_shots(path: str) -> dict[str, np.ndarray]:
    """Центры камер ARKit из shots.json. Поза записана по столбцам (column-major)."""
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    shots = data.get("shots", data) if isinstance(data, dict) else data
    centers: dict[str, np.ndarray] = {}
    for shot in shots or []:
        if not isinstance(shot, dict):
            continue
        name = shot.get("file")
        pose = shot.get("transform")
        if not name or not isinstance(pose, list) or len(pose) != 16:
            continue
        centers[name] = np.array([pose[12], pose[13], pose[14]], dtype=float)
    return centers


# ---------------------------------------------------------------- Umeyama

def umeyama(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    """Подобие dst ≈ s*R*src + t по методу Umeyama. Возвращает (s, R, t)."""
    if src.shape[0] < 3:
        raise ValueError("need at least 3 point pairs")
    mu_src = src.mean(axis=0)
    mu_dst = dst.mean(axis=0)
    src_c = src - mu_src
    dst_c = dst - mu_dst
    var_src = float((src_c ** 2).sum() / src.shape[0])
    if var_src <= 1e-12:
        raise ValueError("source points are degenerate")
    cov = dst_c.T @ src_c / src.shape[0]
    u, d, vt = np.linalg.svd(cov)
    sign = np.eye(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        sign[2, 2] = -1
    rot = u @ sign @ vt
    scale = float((d * np.diag(sign)).sum() / var_src)
    trans = mu_dst - scale * rot @ mu_src
    return scale, rot, trans


def residual(src: np.ndarray, dst: np.ndarray, scale: float, rot: np.ndarray,
             trans: np.ndarray) -> np.ndarray:
    predicted = (scale * (rot @ src.T)).T + trans
    return np.linalg.norm(predicted - dst, axis=1)


def robust_scale(pairs: list[tuple[str, np.ndarray, np.ndarray]],
                 threshold: float = 0.0, rounds: int = 4) -> dict:
    """Umeyama с RANSAC: COLMAP иногда теряет кадр и ставит его не туда.

    Метод наименьших квадратов на такой паре «уезжает» целиком, поэтому сначала
    перебираем тройки камер и ищем подобие, которое согласуется с большинством,
    затем уточняем по инлайерам.
    """
    names = [name for name, _s, _d in pairs]
    src = np.array([s for _n, s, _d in pairs], dtype=float)
    dst = np.array([d for _n, _s, d in pairs], dtype=float)
    count = len(pairs)

    if threshold <= 0:
        # Порог в метрах: 2 % разброса траектории, но не меньше 5 мм.
        spread = float(np.median(np.linalg.norm(dst - dst.mean(axis=0), axis=1)))
        threshold = max(0.005, 0.02 * spread)

    if count <= 30:
        combos = list(itertools.combinations(range(count), 3))
    else:
        rng = np.random.default_rng(20261029)
        combos = [tuple(rng.choice(count, size=3, replace=False)) for _ in range(2000)]

    best_mask = None
    best_residual = None
    for combo in combos:
        index = list(combo)
        try:
            scale, rot, trans = umeyama(src[index], dst[index])
        except (ValueError, np.linalg.LinAlgError):
            continue
        if not (SCALE_LIMITS[0] <= scale <= SCALE_LIMITS[1]):
            continue
        resid = residual(src, dst, scale, rot, trans)
        mask = resid <= threshold
        if mask.sum() < 3:
            continue
        score = (int(mask.sum()), -float(np.median(resid[mask])))
        if best_mask is None or score > best_mask[0]:
            best_mask = (score, mask, resid)

    if best_mask is None:
        raise ValueError("no consistent similarity found (poses do not match the model)")

    keep = best_mask[1]
    # Уточняем на инлайерах, пока состав не перестанет меняться.
    for _ in range(rounds):
        if keep.sum() < 3:
            raise ValueError("too many outliers")
        scale, rot, trans = umeyama(src[keep], dst[keep])
        resid = residual(src, dst, scale, rot, trans)
        median = float(np.median(resid[keep]))
        mad = float(np.median(np.abs(resid[keep] - median)))
        limit = min(max(median + 4.0 * mad, threshold * 0.5), threshold * 4)
        updated = resid <= limit
        if np.array_equal(updated, keep):
            break
        keep = updated

    inliers = [names[i] for i in range(count) if keep[i]]
    return {
        "scale": float(scale),
        "rotation": rot.round(6).tolist(),
        "translation": trans.round(6).tolist(),
        "threshold_m": round(float(threshold), 6),
        "pairs": count,
        "inliers": len(inliers),
        "inlier_names": inliers,
        "median_residual_m": float(np.median(resid[keep])) if keep.any() else None,
        "max_residual_m": float(resid[keep].max()) if keep.any() else None,
    }


def collect_pairs(colmap_centers: dict[str, np.ndarray],
                  arkit_centers: dict[str, np.ndarray]) -> list[tuple[str, np.ndarray, np.ndarray]]:
    pairs = []
    for name, dst in arkit_centers.items():
        src = colmap_centers.get(name)
        if src is None:
            src = colmap_centers.get(os.path.basename(name))
        if src is None:
            continue
        pairs.append((name, src, dst))
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description="Scale a COLMAP model from ARKit poses")
    parser.add_argument("--model", required=True, help="папка с images.txt или сам images.txt")
    parser.add_argument("--shots", required=True, help="shots.json из приложения (вкладка «Скан»)")
    parser.add_argument("--min-pairs", type=int, default=MIN_PAIRS)
    parser.add_argument("--json", default="", help="куда записать результат")
    args = parser.parse_args()

    images = read_images_txt(find_images_txt(args.model))
    shots = read_arkit_shots(args.shots)
    log(f"COLMAP cameras: {len(images)}, ARKit poses: {len(shots)}")

    pairs = collect_pairs(images, shots)
    log(f"matched: {len(pairs)}")
    if len(pairs) < args.min_pairs:
        log(f"Need at least {args.min_pairs} matched cameras. "
            "Симптом: кадры сняты на поворотном столе (камера стоит) или shots.json без transform.")
        return 2

    try:
        result = robust_scale(pairs)
    except ValueError as exc:
        log(f"Scale failed: {exc}")
        return 1

    scale = result["scale"]
    log(f"Scale: x{scale:.5f}  (inliers {result['inliers']}/{result['pairs']})")
    if not (SCALE_LIMITS[0] <= scale <= SCALE_LIMITS[1]):
        log("Scale looks implausible: check that shots.json and the reconstruction "
            "belong to the same capture.")
        return 1
    if result["median_residual_m"] is not None:
        log(f"Residual: median {result['median_residual_m'] * 1000:.1f} mm, "
            f"max {result['max_residual_m'] * 1000:.1f} mm")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        log(f"Saved: {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
