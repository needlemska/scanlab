#!/usr/bin/env python3
"""Измерение и подготовка модели для 3D-печати.

Принимает ZIP от ScanLab, папку, .obj/.ply/.stl. Печатает габариты в мм,
объём, watertight, число компонент и пишет model_mm.stl в миллиметрах.

open3d нужен для .ply/.stl/.glb; OBJ меряется и без него (numpy) — так
скрипт работает на любой машине, где есть только numpy.

    pip install -r requirements.txt      # open3d + numpy
    python measure.py ScanLab.zip
    python measure.py model.obj --scale 0.001 --out out/
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import tempfile
import zipfile

import numpy as np

try:  # чтобы перенаправленный вывод в cp1251-консоли не падал на не-ASCII
    sys.stdout.reconfigure(errors="replace")
except (AttributeError, ValueError):
    pass

try:
    import open3d as o3d
    HAVE_O3D = True
except ImportError:
    o3d = None
    HAVE_O3D = False

MESH_EXT = (".obj", ".ply", ".stl", ".glb", ".gltf")


# --------------------------------------------------------------------------- #
# Поиск файла
# --------------------------------------------------------------------------- #

def find_mesh(root: str, exclude: str | None = None) -> str:
    skip = os.path.abspath(exclude) if exclude else None
    candidates = []
    for directory, _, files in os.walk(root):
        if skip and os.path.abspath(directory).startswith(skip):
            continue
        for name in files:
            if name.lower().endswith(MESH_EXT):
                path = os.path.join(directory, name)
                candidates.append((os.path.getsize(path), path))
    if not candidates:
        raise SystemExit(
            f"No mesh ({', '.join(MESH_EXT)}) found in {root}.\n"
            "A ZIP with frames is a photogrammetry set - build the model first (see PIPELINE.md)."
        )
    candidates.sort(reverse=True)
    return candidates[0][1]


# --------------------------------------------------------------------------- #
# Загрузка
# --------------------------------------------------------------------------- #

def read_obj(path: str) -> tuple[np.ndarray, np.ndarray]:
    """Минимальный OBJ: v / f, веера для полигонов, 1-based и отрицательные индексы."""
    verts: list[tuple[float, float, float]] = []
    faces: list[tuple[int, int, int]] = []

    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if line.startswith("v "):
                parts = line.split()
                verts.append((float(parts[1]), float(parts[2]), float(parts[3])))
            elif line.startswith("f "):
                raw = [int(token.split("/")[0]) for token in line.split()[1:]]
                for i in range(1, len(raw) - 1):
                    faces.append((raw[0], raw[i], raw[i + 1]))

    if not verts or not faces:
        raise SystemExit(f"OBJ has no geometry: {path}")

    v = np.asarray(verts, dtype=np.float64)
    f = np.asarray(faces, dtype=np.int64)
    f = np.where(f < 0, f + len(v), f - 1)  # отрицательные индексы — от конца
    return v, f


def load(path: str) -> tuple[np.ndarray, np.ndarray, str]:
    ext = os.path.splitext(path)[1].lower()

    if HAVE_O3D:
        mesh = o3d.io.read_triangle_mesh(
            path, enable_post_processing=ext in (".obj", ".ply")
        )
        if mesh.is_empty():
            raise SystemExit(f"Empty or unreadable mesh: {path}")
        return (
            np.asarray(mesh.vertices, dtype=np.float64),
            np.asarray(mesh.triangles, dtype=np.int64),
            "open3d",
        )

    if ext != ".obj":
        raise SystemExit(
            f"{ext} needs open3d to read:\n"
            "    pip install -r requirements.txt"
        )
    v, f = read_obj(path)
    return v, f, "numpy"


# --------------------------------------------------------------------------- #
# Геометрия
# --------------------------------------------------------------------------- #

def clean(v: np.ndarray, f: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Убирает вырожденные и повторяющиеся треугольники, перенумеровывает вершины."""
    keep = (f[:, 0] != f[:, 1]) & (f[:, 1] != f[:, 2]) & (f[:, 0] != f[:, 2])
    f = f[keep]

    if len(f) == 0:
        raise SystemExit("Nothing left after cleaning: no valid triangles.")

    _, first = np.unique(np.sort(f, axis=1), axis=0, return_index=True)
    f = f[np.sort(first)]

    used = np.unique(f)
    remap = np.full(len(v), -1, dtype=np.int64)
    remap[used] = np.arange(len(used))
    return v[used], remap[f]


def measure(v: np.ndarray, f: np.ndarray) -> dict:
    used = np.unique(f)
    extents = v[used].max(axis=0) - v[used].min(axis=0) if used.size else np.zeros(3)

    tri = v[f]
    signed = np.einsum(
        "ij,ij->i", tri[:, 0, :], np.cross(tri[:, 1, :], tri[:, 2, :])
    ).sum() / 6.0
    volume = abs(float(signed))

    edges = np.sort(
        np.concatenate([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]]), axis=1
    )
    _, edge_counts = np.unique(edges, axis=0, return_counts=True)
    watertight = bool(edge_counts.size and np.all(edge_counts == 2))

    parent = np.arange(len(v), dtype=np.int64)

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = int(parent[x])
        return x

    for a, b, c in f:
        ra, rb, rc = find(int(a)), find(int(b)), find(int(c))
        if rb != ra:
            parent[rb] = ra
        rc = find(int(c))
        if rc != ra:
            parent[rc] = ra

    roots = np.array([find(int(x)) for x in used])
    uniq_roots, sizes = np.unique(roots, return_counts=True)
    components = int(uniq_roots.size)
    largest_share = float(sizes.max() / len(used)) if components else 0.0

    return {
        "triangles": int(len(f)),
        "vertices": int(len(used)),
        "extents": extents,
        "volume": volume,
        "watertight": watertight,
        "components": components,
        "largest_share": largest_share,
    }


def write_stl(path: str, v: np.ndarray, f: np.ndarray) -> None:
    """Бинарный STL; нормали оставлены нулевыми — слайсеры пересчитывают сами."""
    tri = v[f].astype("<f4")
    with open(path, "wb") as handle:
        handle.write(b"\0" * 80)
        handle.write(struct.pack("<I", len(f)))
        for t in tri:
            handle.write(struct.pack("<3f", 0.0, 0.0, 0.0))
            handle.write(t.tobytes())
            handle.write(b"\0\0")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main() -> int:
    parser = argparse.ArgumentParser(description="Замер модели и экспорт STL в мм")
    parser.add_argument("input", help="ZIP, папка, .obj/.ply/.stl")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="множитель до перевода в мм (по умолчанию 1: модель уже в метрах)")
    parser.add_argument("--units", choices=("m", "mm"), default="m",
                        help="в чём координаты модели: m (ScanLab, RealityCapture) или mm (Blender/Fusion)")
    parser.add_argument("--out", default="pc/out", help="куда положить результат")
    parser.add_argument("--json", action="store_true", help="вывести только JSON")
    args = parser.parse_args()
    if args.units == "mm":
        args.scale *= 0.001

    tmp = None
    source = args.input
    mesh_path: str | None = None

    if os.path.isfile(source) and source.lower().endswith(".zip"):
        tmp = tempfile.mkdtemp(prefix="scanlab-")
        with zipfile.ZipFile(source) as archive:
            archive.extractall(tmp)
        source = tmp
    elif os.path.isfile(source) and source.lower().endswith(MESH_EXT):
        mesh_path = os.path.abspath(source)
    elif os.path.isfile(source):
        source = os.path.dirname(os.path.abspath(source)) or "."

    try:
        if mesh_path is None:
            mesh_path = find_mesh(source, exclude=args.out)
        verts, faces, engine = load(mesh_path)
        verts, faces = clean(verts, faces)
        verts = verts * args.scale

        info = measure(verts, faces)
        data = {
            "source": os.path.basename(mesh_path),
            "engine": engine,
            "triangles": info["triangles"],
            "vertices": info["vertices"],
            "size_mm": [round(float(e) * 1000.0, 2) for e in info["extents"]],
            "volume_cm3": round(info["volume"] * 1e6, 2),
            "watertight": info["watertight"],
            "components": info["components"],
            "largest_component_share": round(info["largest_share"], 3),
            "scale_applied": args.scale,
        }

        os.makedirs(args.out, exist_ok=True)
        stem = os.path.splitext(os.path.basename(args.input))[0] or "model"
        stl_path = os.path.join(args.out, "model_mm.stl")
        write_stl(stl_path, verts * 1000.0, faces)
        data["stl"] = os.path.abspath(stl_path)

        json_path = os.path.join(args.out, f"{stem}-measure.json")
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)

        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
            return 0

        print(f"Source:          {data['source']} ({engine})")
        print(f"Triangles:       {data['triangles']:,}")
        print(f"Size, mm:        {data['size_mm'][0]} x {data['size_mm'][1]} x {data['size_mm'][2]}")
        print(f"Volume, cm3:     {data['volume_cm3']}")
        print(f"Watertight:      {'yes' if data['watertight'] else 'NO - close holes'}")
        print(f"Components:      {data['components']} (largest {data['largest_component_share']:.0%})")
        print(f"STL (mm):        {data['stl']}")
        print(f"Report:          {os.path.abspath(json_path)}")

        if max(data["size_mm"]) < 0.1 or max(data["size_mm"]) > 10000:
            print("\nWARNING: size looks unreal. Check --units/--scale and the scale marker.")
        if data["components"] > 1 and data["largest_component_share"] < 0.9:
            print("WARNING: model broke into pieces - usually too little frame overlap.")
        if not data["watertight"]:
            print("WARNING: not watertight. MeshLab: Filters -> Remeshing -> Close Holes.")
        return 0
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
