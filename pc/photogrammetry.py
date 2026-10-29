"""COLMAP-пайплайн для снимков ScanLab (вкладка «Профи-фото»).

Вход: папка или ZIP с img_XXX.jpg (и, если есть, shots.json с выдержкой/ISO/секторами).
Выход: <work>/dataset/dense/meshed-poisson.ply + отчёт измерения.

    python pc/photogrammetry.py ScanLab.zip
    python pc/photogrammetry.py ScanLab.zip --dry-run          # только показать команды
    python pc/photogrammetry.py ScanLab.zip --fit-mm 42 --fit-axis y

COLMAP нужен отдельно: https://github.com/colmap/colmap/releases (сборка с CUDA).
RealityCapture точнее и быстрее на 5080 — этот скрипт для тех, кто хочет только
открытый софт или повторить результат через год.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE_EXT = (".jpg", ".jpeg", ".png")


def log(message: str = "") -> None:
    print(message, flush=True)


def count_images(folder: str) -> int:
    if not os.path.isdir(folder):
        return 0
    return sum(1 for name in os.listdir(folder) if name.lower().endswith(IMAGE_EXT))


def link_or_copy(src: str, dst: str, use_link: bool = True) -> None:
    """Junction на NTFS не требует прав администратора; если не вышло — копируем."""
    if os.path.lexists(dst):
        if os.path.isdir(dst) and count_images(dst) > 0:
            return
        try:
            os.rmdir(dst)  # junction или пустая папка: снимается без удаления цели
        except OSError:
            shutil.rmtree(dst, ignore_errors=True)

    if use_link:
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", os.path.abspath(dst), os.path.abspath(src)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and os.path.isdir(dst):
            return
    shutil.copytree(src, dst)


def run_step(cmd: list[str], dry_run: bool) -> int:
    log("  $ " + " ".join(cmd))
    if dry_run:
        return 0
    started = time.time()
    proc = subprocess.run(
        cmd, capture_output=True, text=True, errors="replace"
    )
    log(f"    -> exit {proc.returncode} in {time.time() - started:.1f}s")
    if proc.returncode != 0:
        tail = (proc.stdout or "")[-1500:] + (proc.stderr or "")[-1500:]
        sys.stderr.write(tail + "\n")
    return proc.returncode


def build_steps(colmap: str, dataset: str, max_image_size: int) -> list[tuple]:
    db = os.path.join(dataset, "database.db")
    images = os.path.join(dataset, "images")
    sparse = os.path.join(dataset, "sparse")
    dense = os.path.join(dataset, "dense")
    return [
        (
            "features",
            None,
            [
                colmap, "feature_extractor",
                "--database_path", db,
                "--image_path", images,
                "--ImageReader.single_camera", "1",
                "--ImageReader.camera_model", "OPENCV",
            ],
        ),
        ("matching", None, [colmap, "exhaustive_matcher", "--database_path", db]),
        (
            "mapping",
            os.path.join(sparse, "0", "cameras.bin"),
            [
                colmap, "mapper",
                "--database_path", db,
                "--image_path", images,
                "--output_path", sparse,
            ],
        ),
        (
            # Текстовый экспорт нужен, чтобы прочитать центры камер для масштаба по ARKit
            # (scale_from_poses.py бинарный формат не разбирает).
            "model_txt",
            os.path.join(sparse, "0-txt", "images.txt"),
            [
                colmap, "model_converter",
                "--input_path", os.path.join(sparse, "0"),
                "--output_path", os.path.join(sparse, "0-txt"),
                "--output_type", "TXT",
            ],
        ),
        (
            "undistort",
            os.path.join(dense, "images"),
            [
                colmap, "image_undistorter",
                "--image_path", images,
                "--input_path", os.path.join(sparse, "0"),
                "--output_path", dense,
                "--output_type", "COLMAP",
                "--max_image_size", str(max_image_size),
            ],
        ),
        (
            "stereo",
            os.path.join(dense, "stereo", "depth_maps"),
            [
                colmap, "patch_match_stereo",
                "--workspace_path", dense,
                "--workspace_format", "COLMAP",
                "--PatchMatchStereo.geom_consistency", "true",
            ],
        ),
        (
            "fusion",
            os.path.join(dense, "fused.ply"),
            [
                colmap, "stereo_fusion",
                "--workspace_path", dense,
                "--workspace_format", "COLMAP",
                "--input_type", "geometric",
                "--output_path", os.path.join(dense, "fused.ply"),
            ],
        ),
        (
            "meshing",
            os.path.join(dense, "meshed-poisson.ply"),
            [
                colmap, "poisson_mesher",
                "--input_path", os.path.join(dense, "fused.ply"),
                "--output_path", os.path.join(dense, "meshed-poisson.ply"),
            ],
        ),
    ]


def prepare_dataset(source: str, dataset: str, tmp_holder: list) -> str:
    """Раскладывает снимки в <dataset>/images и возвращает путь к папке кадров."""
    from_zip = False
    if os.path.isfile(source) and source.lower().endswith(".zip"):
        tmp = tempfile.mkdtemp(prefix="scanlab-photo-")
        tmp_holder.append(tmp)
        with zipfile.ZipFile(source) as archive:
            archive.extractall(tmp)
        source = tmp
        from_zip = True

    if os.path.isfile(source):
        source = os.path.dirname(os.path.abspath(source)) or "."

    nested = os.path.join(source, "images")
    frames = nested if count_images(nested) else source
    total = count_images(frames)
    if total < 3:
        raise SystemExit(f"Need at least 3 images, found {total} in {frames}")

    os.makedirs(dataset, exist_ok=True)
    link_or_copy(frames, os.path.join(dataset, "images"), use_link=not from_zip)

    shots = os.path.join(frames, "shots.json")
    if os.path.isfile(shots):
        shutil.copy2(shots, os.path.join(dataset, "shots.json"))
    return frames


def describe_shots(dataset: str) -> dict:
    path = os.path.join(dataset, "shots.json")
    if not os.path.isfile(path):
        return {"shots_json": False}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            shots = json.load(handle)
    except (OSError, ValueError) as exc:
        return {"shots_json": False, "error": str(exc)}
    if isinstance(shots, dict):
        shots = shots.get("shots", [])
    sectors = sorted({int(s["sector"]) for s in shots if isinstance(s, dict) and "sector" in s})
    return {
        "shots_json": True,
        "shots": len(shots),
        "sectors_covered": len(sectors),
        "turntable": bool(sectors),
    }


def resolve_scale(args, dataset: str, frames: str, info: dict) -> float:
    """Масштаб реконструкции: глубина LiDAR точнее поз, поэтому она первая."""
    if args.scale > 0:
        info["scale"] = {"value": args.scale, "source": "cli"}
        return args.scale

    model_dir = os.path.join(dataset, "sparse", "0-txt")
    if not os.path.isdir(model_dir):
        return 1.0

    if not args.no_scale_from_depth:
        try:
            import scale_from_depth as sfd

            result = sfd.estimate_scale(model_dir, frames)
            scale = float(result["scale"])
            if sfd.SCALE_LIMITS[0] <= scale <= sfd.SCALE_LIMITS[1]:
                info["scale"] = {
                    "value": round(scale, 6),
                    "source": "depth",
                    "pairs": result["pairs"],
                    "inliers": result["inliers"],
                    "median_residual_mm": round(result["median_residual_mm"], 3),
                }
                log(f"[scale] x{scale:.5f} from LiDAR depth "
                    f"(inliers {result['inliers']}/{result['pairs']}, "
                    f"residual {result['median_residual_mm']:.2f} mm)")
                return scale
            log(f"[scale] depth gave implausible x{scale:.4f}, trying poses")
        except Exception as exc:  # noqa: BLE001 — пайплайн не должен падать из-за масштаба
            log(f"[scale] depth not used: {exc}")

    if args.no_scale_from_poses:
        return 1.0

    shots = os.path.join(dataset, "shots.json")
    if not (os.path.isfile(shots) and os.path.isdir(model_dir)):
        return 1.0

    try:
        import scale_from_poses as sfp

        images = sfp.read_images_txt(sfp.find_images_txt(model_dir))
        poses = sfp.read_arkit_shots(shots)
        pairs = sfp.collect_pairs(images, poses)
        if len(pairs) < sfp.MIN_PAIRS:
            log(f"[scale] matched cameras: {len(pairs)} < {sfp.MIN_PAIRS}, scale untouched")
            log("        (поворотный стол? камера стоит — совмещать траектории нечем)")
            return 1.0
        result = sfp.robust_scale(pairs)
    except Exception as exc:  # noqa: BLE001 — пайплайн не должен падать из-за масштаба
        log(f"[scale] failed: {exc}")
        return 1.0

    scale = float(result["scale"])
    if not (sfp.SCALE_LIMITS[0] <= scale <= sfp.SCALE_LIMITS[1]):
        log(f"[scale] implausible x{scale:.4f}, ignored")
        return 1.0

    info["scale"] = {
        "value": round(scale, 6),
        "source": "arkit-poses",
        "pairs": result["pairs"],
        "inliers": result["inliers"],
        "median_residual_m": result["median_residual_m"],
    }
    log(f"[scale] x{scale:.5f} from ARKit poses "
        f"(inliers {result['inliers']}/{result['pairs']})")
    return scale


def main() -> int:
    parser = argparse.ArgumentParser(description="COLMAP-пайплайн для снимков ScanLab")
    parser.add_argument("input", help="ZIP или папка с img_*.jpg из вкладки «Профи-фото»")
    parser.add_argument("--work", default="pc/out/recon", help="рабочая папка пайплайна")
    parser.add_argument("--colmap", default="colmap", help="путь к colmap.exe")
    parser.add_argument("--max-image-size", type=int, default=2000,
                        help="до какого размера ужимать кадры перед MVS (2000 — быстро, 3200 — детально)")
    parser.add_argument("--fit-mm", type=float, default=0.0,
                        help="подогнать масштаб после реконструкции (мм по оси --fit-axis)")
    parser.add_argument("--fit-axis", choices=("x", "y", "z"), default="y")
    parser.add_argument("--scale", type=float, default=0.0,
                        help="готовый коэффициент масштаба (перебивает расчёт по позам ARKit)")
    parser.add_argument("--no-scale-from-poses", action="store_true",
                        help="не восстанавливать масштаб по позам ARKit (нужно для поворотного стола)")
    parser.add_argument("--no-scale-from-depth", action="store_true",
                        help="не использовать глубину LiDAR для масштаба (например, кадры без depth-файлов)")
    parser.add_argument("--no-measure", action="store_true", help="не запускать measure.py в конце")
    parser.add_argument("--dry-run", action="store_true", help="только напечатать команды")
    args = parser.parse_args()

    if not args.dry_run and shutil.which(args.colmap) is None:
        log(f"COLMAP not found: {args.colmap}")
        log("Install a CUDA build from https://github.com/colmap/colmap/releases,")
        log("then: python pc/photogrammetry.py <input> --colmap C:\\Tools\\COLMAP\\colmap.exe")
        log("RealityCapture (pc/PIPELINE.md) does the same faster on your 5080.")
        return 2

    dataset = os.path.join(args.work, "dataset")
    holder: list = []
    try:
        frames = prepare_dataset(args.input, dataset, holder)
        info = {"images": count_images(os.path.join(dataset, "images"))}
        info.update(describe_shots(dataset))
        log(f"Images: {info['images']} from {frames}")
        if info.get("shots_json"):
            log(f"shots.json: {info['shots']} shots, sectors {info['sectors_covered']}")

        steps = build_steps(args.colmap, dataset, args.max_image_size)
        for name, marker, cmd in steps:
            done = marker is not None and os.path.exists(marker)
            log(f"[{name}] {'skip (done)' if done else 'run'}")
            if not done and run_step(cmd, args.dry_run) != 0:
                log(f"Step '{name}' failed. Fix the cause; re-run resumes from here.")
                return 1
            if args.dry_run:
                os.makedirs(dataset, exist_ok=True)

        mesh = os.path.join(dataset, "dense", "meshed-poisson.ply")
        log(f"Mesh: {mesh}")

        scale = 1.0
        if not args.dry_run:
            scale = resolve_scale(args, dataset, frames, info)
        if args.fit_mm > 0 and not args.dry_run:
            info["fit"] = {"mm": args.fit_mm, "axis": args.fit_axis}
        if not args.no_measure and not args.dry_run:
            measure = [sys.executable, os.path.join(HERE, "measure.py"), mesh,
                       "--out", os.path.join(args.work, "measure")]
            if scale != 1.0:
                measure += ["--scale", f"{scale:.6f}"]
            if args.fit_mm > 0:
                measure += ["--fit-mm", str(args.fit_mm), "--fit-axis", args.fit_axis]
            log("[measure]")
            if run_step(measure, False) != 0:
                log("measure.py failed (open3d missing for .ply?). pip install -r pc/requirements.txt")
                return 1

        if not args.dry_run:
            with open(os.path.join(args.work, "recon.json"), "w", encoding="utf-8") as handle:
                json.dump(info, handle, ensure_ascii=False, indent=2)
        log("Done." if not args.dry_run else "Dry run finished, nothing executed.")
        return 0
    finally:
        for tmp in holder:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
