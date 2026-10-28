#!/usr/bin/env python3
"""Измерение и подготовка модели для 3D-печати.

Принимает ZIP от ScanLab, папку, .obj/.ply/.stl. Печатает габариты в мм,
объём, watertight, число компонент и пишет model_mm.stl в миллиметрах.

    pip install open3d numpy
    python measure.py ScanLab.zip
    python measure.py model.obj --scale 0.001 --out out/
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import zipfile

import numpy as np

try:
    import open3d as o3d
except ImportError:  # понятная подсказка вместо голого traceback
    raise SystemExit(
        "Нужен open3d: pip install -r pc/requirements.txt\n"
        "Ставьте на ПК с NVIDIA (там же, где RealityCapture)."
    )

MESH_EXT = (".obj", ".ply", ".stl", ".glb", ".gltf")
READERS = {
    ".obj": lambda p: o3d.io.read_triangle_mesh(p, enable_post_processing=True),
    ".ply": lambda p: o3d.io.read_triangle_mesh(p, enable_post_processing=True),
    ".stl": lambda p: o3d.io.read_triangle_mesh(p),
    ".glb": lambda p: o3d.io.read_triangle_mesh(p),
    ".gltf": lambda p: o3d.io.read_triangle_mesh(p),
}


def find_mesh(root: str) -> str:
    candidates = []
    for directory, _, files in os.walk(root):
        for name in files:
            if name.lower().endswith(MESH_EXT):
                path = os.path.join(directory, name)
                candidates.append((os.path.getsize(path), path))
    if not candidates:
        raise SystemExit(
            f"В {root} нет меша ({', '.join(MESH_EXT)}).\n"
            "ZIP с кадрами — это набор для фотограмметрии, сначала соберите модель (см. PIPELINE.md)."
        )
    candidates.sort(reverse=True)
    return candidates[0][1]


def load(path: str) -> o3d.geometry.TriangleMesh:
    ext = os.path.splitext(path)[1].lower()
    mesh = READERS[ext](path)
    if mesh.is_empty():
        raise SystemExit(f"Пустой или нечитаемый меш: {path}")
    return mesh


def clean(mesh: o3d.geometry.TriangleMesh) -> o3d.geometry.TriangleMesh:
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    return mesh


def report(mesh: o3d.geometry.TriangleMesh, scale: float) -> dict:
    vertices = np.asarray(mesh.vertices)
    extents = vertices.max(axis=0) - vertices.min(axis=0) if len(vertices) else np.zeros(3)

    watertight = bool(mesh.is_watertight())
    volume = float(mesh.get_volume()) if watertight and len(mesh.triangles) else 0.0

    clusters, counts, _ = mesh.cluster_connected_triangles()
    clusters = np.asarray(clusters)
    components = int(len(counts))

    biggest = int(np.argmax(counts)) if components else 0
    largest_share = float(counts[biggest] / max(1, len(clusters))) if components else 0.0

    return {
        "triangles": int(len(mesh.triangles)),
        "vertices": int(len(mesh.vertices)),
        "size_mm": [round(float(v) * scale * 1000.0, 2) for v in extents],
        "volume_cm3": round(volume * (scale * 100.0) ** 3, 2),
        "watertight": watertight,
        "components": components,
        "largest_component_share": round(largest_share, 3),
        "scale_applied": scale,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Замер модели и экспорт STL в мм")
    parser.add_argument("input", help="ZIP, папка, .obj/.ply/.stl")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="множитель до перевода в мм (по умолчанию 1: модель уже в метрах)")
    parser.add_argument("--out", default="pc/out", help="куда положить результат")
    parser.add_argument("--json", action="store_true", help="вывести только JSON")
    args = parser.parse_args()

    tmp = None
    source = args.input
    if os.path.isfile(source) and source.lower().endswith(".zip"):
        tmp = tempfile.mkdtemp(prefix="scanlab-")
        with zipfile.ZipFile(source) as archive:
            archive.extractall(tmp)
        source = tmp
    elif os.path.isfile(source):
        source = os.path.dirname(os.path.abspath(source)) or "."

    try:
        mesh_path = find_mesh(source)
        mesh = clean(load(mesh_path))
        if args.scale != 1.0:
            mesh.scale(args.scale, center=np.zeros(3))

        data = report(mesh, 1.0)
        data["source"] = os.path.basename(mesh_path)

        os.makedirs(args.out, exist_ok=True)
        stem = os.path.splitext(os.path.basename(args.input))[0] or "model"
        stl_path = os.path.join(args.out, "model_mm.stl")
        mesh.scale(1000.0, center=np.zeros(3))  # метры → миллиметры
        o3d.io.write_triangle_mesh(stl_path, mesh, write_ascii=False)
        data["stl"] = os.path.abspath(stl_path)

        json_path = os.path.join(args.out, f"{stem}-measure.json")
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)

        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(f"Источник:        {data['source']}")
            print(f"Треугольников:   {data['triangles']:,}")
            print(f"Габарит, мм:     {data['size_mm'][0]} × {data['size_mm'][1]} × {data['size_mm'][2]}")
            print(f"Объём, см³:      {data['volume_cm3']}")
            print(f"Watertight:      {'да' if data['watertight'] else 'НЕТ — закрыть дыры'}")
            print(f"Компонент:       {data['components']} (крупнейшая {data['largest_component_share']:.0%})")
            print(f"STL в мм:        {data['stl']}")
            print(f"Отчёт:           {os.path.abspath(json_path)}")

            if max(data["size_mm"]) < 0.1 or max(data["size_mm"]) > 10000:
                print("\nВНИМАНИЕ: габарит не похож на реальный. Проверьте --scale и масштабную метку.")
            if data["components"] > 1 and data["largest_component_share"] < 0.9:
                print("ВНИМАНИЕ: модель развалилась на куски — обычно мало перекрытия кадров.")
            if not data["watertight"]:
                print("ВНИМАНИЕ: не watertight. В MeshLab: Filters → Remeshing → Close Holes.")
        return 0
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
