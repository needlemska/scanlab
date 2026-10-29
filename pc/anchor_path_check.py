"""Проверка пути `SmartBox.measure(anchors:)` — того, что работает на телефоне.

Вкладка «Тест» проверяет только `measure(facePoints:...)`. А на устройстве точки
берутся из ARMeshAnchor: буферы вершин с offset и stride, буфер индексов с
bytesPerIndex 2 или 4, мировая матрица anchor.transform и прореживание граней
(faceStride). Здесь этот путь воспроизведён байт в байт на синтетических буферах:
если арифметика неверна, результат развалится.
"""
import struct

import numpy as np

from smart_measure import smart_measure

DIMS = (0.10, 0.06, 0.04)
CELLS = 12


def box_mesh(dims, cells):
    """Коробка с общими вершинами и треугольниками наружу. Возвращает (verts, faces)."""
    half = np.array(dims, dtype=np.float64) / 2.0
    index_of = {}
    verts = []

    def vertex(axis, sign, i, j, u, v, du, dv):
        key = (axis, sign, i, j)
        if key not in index_of:
            p = np.zeros(3)
            p[axis] = sign * half[axis]
            p[u] = -half[u] + i * du
            p[v] = -half[v] + j * dv
            index_of[key] = len(verts)
            verts.append(p)
        return index_of[key]

    faces = []
    for axis in range(3):
        u, v = (axis + 1) % 3, (axis + 2) % 3
        du, dv = 2 * half[u] / cells, 2 * half[v] / cells
        for sign in (1, -1):
            for i in range(cells):
                for j in range(cells):
                    a = vertex(axis, sign, i, j, u, v, du, dv)
                    b = vertex(axis, sign, i + 1, j, u, v, du, dv)
                    c = vertex(axis, sign, i + 1, j + 1, u, v, du, dv)
                    d = vertex(axis, sign, i, j + 1, u, v, du, dv)
                    if sign > 0:
                        faces.append((a, b, c))
                        faces.append((a, c, d))
                    else:
                        faces.append((a, c, b))
                        faces.append((a, d, c))
    return np.array(verts, dtype=np.float64), np.array(faces, dtype=np.int64)


def pack_vertices(verts, offset=32, stride=16):
    """Буфер как у ARKit: сначала offset байт мусора, затем вершины с шагом stride."""
    buf = bytearray(offset)
    for p in verts:
        chunk = struct.pack("<4f", p[0], p[1], p[2], 0.0)
        assert len(chunk) <= stride
        buf += chunk + b"\x00" * (stride - len(chunk))
    return bytes(buf)


def pack_indices(faces, bytes_per_index):
    flat = faces.reshape(-1)
    if bytes_per_index == 2:
        return struct.pack("<%dH" % len(flat), *flat)
    return struct.pack("<%dI" % len(flat), *flat)


def read_anchor(vertex_buffer, offset, stride, vertex_count, index_buffer,
                bytes_per_index, face_count, transform, max_faces=120_000):
    """Дословный перенос measure(anchors:maxFaces:) из SmartBoundingBox.swift."""
    face_stride = max(1, face_count // max(1, max_faces))
    points, normals, areas = [], [], []

    def vertex(index):
        at = offset + index * stride
        x, y, z = struct.unpack_from("<3f", vertex_buffer, at)
        return np.array([x, y, z], dtype=np.float64)

    def corner(face, k):
        at = (face * 3 + k) * bytes_per_index
        if bytes_per_index == 2:
            return struct.unpack_from("<H", index_buffer, at)[0]
        return struct.unpack_from("<I", index_buffer, at)[0]

    f = 0
    while f < face_count:
        i0, i1, i2 = corner(f, 0), corner(f, 1), corner(f, 2)
        if i0 < vertex_count and i1 < vertex_count and i2 < vertex_count:
            local = [vertex(i0), vertex(i1), vertex(i2)]
            world = [(transform[:3, :3] @ p) + transform[:3, 3] for p in local]
            a, b, c = world
            n = np.cross(b - a, c - a)
            area2 = float(np.linalg.norm(n))
            if area2 > 1e-9:
                points.extend(world)
                normals.append(n / area2)
                areas.append(area2 * 0.5)
        f += face_stride
    return np.array(points), np.array(normals), np.array(areas)


def rotation(angle, axis):
    axis = np.array(axis, dtype=np.float64)
    axis /= np.linalg.norm(axis)
    c, s = np.cos(angle), np.sin(angle)
    x, y, z = axis
    return np.array([
        [c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
        [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
        [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)],
    ])


def frame(rot, shift):
    m = np.eye(4)
    m[:3, :3] = rot
    m[:3, 3] = shift
    return m


def run(label, bytes_per_index=2, max_faces=120_000, two_anchors=False, expect_mm=(40, 60, 100), expect_none=False):
    verts, faces = box_mesh(DIMS, CELLS)
    rot = rotation(0.6, (1.0, 1.0, 0.4))
    shift = np.array([0.5, -0.25, 0.75])
    transform = frame(rot, shift)

    chunks = []
    if two_anchors:
        # Две половины коробки: свой локальный меш и своя матрица размещения.
        half_faces = len(faces) // 2
        for part, (lo, hi) in enumerate(((0, half_faces), (half_faces, len(faces)))):
            part_faces = faces[lo:hi]
            used = np.unique(part_faces)
            remap = {old: new for new, old in enumerate(used)}
            local_verts = verts[used] - np.array([0.0, 0.0, 0.0])
            local_faces = np.array([[remap[i] for i in tri] for tri in part_faces], dtype=np.int64)
            # Обе половины лежат в одной системе координат: части одного меша,
            # а не два разных объекта. Разные матрицы здесь означали бы излом коробки.
            part_transform = transform
            chunks.append((local_verts, local_faces, part_transform))
    else:
        chunks.append((verts, faces, transform))

    points, normals, areas = [], [], []
    for local_verts, local_faces, m in chunks:
        vb = pack_vertices(local_verts)
        ib = pack_indices(local_faces, bytes_per_index)
        p, n, w = read_anchor(vb, 32, 16, len(local_verts), ib, bytes_per_index, len(local_faces), m, max_faces)
        points.append(p)
        normals.append(n)
        areas.append(w)
    pts = np.vstack(points)
    nrm = np.vstack(normals)
    wts = np.concatenate(areas)

    if expect_none:
        assert smart_measure(pts, nrm, wts) is None, "%s: ожидался None" % label
        print("%-28s points=%-6d -> None, как и ожидалось" % (label, len(pts)))
        return 0.0
    result = smart_measure(pts, nrm, wts)
    assert result is not None, "%s: smart_measure вернул None (точек %d)" % (label, len(pts))
    dims = np.sort(result["dims"] * 1000.0)
    expect = np.sort(np.array(expect_mm, dtype=np.float64))
    worst = float(np.max(np.abs(dims - expect)))
    print("%-28s points=%-6d method=%-5s dims=%s err=%.2f mm" % (
        label, len(pts), result["method"], np.round(dims, 2), worst))
    assert worst < 2.0, "%s: ошибка %.2f мм" % (label, worst)
    return worst


if __name__ == "__main__":
    errors = [
        run("uint16, stride16, offset32"),
        run("uint32, stride16, offset32", bytes_per_index=4),
        run("two anchors", two_anchors=True),
        run("sampling max_faces=300", max_faces=300),
        run("sampling max_faces=120 (guard)", max_faces=120, expect_none=True),
    ]
    print("OK: худшая ошибка %.2f мм на всех вариантах буферов" % max(errors))
