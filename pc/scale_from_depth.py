"""Масштаб реконструкции по карте глубины LiDAR.

Зачем: COLMAP восстанавливает сцену в произвольных единицах, но вкладка
«Профи-фото» пишет рядом с каждым кадром сырую глубину LiDAR — уже в метрах.
Для каждой 3D-точки COLMAP, видимой в кадре с глубиной, сравниваем её z в
камере (единицы SfM) с глубиной в этом же пикселе (метры): отношение и есть
коэффициент перевода.

Это работает и на поворотном столе, где камера стоит неподвижно и совмещать
траектории нечем. Ограничение: iPhone 15 Pro Max пишет глубину только с
LiDAR-камеры (до ~5 м), поэтому кадры снимков должны быть с расстояния
меньше этого, а точки — попадать в предмет, а не в фон.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

MIN_PAIRS = 20
SCALE_LIMITS = (0.02, 50.0)
MAX_DEPTH_M = 8.0
MIN_DEPTH_M = 0.05


class Camera:
    __slots__ = ("fx", "fy", "cx", "cy", "k1", "k2", "p1", "p2", "width", "height")

    def __init__(self, fx, fy, cx, cy, k1=0.0, k2=0.0, p1=0.0, p2=0.0, width=0, height=0):
        self.fx, self.fy, self.cx, self.cy = fx, fy, cx, cy
        self.k1, self.k2, self.p1, self.p2 = k1, k2, p1, p2
        self.width, self.height = width, height

    def project(self, x: float, y: float, z: float) -> tuple[float, float]:
        """Точка в камере -> пиксель, с учётом радиальной и тангенциальной дисторсии."""
        xn, yn = x / z, y / z
        r2 = xn * xn + yn * yn
        radial = 1.0 + self.k1 * r2 + self.k2 * r2 * r2
        xd = xn * radial + 2.0 * self.p1 * xn * yn + self.p2 * (r2 + 2.0 * xn * xn)
        yd = yn * radial + 2.0 * self.p2 * xn * yn + self.p1 * (r2 + 2.0 * yn * yn)
        return self.fx * xd + self.cx, self.fy * yd + self.cy


def read_cameras_txt(path: str) -> dict[int, Camera]:
    cameras: dict[int, Camera] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            camera_id, model, width, height = int(parts[0]), parts[1], int(parts[2]), int(parts[3])
            params = [float(value) for value in parts[4:]]
            if model in ("SIMPLE_PINHOLE",):
                fx = fy = params[0]
                cx, cy = params[1], params[2]
            elif model in ("PINHOLE",):
                fx, fy, cx, cy = params[0], params[1], params[2], params[3]
            elif model in ("SIMPLE_RADIAL",):
                fx = fy = params[0]
                cx, cy = params[1], params[2]
            elif model in ("RADIAL",):
                fx = fy = params[0]
                cx, cy = params[1], params[2]
            elif model in ("OPENCV", "OPENCV_FISHEYE", "FULL_OPENCV"):
                fx, fy, cx, cy = params[0], params[1], params[2], params[3]
            else:
                # Незнакомая модель: берём первые четыре параметра как fx, fy, cx, cy.
                fx, fy, cx, cy = params[0], params[1], params[2], params[3]
            k1 = params[3] if model == "RADIAL" else (params[4] if len(params) > 4 else 0.0)
            k2 = params[4] if model == "RADIAL" else (params[5] if len(params) > 5 else 0.0)
            p1 = params[6] if len(params) > 6 else 0.0
            p2 = params[7] if len(params) > 7 else 0.0
            if model in ("SIMPLE_PINHOLE", "PINHOLE", "SIMPLE_RADIAL", "OPENCV", "OPENCV_FISHEYE"):
                k1, k2, p1, p2 = (0.0, 0.0, 0.0, 0.0) if model in ("SIMPLE_PINHOLE", "PINHOLE") else (
                    params[4] if len(params) > 4 else 0.0,
                    params[5] if len(params) > 5 else 0.0,
                    params[6] if len(params) > 6 else 0.0,
                    params[7] if len(params) > 7 else 0.0,
                )
            cameras[camera_id] = Camera(fx, fy, cx, cy, k1, k2, p1, p2, width, height)
    return cameras


def quat_to_rot(q: np.ndarray) -> np.ndarray:
    w, x, y, z = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ])


def read_images_txt(path: str) -> dict[int, dict]:
    """id -> {name, camera_id, R, t}; строки с точками (2D) пропускаем."""
    images: dict[int, dict] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 10:
                continue  # это строка с 2D-точками (POINTS2D)
            image_id = int(parts[0])
            qvec = np.array([float(value) for value in parts[1:5]])
            tvec = np.array([float(value) for value in parts[5:8]])
            images[image_id] = {
                "name": parts[9],
                "camera_id": int(parts[8]),
                "R": quat_to_rot(qvec),
                "t": tvec,
            }
    return images


def read_points3D_txt(path: str) -> list[dict]:
    points: list[dict] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            xyz = np.array([float(parts[1]), float(parts[2]), float(parts[3])])
            track = []
            rest = parts[8:]
            for index in range(0, len(rest) - 1, 2):
                track.append((int(rest[index]), int(rest[index + 1])))
            points.append({"xyz": xyz, "track": track})
    return points


def load_shots(path: str) -> dict[str, dict]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("shots", [])
    shots = {}
    for shot in data:
        if not isinstance(shot, dict) or "file" not in shot:
            continue
        shots[shot["file"]] = shot
    return shots


def read_depth(folder: str, name: str, size: list[int]) -> np.ndarray | None:
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        return None
    values = np.fromfile(path, dtype="<f4")
    width, height = int(size[0]), int(size[1])
    if values.size != width * height:
        return None
    return values.reshape((height, width))


def sample_depth(depth: np.ndarray, u: float, v: float) -> float | None:
    """Медиана 3x3 вокруг пикселя: одиночные дыры LiDAR не должны решать масштаб."""
    height, width = depth.shape
    x = int(round(u))
    y = int(round(v))
    if x < 1 or y < 1 or x >= width - 1 or y >= height - 1:
        return None
    patch = depth[y - 1:y + 2, x - 1:x + 2].reshape(-1)
    patch = patch[np.isfinite(patch)]
    patch = patch[(patch > MIN_DEPTH_M) & (patch < MAX_DEPTH_M)]
    if patch.size < 4:
        return None
    return float(np.median(patch))


def collect_ratios(model_dir: str, shots_dir: str) -> list[tuple[float, float]]:
    """Пары (глубина_м, z_в_камере_в_единицах_SfM) по всем наблюдаемым точкам."""
    cameras = read_cameras_txt(os.path.join(model_dir, "cameras.txt"))
    images = read_images_txt(os.path.join(model_dir, "images.txt"))
    points = read_points3D_txt(os.path.join(model_dir, "points3D.txt"))
    shots = load_shots(os.path.join(shots_dir, "shots.json"))

    depth_cache: dict[int, tuple[np.ndarray, Camera]] = {}
    by_name = {item["name"]: image_id for image_id, item in images.items()}

    def depth_for(image_id: int):
        if image_id in depth_cache:
            return depth_cache[image_id]
        entry = images.get(image_id)
        camera = cameras.get(entry["camera_id"]) if entry else None
        shot = shots.get(entry["name"]) if entry else None
        if entry is None or camera is None or shot is None:
            depth_cache[image_id] = (None, None)  # type: ignore[assignment]
            return depth_cache[image_id]
        depth_file = shot.get("depthFile")
        size = shot.get("depthSize")
        if not depth_file or not size:
            depth_cache[image_id] = (None, None)  # type: ignore[assignment]
            return depth_cache[image_id]
        depth = read_depth(shots_dir, depth_file, size)
        depth_cache[image_id] = (depth, camera)  # type: ignore[assignment]
        return depth_cache[image_id]

    ratios: list[tuple[float, float]] = []
    for point in points:
        for image_id, _point2d in point["track"]:
            entry = images.get(image_id)
            if entry is None:
                continue
            depth, camera = depth_for(image_id)
            if depth is None or camera is None:
                continue
            camera_point = entry["R"] @ point["xyz"] + entry["t"]
            z = float(camera_point[2])
            if not np.isfinite(z) or z <= MIN_DEPTH_M:
                continue
            u, v = camera.project(float(camera_point[0]), float(camera_point[1]), z)
            # Глубина LiDAR может быть другого разрешения, чем кадр.
            sx = depth.shape[1] / float(camera.width or depth.shape[1])
            sy = depth.shape[0] / float(camera.height or depth.shape[0])
            metric = sample_depth(depth, u * sx, v * sy)
            if metric is None:
                continue
            ratios.append((metric, z))
        # Одна точка на камеру — достаточно: глубины независимы.
    return ratios


def robust_scale(ratios: list[tuple[float, float]], rounds: int = 4, tolerance: float = 0.02) -> dict:
    """Мода отношений, а не медиана.

    Часть точек COLMAP проецируется в пиксели, где глубина принадлежит другой
    поверхности (перекрытие, край предмета) — их отношение занижено. Если таких
    больше половины, медиана уезжает; поэтому ищем самый населённый кластер
    отношений в логарифмическом масштабе, а затем уточняем по нему.
    """
    if len(ratios) < MIN_PAIRS:
        raise ValueError(f"only {len(ratios)} depth samples, need {MIN_PAIRS}")

    depth = np.array([item[0] for item in ratios], dtype=float)
    zs = np.array([item[1] for item in ratios], dtype=float)
    valid = np.isfinite(depth) & np.isfinite(zs) & (zs > 0) & (depth > 0)
    depth, zs = depth[valid], zs[valid]
    if depth.size < MIN_PAIRS:
        raise ValueError(f"only {depth.size} usable depth samples, need {MIN_PAIRS}")

    ratios_all = depth / zs
    logs = np.log10(ratios_all)
    span = float(np.ptp(logs))
    bins = max(8, min(400, int(round(depth.size / 3))))
    if span < 1e-6:
        scale = float(np.median(ratios_all))
    else:
        counts, edges = np.histogram(logs, bins=bins)
        peak = int(np.argmax(counts))
        centre = 0.5 * (edges[peak] + edges[peak + 1])
        width = edges[1] - edges[0]
        near = np.abs(logs - centre) <= 2.0 * width
        scale = float(np.median(ratios_all[near]))

    keep = np.ones(depth.size, dtype=bool)
    for _ in range(rounds):
        resid = np.abs(depth - scale * zs)
        relative = np.abs(ratios_all / scale - 1.0)
        updated = (relative <= tolerance) & (resid <= max(0.01, 0.02 * float(np.median(depth[keep]))))
        if updated.sum() < MIN_PAIRS:
            break
        if np.array_equal(updated, keep):
            break
        keep = updated
        scale = float(np.median(ratios_all[keep]))

    resid = np.abs(depth - scale * zs)
    return {
        "scale": scale,
        "pairs": int(depth.size),
        "inliers": int(keep.sum()),
        "median_residual_mm": float(np.median(resid[keep]) * 1000.0),
        "max_residual_mm": float(resid[keep].max() * 1000.0),
        "spread_ratio": float(np.median(ratios_all) / scale) if scale else None,
        "source": "depth",
    }


def estimate_scale(model_dir: str, shots_dir: str) -> dict:
    ratios = collect_ratios(model_dir, shots_dir)
    result = robust_scale(ratios)
    if not (SCALE_LIMITS[0] <= result["scale"] <= SCALE_LIMITS[1]):
        raise ValueError(f"implausible scale x{result['scale']:.4f}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Масштаб реконструкции по глубине LiDAR")
    parser.add_argument("--model", required=True, help="папка sparse/0-txt (cameras.txt, images.txt, points3D.txt)")
    parser.add_argument("--shots", required=True, help="папка скана с shots.json и *_depth.f32")
    parser.add_argument("--json", action="store_true", help="вывести результат в JSON")
    args = parser.parse_args()

    try:
        result = estimate_scale(args.model, args.shots)
    except Exception as exc:  # noqa: BLE001
        print(f"failed: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"scale:      x{result['scale']:.6f}")
        print(f"samples:    {result['inliers']}/{result['pairs']}")
        print(f"residual:   {result['median_residual_mm']:.2f} mm (median)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
