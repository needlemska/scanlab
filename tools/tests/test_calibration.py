"""Проверки калибровочных скриптов на синтетике — без телефона, COLMAP и интернета.

Запуск:

    python tools/tests/test_calibration.py

Покрыто:
  * scale_from_poses  — Umeyama + RANSAC (масштаб по позам ARKit, выбросы);
  * scale_from_depth  — масштаб по LiDAR-глубине (перекрытия, дыры, разрешение);
  * turn_table_check  — шаг поворота и ось стола;
  * разборы images.txt / shots.json (кватернион → поворот, column-major поза).

Зачем это здесь: на стенде без Swift и без macOS единственный быстрый способ
поймать регресс в ПК-части — вот эти проверки. CI гоняет их же.
"""

from __future__ import annotations

import json
import math
import os
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "pc"))

import photogrammetry
import scale_from_depth as sfd
import scale_from_poses as sfp
import turn_table_check as ttc

failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("ok   " if condition else "FAIL ") + name + ("" if condition else " " + detail))
    if not condition:
        failures.append(name)


def rot_z(angle: float) -> np.ndarray:
    c, s = math.cos(angle), math.sin(angle)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def ring(count: int = 12, radius: float = 0.45) -> list[np.ndarray]:
    return [
        np.array([
            radius * math.cos(2 * math.pi * i / count),
            radius * math.sin(2 * math.pi * i / count) * 0.4,
            0.2 + 0.1 * math.sin(i),
        ])
        for i in range(count)
    ]


# --------------------------------------------------------------- poses


def test_scale_from_poses() -> None:
    true_scale = 0.37
    rotation = rot_z(0.7)
    shift = np.array([1.5, -2.0, 0.4])
    src = ring()
    dst = [true_scale * rotation @ point + shift for point in src]
    pairs = [(f"img_{i:03d}.jpg", src[i], dst[i]) for i in range(len(src))]

    result = sfp.robust_scale(pairs)
    check("poses: масштаб 0.37", abs(result["scale"] - true_scale) < 1e-9, str(result["scale"]))
    check("poses: все кадры в допуске", result["inliers"] == len(pairs), f"{result['inliers']}/{result['pairs']}")

    noisy = list(pairs)
    noisy.append(("img_900.jpg", src[0], dst[0] + np.array([3.0, 0.0, 0.0])))
    noisy.append(("img_901.jpg", src[1], dst[1] + np.array([0.0, 2.5, 0.0])))
    result = sfp.robust_scale(noisy)
    check("poses: выбросы отброшены", result["inliers"] == 12, f"{result['inliers']}/{result['pairs']}")
    check("poses: масштаб с выбросами", abs(result["scale"] - true_scale) < 1e-3, str(result["scale"]))

    try:
        sfp.robust_scale([("a.jpg", np.zeros(3), np.zeros(3))] * 6)
        check("poses: вырожденный вход даёт ошибку", False, "исключения не было")
    except ValueError:
        check("poses: вырожденный вход даёт ошибку", True)

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "images.txt")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("1 1 0 0 0 0.5 -1.0 2.0 1 img_001.jpg\n10 20 -1 -1\n\n")
            handle.write("2 0.7071068 0 0.7071068 0 0 0 3.0 1 img_002.jpg\n10 20 -1 -1\n")
        centers = sfp.read_images_txt(path)
        check("poses: две камеры прочитаны", len(centers) == 2, str(list(centers)))
        check("poses: центр без поворота", np.allclose(centers["img_001.jpg"], [-0.5, 1.0, -2.0]),
              str(centers["img_001.jpg"]))
        check("poses: центр с поворотом", np.allclose(centers["img_002.jpg"], [3.0, 0.0, 0.0], atol=1e-5),
              str(centers["img_002.jpg"]))

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "shots.json")
        pose = [0.0] * 16
        pose[0] = pose[5] = pose[10] = pose[15] = 1.0
        pose[12], pose[13], pose[14] = 0.3, -0.2, 1.4
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"shots": [{"file": "img_001.jpg", "transform": pose}]}, handle)
        centers = sfp.read_arkit_shots(path)
        check("poses: сдвиг из shots.json (column-major)", np.allclose(centers["img_001.jpg"], [0.3, -0.2, 1.4]),
              str(centers))


# --------------------------------------------------------------- depth

IMG_W, IMG_H = 1920, 1440
DEPTH_W, DEPTH_H = 256, 192
FX = FY = 1500.0
CX, CY = IMG_W / 2.0, IMG_H / 2.0


def look_at(position: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    forward = -position / np.linalg.norm(position)
    x_axis = np.cross(np.array([0.0, 1.0, 0.0]), forward)
    x_axis /= np.linalg.norm(x_axis)
    y_axis = np.cross(forward, x_axis)
    rotation = np.vstack([x_axis, y_axis, forward])
    return rotation, -rotation @ position


def quat_from_rot(rotation: np.ndarray) -> np.ndarray:
    trace = rotation[0, 0] + rotation[1, 1] + rotation[2, 2]
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2
        q = [0.25 * s, (rotation[2, 1] - rotation[1, 2]) / s,
             (rotation[0, 2] - rotation[2, 0]) / s, (rotation[1, 0] - rotation[0, 1]) / s]
    else:
        i = int(np.argmax([rotation[0, 0], rotation[1, 1], rotation[2, 2]]))
        if i == 0:
            s = math.sqrt(1.0 + rotation[0, 0] - rotation[1, 1] - rotation[2, 2]) * 2
            q = [(rotation[2, 1] - rotation[1, 2]) / s, 0.25 * s,
                 (rotation[0, 1] + rotation[1, 0]) / s, (rotation[0, 2] + rotation[2, 0]) / s]
        elif i == 1:
            s = math.sqrt(1.0 + rotation[1, 1] - rotation[0, 0] - rotation[2, 2]) * 2
            q = [(rotation[0, 2] - rotation[2, 0]) / s, (rotation[0, 1] + rotation[1, 0]) / s,
                 0.25 * s, (rotation[1, 2] + rotation[2, 1]) / s]
        else:
            s = math.sqrt(1.0 + rotation[2, 2] - rotation[0, 0] - rotation[1, 1]) * 2
            q = [(rotation[1, 0] - rotation[0, 1]) / s, (rotation[0, 2] + rotation[2, 0]) / s,
                 (rotation[1, 2] + rotation[2, 1]) / s, 0.25 * s]
    quaternion = np.array(q, dtype=float)
    return quaternion / np.linalg.norm(quaternion)


def write_depth_dataset(root: str, factor: float, points: int = 240, views: int = 6,
                        holes: float = 0.0) -> str:
    model = os.path.join(root, "sparse", "0-txt")
    os.makedirs(model, exist_ok=True)
    with open(os.path.join(model, "cameras.txt"), "w", encoding="utf-8") as handle:
        handle.write("# Camera list\n1 OPENCV 1920 1440 1500 1500 960 720 0 0 0 0\n")

    generator = np.random.default_rng(7)
    cloud = generator.normal(size=(points, 3))
    cloud /= np.linalg.norm(cloud, axis=1, keepdims=True)
    cloud *= 0.30

    camera = sfd.Camera(FX, FY, CX, CY, 0.0, 0.0, 0.0, 0.0, IMG_W, IMG_H)
    image_lines = ["# Image list"]
    point_lines = ["# 3D point list"]
    shots = []

    for image_id in range(1, views + 1):
        angle = 2 * math.pi * (image_id - 1) / views
        position = np.array([0.65 * math.cos(angle), 0.10 * math.sin(2 * angle), 0.65 * math.sin(angle)])
        rotation, shift = look_at(position)
        name = f"img_{image_id:03d}.jpg"
        quaternion = quat_from_rot(rotation)
        shift_sfm = shift * factor
        image_lines.append(
            f"{image_id} " + " ".join(f"{value:.9f}" for value in quaternion) + " "
            + " ".join(f"{value:.9f}" for value in shift_sfm) + f" 1 {name}"
        )
        # POINTS2D пишем не пустой строкой, а настоящими треками: иначе тест
        # не проверяет главное — что строки точек не принимаются за камеры.
        point_pairs: list[str] = []
        image_lines.append("")

        depth = np.zeros((DEPTH_H, DEPTH_W), dtype="<f4")
        for point_id, point in enumerate(cloud, start=1):
            camera_point = rotation @ point + shift
            if camera_point[2] <= 0.05:
                continue
            u, v = camera.project(camera_point[0], camera_point[1], camera_point[2])
            point_pairs.append(f"{point_id * 100 + image_id} {u:.4f} {v:.4f} -1")
            du = int(round(u * DEPTH_W / IMG_W))
            dv = int(round(v * DEPTH_H / IMG_H))
            if not (1 <= du < DEPTH_W - 1 and 1 <= dv < DEPTH_H - 1):
                continue
            depth[dv - 1:dv + 2, du - 1:du + 2] = camera_point[2]
            sfm_point = point * factor
            point_lines.append(
                f"{point_id * 100 + image_id} " + " ".join(f"{value:.9f}" for value in sfm_point)
                + f" 128 128 128 0.5 {image_id} 0"
            )

        image_lines[-1] = " ".join(point_pairs)

        depth_file = name.replace(".jpg", "_depth.f32")
        if holes > 0:
            mask = generator.random((DEPTH_H, DEPTH_W)) < holes
            depth[mask] = 0.0
        depth.tofile(os.path.join(root, depth_file))
        shots.append({"file": name, "depthFile": depth_file, "depthSize": [DEPTH_W, DEPTH_H]})

    with open(os.path.join(model, "images.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(image_lines) + "\n")
    with open(os.path.join(model, "points3D.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(point_lines) + "\n")
    with open(os.path.join(root, "shots.json"), "w", encoding="utf-8") as handle:
        json.dump({"shots": shots}, handle)
    return model


def test_scale_from_depth() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        model = write_depth_dataset(tmp, factor=0.37)
        result = sfd.estimate_scale(model, tmp)
        expected = 1.0 / 0.37
        check("depth: масштаб 1/0.37", abs(result["scale"] - expected) / expected < 1e-3,
              f"{result['scale']:.6f} != {expected:.6f}")
        check("depth: инлайеры", result["inliers"] >= result["pairs"] * 0.9,
              f"{result['inliers']}/{result['pairs']}")
        check("depth: невязка < 1 мм", result["median_residual_mm"] < 1.0,
              f"{result['median_residual_mm']:.3f}")

    with tempfile.TemporaryDirectory() as tmp:
        model = write_depth_dataset(tmp, factor=1.0)
        result = sfd.estimate_scale(model, tmp)
        check("depth: масштаб 1.0", abs(result["scale"] - 1.0) < 1e-3, f"{result['scale']:.6f}")

    with tempfile.TemporaryDirectory() as tmp:
        model = write_depth_dataset(tmp, factor=0.37, points=2)
        try:
            sfd.estimate_scale(model, tmp)
            check("depth: мало точек даёт ошибку", False, "исключения не было")
        except ValueError:
            check("depth: мало точек даёт ошибку", True)

    with tempfile.TemporaryDirectory() as tmp:
        model = write_depth_dataset(tmp, factor=0.37, holes=0.35)
        result = sfd.estimate_scale(model, tmp)
        expected = 1.0 / 0.37
        check("depth: дыры LiDAR пережиты", abs(result["scale"] - expected) / expected < 5e-3,
              f"{result['scale']:.6f}")


# --------------------------------------------------------------- turntable


def axis_rotation(axis: tuple[float, float, float], degrees: float) -> np.ndarray:
    vector = np.array(axis, dtype=float)
    vector /= np.linalg.norm(vector)
    angle = math.radians(degrees)
    x, y, z = vector
    c, s = math.cos(angle), math.sin(angle)
    C = 1 - c
    return np.array([
        [c + x * x * C, x * y * C - z * s, x * z * C + y * s],
        [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
        [z * x * C - y * s, z * y * C + x * s, c + z * z * C],
    ])


def write_turntable(root: str, step_deg: float = 15.0, count: int = 24,
                    yaw_step: float | None = None) -> str:
    model = os.path.join(root, "sparse", "0-txt")
    os.makedirs(model, exist_ok=True)
    with open(os.path.join(model, "cameras.txt"), "w", encoding="utf-8") as handle:
        handle.write("# Camera list\n1 PINHOLE 1920 1440 1500 1500 960 720\n")

    position = np.array([0.0, 0.35, 0.55])
    rotation0, shift0 = look_at(-position if False else position)
    rotation0 = rotation0 @ np.diag([1.0, 1.0, 1.0])

    lines = ["# Image list"]
    shots = []
    for index in range(count):
        rotation = rotation0 @ axis_rotation((0.0, 1.0, 0.0), step_deg * index)
        quaternion = quat_from_rot(rotation)
        name = f"img_{index + 1:03d}.jpg"
        lines.append(
            f"{index + 1} " + " ".join(f"{value:.9f}" for value in quaternion) + " "
            + " ".join(f"{value:.9f}" for value in shift0) + f" 1 {name}"
        )
        lines.append("")
        recorded = (yaw_step if yaw_step is not None else step_deg) * index
        shots.append({"file": name, "yawDeg": round(recorded, 3), "sector": index % 24})

    with open(os.path.join(model, "images.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    with open(os.path.join(root, "shots.json"), "w", encoding="utf-8") as handle:
        json.dump({"shots": shots}, handle)
    return model


def test_turn_table() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        model = write_turntable(tmp)
        result = ttc.analyze(model, tmp)
        check("стол: шаг 15°", abs(result["median_step_deg"] - 15.0) < 0.05, str(result["median_step_deg"]))
        check("стол: ошибка шага ~0", result["median_step_error_deg"] < 0.05, str(result["median_step_error_deg"]))
        check("стол: ось Y", abs(abs(result["axis"][1]) - 1.0) < 0.01, str(result["axis"]))
        check("стол: вердикт ok", result["ok"], str(result["median_step_error_deg"]))

    with tempfile.TemporaryDirectory() as tmp:
        model = write_turntable(tmp, yaw_step=9.0)
        result = ttc.analyze(model, tmp)
        check("стол: сбитый счётчик пойман", not result["ok"], str(result["median_step_error_deg"]))
        check("стол: ошибка ~6°", 5.5 < result["median_step_error_deg"] < 6.5, str(result["median_step_error_deg"]))

    with tempfile.TemporaryDirectory() as tmp:
        model = write_turntable(tmp)
        shots_path = os.path.join(tmp, "shots.json")
        with open(shots_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        for shot in data["shots"]:
            shot.pop("yawDeg", None)
        with open(shots_path, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        try:
            ttc.analyze(model, tmp)
            check("стол: без yawDeg ошибка", False, "исключения не было")
        except ValueError:
            check("стол: без yawDeg ошибка", True)


def test_camera_hint() -> None:
    """Фокус из угла обзора: кадры приложения идут без FocalLength в EXIF."""
    fx = photogrammetry.focal_from_hfov(4032, 73.0)
    check("камера: fx из hfov 73°", abs(fx - 2724.5) < 2.0, f"{fx:.1f} px")
    fx_wide = photogrammetry.focal_from_hfov(4032, 120.0)
    check("камера: широкий угол даёт меньше фокус", fx_wide < fx / 2, f"{fx_wide:.1f} px")

    for bad in ((0, 73.0), (4032, 0.0), (4032, 180.0), (4032, -5.0)):
        try:
            photogrammetry.focal_from_hfov(*bad)
            check(f"камера: плохой вход {bad}", False, "исключения не было")
        except ValueError:
            check(f"камера: плохой вход {bad}", True)

    with tempfile.TemporaryDirectory() as root:
        with open(os.path.join(root, "shots.json"), "w", encoding="utf-8") as handle:
            json.dump({"shots": [{"file": "img_001.jpg", "imageSize": [4032, 3024], "hfovDeg": 73.0}]},
                      handle)
        guess = photogrammetry.camera_params_from_shots(root)
        check("камера: параметры найдены", guess is not None, "None")
        if guess:
            params, meta = guess
            numbers = [float(x) for x in params.split(",")]
            check("камера: восемь параметров OPENCV", len(numbers) == 8, params)
            check("камера: cx, cy по центру",
                  (numbers[2], numbers[3]) == (2016.0, 1512.0), params)
            check("камера: дисторсия нулевая", numbers[4:] == [0.0, 0.0, 0.0, 0.0], params)

    with tempfile.TemporaryDirectory() as root:
        with open(os.path.join(root, "shots.json"), "w", encoding="utf-8") as handle:
            json.dump({"shots": [{"file": "img_001.jpg"}]}, handle)
        check("камера: без hfov подсказки нет",
              photogrammetry.camera_params_from_shots(root) is None, "не None")


def main() -> int:
    print(f"python {sys.version.split()[0]}, numpy {np.__version__}")
    test_scale_from_poses()
    test_scale_from_depth()
    test_turn_table()
    test_camera_hint()
    print("")
    if failures:
        print(f"провалено: {', '.join(failures)}")
        return 1
    print("все проверки прошли")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
