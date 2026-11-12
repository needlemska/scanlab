"""Чтение текстовых моделей COLMAP (cameras.txt / images.txt / points3D.txt).

Один общий разбор на все скрипты ПК-части: раньше `read_images_txt` был
скопирован в три файла и во всех трёх принимал строки POINTS2D за строки
камер. Здесь строки различаются по структуре, а не по числу токенов:
строка камеры имеет ровно 10 обязательных полей, причём первое и девятое —
целые числа; у строки с 2D-точками первое поле дробное (x точки).
"""

from __future__ import annotations

import os

import numpy as np


class Camera:
    """Камера COLMAP с моделью дисторсии, приведённой к k1/k2/p1/p2."""

    __slots__ = ("fx", "fy", "cx", "cy", "k1", "k2", "p1", "p2", "width", "height", "model")

    def __init__(self, fx, fy, cx, cy, k1=0.0, k2=0.0, p1=0.0, p2=0.0, width=0, height=0,
                 model="PINHOLE"):
        self.fx, self.fy, self.cx, self.cy = fx, fy, cx, cy
        self.k1, self.k2, self.p1, self.p2 = k1, k2, p1, p2
        self.width, self.height = width, height
        self.model = model

    def project(self, x: float, y: float, z: float) -> tuple[float, float]:
        """Точка в системе камеры (z > 0) -> пиксель, с радиальной и тангенциальной дисторсией."""
        xn, yn = x / z, y / z
        r2 = xn * xn + yn * yn
        radial = 1.0 + self.k1 * r2 + self.k2 * r2 * r2
        xd = xn * radial + 2.0 * self.p1 * xn * yn + self.p2 * (r2 + 2.0 * xn * xn)
        yd = yn * radial + 2.0 * self.p2 * xn * yn + self.p1 * (r2 + 2.0 * yn * yn)
        return self.fx * xd + self.cx, self.fy * yd + self.cy


def _params(model: str, values: list[float]) -> tuple[float, float, float, float,
                                                      float, float, float, float]:
    """Параметры COLMAP -> (fx, fy, cx, cy, k1, k2, p1, p2).

    Для моделей с одной фокусной (SIMPLE_*) fx = fy = f. У FOV и fisheye-моделей
    берётся только радиальная часть: полноценная fisheye-проекция (угол omega,
    искажение k3/k4) не воспроизводится — на краях кадра ошибка заметна, но
    для масштаба по глубине важен центр кадра, где модель совпадает с pinhole.
    """
    try:
        if model == "SIMPLE_PINHOLE":
            f, cx, cy = values[0], values[1], values[2]
            return f, f, cx, cy, 0.0, 0.0, 0.0, 0.0
        if model == "PINHOLE":
            return values[0], values[1], values[2], values[3], 0.0, 0.0, 0.0, 0.0
        if model == "SIMPLE_RADIAL":
            f, cx, cy, k1 = values[0], values[1], values[2], values[3]
            return f, f, cx, cy, k1, 0.0, 0.0, 0.0
        if model == "RADIAL":
            f, cx, cy, k1, k2 = values[0], values[1], values[2], values[3], values[4]
            return f, f, cx, cy, k1, k2, 0.0, 0.0
        if model in ("OPENCV", "FULL_OPENCV"):
            return tuple(values[0:8])  # type: ignore[return-value]
        if model in ("OPENCV_FISHEYE", "SIMPLE_RADIAL_FISHEYE", "RADIAL_FISHEYE",
                     "FOV", "THIN_PRISM_FISHEYE"):
            fx, fy, cx, cy = values[0], values[1], values[2], values[3]
            k1 = values[4] if len(values) > 4 else 0.0
            k2 = values[5] if len(values) > 5 else 0.0
            return fx, fy, cx, cy, k1, k2, 0.0, 0.0
    except IndexError:
        pass
    # Незнакомая модель: считаем, что первые четыре параметра — fx, fy, cx, cy.
    fx, fy, cx, cy = values[0], values[1], values[2], values[3]
    return fx, fy, cx, cy, 0.0, 0.0, 0.0, 0.0


def read_cameras_txt(path: str) -> dict[int, Camera]:
    cameras: dict[int, Camera] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 5:
                continue
            try:
                camera_id = int(parts[0])
                width, height = int(parts[2]), int(parts[3])
                values = [float(value) for value in parts[4:]]
            except ValueError:
                continue
            model = parts[1]
            fx, fy, cx, cy, k1, k2, p1, p2 = _params(model, values)
            cameras[camera_id] = Camera(fx, fy, cx, cy, k1, k2, p1, p2, width, height, model)
    return cameras


def _camera_line(line: str) -> dict | None:
    """Строка камеры из images.txt или None, если это строка 2D-точек."""
    parts = line.split()
    if len(parts) < 10:
        return None
    try:
        image_id = int(parts[0])
        camera_id = int(parts[8])
        qvec = np.array([float(value) for value in parts[1:5]])
        tvec = np.array([float(value) for value in parts[5:8]])
    except ValueError:
        return None
    name = parts[9] if len(parts) == 10 else " ".join(parts[9:])
    return {"id": image_id, "name": name, "camera_id": camera_id,
            "qvec": qvec, "t": tvec, "R": quat_to_rot(qvec)}


def read_images_txt(path: str) -> dict[int, dict]:
    """id -> {name, camera_id, R, t}; строки с 2D-точками (POINTS2D) пропускаются.

    Формат COLMAP жёстко парный: на каждую камеру идёт её строка и сразу за ней
    строка 2D-точек (может быть пустой). Поэтому читаем состоянием, а не
    угадыванием по числу токенов: строка точек с треками тоже легко даёт
    ≥10 полей (id точки, x, y, -1, …), и «десять токенов + int в 9-м» её не
    отсекают — раньше из-за этого падало `int("0.5123")`.
    """
    images: dict[int, dict] = {}
    expect_image = True
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                # Пустая строка в позиции точек = пустой POINTS2D у этой камеры.
                if not expect_image:
                    expect_image = True
                continue
            if not expect_image:
                expect_image = True
                continue
            parsed = _camera_line(line)
            if parsed is not None:
                images[parsed["id"]] = {
                    "name": parsed["name"],
                    "camera_id": parsed["camera_id"],
                    "R": parsed["R"],
                    "t": parsed["t"],
                }
            # И строка камеры, и любая непонятная строка сменяются строкой точек.
            expect_image = False
    return images


def image_centers(images: dict[int, dict], extensions: tuple[str, ...] = (".jpg", ".jpeg", ".png")
                  ) -> dict[str, np.ndarray]:
    """Центры камер COLMAP: C = -R^T * t, ключ — имя файла."""
    centers: dict[str, np.ndarray] = {}
    for image in images.values():
        name = image["name"]
        if extensions and not name.lower().endswith(extensions):
            continue
        centers[name] = -image["R"].T @ image["t"]
    return centers


def read_points3D_txt(path: str) -> list[dict]:
    points: list[dict] = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            try:
                xyz = np.array([float(parts[1]), float(parts[2]), float(parts[3])])
            except ValueError:
                continue
            track = []
            rest = parts[8:]
            for index in range(0, len(rest) - 1, 2):
                try:
                    track.append((int(rest[index]), int(rest[index + 1])))
                except ValueError:
                    break
            points.append({"xyz": xyz, "track": track})
    return points


def quat_to_rot(q: np.ndarray) -> np.ndarray:
    """Кватернион COLMAP (w, x, y, z) -> матрица поворота."""
    w, x, y, z = float(q[0]), float(q[1]), float(q[2]), float(q[3])
    norm = w * w + x * x + y * y + z * z
    if norm <= 0:
        return np.eye(3)
    s = 2.0 / norm
    return np.array([
        [1 - s * (y * y + z * z), s * (x * y - z * w), s * (x * z + y * w)],
        [s * (x * y + z * w), 1 - s * (x * x + z * z), s * (y * z - x * w)],
        [s * (x * z - y * w), s * (y * z + x * w), 1 - s * (x * x + y * y)],
    ])


def find_images_txt(model: str) -> str:
    """Путь к images.txt: сам файл, папка модели или файл sparse/0.txt/images.txt."""
    if os.path.isfile(model):
        return model
    for candidate in ("images.txt", os.path.join("sparse", "0.txt", "images.txt")):
        path = os.path.join(model, candidate)
        if os.path.isfile(path):
            return path
    raise SystemExit(f"images.txt not found in {model}")
