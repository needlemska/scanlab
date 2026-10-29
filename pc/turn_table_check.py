"""Проверка поворотного стола по реконструкции: шаг и ось.

Зачем: на столе камера стоит, объект вращается — значит относительные повороты
камер в реконструкции должны равняться записанному шагу (yawDeg/sector в
shots.json), а все оси поворота — совпадать.

Что даёт: ловит сбитый счётчик секторов, случайные кадры «между шагами» и
съёмку с рук под видом стола. Абсолютный масштаб отсюда не берётся — для него
нужны глубина LiDAR или позы ARKit (pc/scale_from_depth.py, pc/scale_from_poses.py).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np

MAX_STEP_ERROR_DEG = 3.0
MAX_AXIS_SPREAD_DEG = 10.0
MAX_RADIUS_SPREAD = 0.10  # разброс радиуса окружности камер (информативно)


def quat_to_rot(q: np.ndarray) -> np.ndarray:
    w, x, y, z = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ])


def read_model(model_dir: str) -> list[dict]:
    images: list[dict] = []
    with open(os.path.join(model_dir, "images.txt"), "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 10:
                continue
            qvec = np.array([float(value) for value in parts[1:5]])
            tvec = np.array([float(value) for value in parts[5:8]])
            R = quat_to_rot(qvec)
            images.append({
                "id": int(parts[0]),
                "name": parts[9],
                "R": R,
                "center": -R.T @ tvec,
            })
    return images


def load_shots(shots_dir: str) -> dict[str, dict]:
    path = os.path.join(shots_dir, "shots.json")
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("shots", [])
    return {shot["file"]: shot for shot in data if isinstance(shot, dict) and "file" in shot}


def rotation_angle_deg(R: np.ndarray) -> float:
    trace = float(np.clip((np.trace(R) - 1.0) / 2.0, -1.0, 1.0))
    return math.degrees(math.acos(trace))


def rotation_axis(R: np.ndarray) -> np.ndarray | None:
    axis = np.array([R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]])
    norm = float(np.linalg.norm(axis))
    if norm < 1e-8:
        return None
    return axis / norm


def angle_between(a: np.ndarray, b: np.ndarray) -> float:
    value = float(np.clip(abs(float(a @ b)), -1.0, 1.0))
    return math.degrees(math.acos(value))


def analyze(model_dir: str, shots_dir: str) -> dict:
    images = read_model(model_dir)
    shots = load_shots(shots_dir)
    if len(images) < 2:
        raise ValueError("need at least 2 registered cameras")

    with_yaw = [image for image in images if "yawDeg" in shots.get(image["name"], {})]
    if len(with_yaw) < 2:
        raise ValueError("turntable mode was off: no yawDeg in shots.json")

    with_yaw.sort(key=lambda image: float(shots[image["name"]]["yawDeg"]))

    errors: list[float] = []
    axes: list[np.ndarray] = []
    handled: list[dict] = []
    for previous, current in zip(with_yaw, with_yaw[1:]):
        yaw_before = float(shots[previous["name"]]["yawDeg"])
        yaw_after = float(shots[current["name"]]["yawDeg"])
        step = abs(yaw_after - yaw_before) % 360.0
        step = min(step, 360.0 - step)
        relative = current["R"] @ previous["R"].T
        measured = rotation_angle_deg(relative)
        axis = rotation_axis(relative)
        if axis is not None:
            axes.append(axis)
        errors.append(abs(measured - step))
        handled.append({
            "from": previous["name"],
            "to": current["name"],
            "step_deg": round(step, 3),
            "measured_deg": round(measured, 3),
            "error_deg": round(abs(measured - step), 3),
        })

    result: dict = {
        "pairs": len(errors),
        "median_step_error_deg": round(float(np.median(errors)), 3),
        "max_step_error_deg": round(float(np.max(errors)), 3),
        "median_step_deg": round(float(np.median([item["step_deg"] for item in handled])), 3),
    }

    if axes:
        reference = axes[0]
        spread = [angle_between(reference, axis) for axis in axes[1:]]
        mean_axis = np.mean([axis if float(axis @ reference) > 0 else -axis for axis in axes], axis=0)
        mean_axis /= np.linalg.norm(mean_axis)
        # Ось относительного поворота живёт в системе координат камеры; для отчёта
        # переводим её в мировую, чтобы «стол» давал ось ≈ (0, 1, 0).
        world_axis = with_yaw[0]["R"].T @ mean_axis
        world_axis /= np.linalg.norm(world_axis)
        result.update({
            "axis": [round(float(value), 4) for value in world_axis],
            "axis_camera": [round(float(value), 4) for value in mean_axis],
            "axis_spread_deg": round(float(np.max(spread)) if spread else 0.0, 3),
        })

    centers = np.array([image["center"] for image in with_yaw])
    if len(centers) > 3:
        centroid = centers.mean(axis=0)
        radii = np.linalg.norm(centers - centroid, axis=1)
        median_radius = float(np.median(radii))
        if median_radius > 0:
            # На столе камера стоит на месте, поэтому в реконструкции её центры
            # лежат на окружности одного радиуса — разброс радиуса и есть проверка.
            low, high = np.percentile(radii, [5, 95])
            result["radius_spread_fraction"] = round(float((high - low) / median_radius), 4)
            _, _, vt = np.linalg.svd(centers - centroid, full_matrices=False)
            normal = vt[-1]
            heights = np.abs((centers - centroid) @ normal)
            result["planarity_fraction"] = round(float(heights.max() / median_radius), 4)

    result["ok"] = bool(result["median_step_error_deg"] <= MAX_STEP_ERROR_DEG
                        and result.get("axis_spread_deg", 0.0) <= MAX_AXIS_SPREAD_DEG)
    result["details"] = handled
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Проверка поворотного стола по реконструкции")
    parser.add_argument("--model", required=True, help="папка sparse/0-txt")
    parser.add_argument("--shots", required=True, help="папка скана с shots.json")
    parser.add_argument("--json", action="store_true", help="вывести результат в JSON")
    args = parser.parse_args()

    try:
        result = analyze(args.model, args.shots)
    except Exception as exc:  # noqa: BLE001
        print(f"failed: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"steps:      {result['pairs']} pairs, median {result['median_step_deg']:.2f} deg")
        print(f"step error: {result['median_step_error_deg']:.2f} deg median, "
              f"{result['max_step_error_deg']:.2f} deg max")
        if "axis" in result:
            print(f"axis:       {result['axis']} (spread {result['axis_spread_deg']:.2f} deg)")
        if "camera_drift_fraction" in result:
            print(f"radius:     spread {result['radius_spread_fraction'] * 100:.1f} %, planar {result['planarity_fraction'] * 100:.1f} %")
        print("verdict:    " + ("ok" if result["ok"] else "mismatch — check sector counting or handheld shots"))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
