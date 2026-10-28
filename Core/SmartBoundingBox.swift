import Foundation
import ARKit
import simd

/// Габариты по осям объекта, а не по осям мира.
///
/// Обычный AABB (min/max по мировым осям) на повёрнутой коробке 100x60x40 даёт
/// сотни миллиметров вдоль осей мира — потому что оси мира не совпадают с осями
/// предмета. Здесь оси берутся из нормалей граней: кластер по площади, до трёх
/// ортогональных направлений. Если одна плоскость доминирует (стол, пол), её
/// точки выбрасываются и высота считается от плоскости.
///
/// Вход — по три точки на грань (порядок: грань i занимает точки 3i, 3i+1, 3i+2),
/// нормаль грани и её площадь. Так индексы граней и точек согласованы.
struct SmartBoxResult {
    var size: SIMD3<Float>
    var axes: [SIMD3<Float>]
    var method: String
    var coverage: Float
    var planeShare: Float
}

enum SmartBox {
    // Пороги подобраны на синтетике и проверены на 160 сценах (см. .scratch/testdata).
    static let tolDeg: Float = 12
    static let bandMeters: Float = 0.008
    static let tailFraction: Float = 0.02
    static let minPoints = 400
    static let minPlaneShare: Float = 0.35
    static let minPlaneMargin: Float = 2.0
    static let minCoverage: Float = 0.75

    struct Cluster {
        var axis: SIMD3<Float>
        var weight: Float
        var mask: [Bool]
    }

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    static func length(_ a: SIMD3<Float>) -> Float {
        sqrt(dot(a, a))
    }

    static func normalized(_ a: SIMD3<Float>) -> SIMD3<Float> {
        let l = length(a)
        return l > 1e-9 ? a / l : SIMD3<Float>(0, 1, 0)
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(a.y * b.z - a.z * b.y,
                     a.z * b.x - a.x * b.z,
                     a.x * b.y - a.y * b.x)
    }

    /// Жадно выбирает до трёх направлений, покрывающих большинство нормалей по площади.
    static func clusterAxes(normals: [SIMD3<Float>], weights: [Float]) -> [Cluster] {
        let threshold = cos(tolDeg * .pi / 180)
        var used = [Bool](repeating: false, count: normals.count)
        var order = Array(0..<normals.count)
        order.sort { weights[$0] > weights[$1] }
        var clusters: [Cluster] = []

        for i in order {
            if used[i] { continue }
            var axis = normalized(normals[i])
            for _ in 0..<3 {
                var sum = SIMD3<Float>.zero
                var any = false
                for j in 0..<normals.count where abs(dot(normals[j], axis)) > threshold {
                    let sign: Float = dot(normals[j], axis) >= 0 ? 1 : -1
                    sum += normals[j] * sign
                    any = true
                }
                if !any { break }
                axis = normalized(sum)
            }
            var mask = [Bool](repeating: false, count: normals.count)
            var weight: Float = 0
            var covered = false
            for j in 0..<normals.count where abs(dot(normals[j], axis)) > threshold {
                mask[j] = true
                weight += weights[j]
                if !used[j] { covered = true }
            }
            if !covered { continue }
            // параллельные кластеры (стол и низ предмета в одной плоскости,
            // или близнецы после уточнения центра) не считаем разными осями
            if clusters.contains(where: { abs(dot($0.axis, axis)) > threshold }) {
                for j in 0..<normals.count where mask[j] { used[j] = true }
                continue
            }
            for j in 0..<normals.count where mask[j] { used[j] = true }
            clusters.append(Cluster(axis: axis, weight: weight, mask: mask))
            if clusters.count >= 3 { break }
        }
        clusters.sort { $0.weight > $1.weight }
        return clusters
    }

    /// Три ортогональные оси; nil, если направления вырождены.
    static func orthonormal(_ axes: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard axes.count >= 3 else { return nil }
        let a = normalized(axes[0])
        let b = normalized(axes[1] - a * dot(axes[1], a))
        if length(b) < 1e-6 { return nil }
        let c = normalized(cross(a, b))
        return [a, b, c]
    }

    /// Размер по одному направлению: разница средних хвостов по 2 %.
    /// Устойчивее, чем min/max: одиночный выброс ARKit не растягивает габарит.
    static func tailExtent(_ values: [Float]) -> Float {
        guard values.count > 8 else {
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        let sorted = values.sorted()
        let lo = Int(Float(sorted.count - 1) * tailFraction)
        let hi = sorted.count - 1 - lo
        var lowSum: Float = 0
        for i in 0...lo { lowSum += sorted[i] }
        var highSum: Float = 0
        for i in hi..<sorted.count { highSum += sorted[i] }
        return highSum / Float(sorted.count - hi) - lowSum / Float(lo + 1)
    }

    /// Среднее верхнего хвоста — верхняя грань объекта.
    static func topMean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let hi = sorted.count - 1 - Int(Float(sorted.count - 1) * tailFraction)
        var sum: Float = 0
        for i in hi..<sorted.count { sum += sorted[i] }
        return sum / Float(sorted.count - hi)
    }

    static func projections(_ points: [SIMD3<Float>], axis: SIMD3<Float>) -> [Float] {
        points.map { dot($0, axis) }
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func obbAxes(normals: [SIMD3<Float>], weights: [Float])
        -> (axes: [SIMD3<Float>], coverage: Float)? {
        let clusters = clusterAxes(normals: normals, weights: weights)
        let total = weights.reduce(0, +)
        let covered = clusters.reduce(0) { $0 + $1.weight }
        let coverage = total > 0 ? covered / total : 0
        guard clusters.count >= 3, coverage >= minCoverage else { return nil }
        guard let axes = orthonormal(clusters.map { $0.axis }) else { return nil }
        return (axes, coverage)
    }

    static func obb(points: [SIMD3<Float>], normals: [SIMD3<Float>], weights: [Float]) -> SmartBoxResult? {
        guard let (axes, coverage) = obbAxes(normals: normals, weights: weights) else {
            return nil
        }
        var size = SIMD3<Float>.zero
        for i in 0..<3 {
            size[i] = tailExtent(projections(points, axis: axes[i]))
        }
        return SmartBoxResult(size: size, axes: axes, method: "OBB",
                              coverage: coverage, planeShare: 0)
    }

    /// Главный вход. facePoints — вершины в метрах по три на грань,
    /// faceNormals — нормали граней, faceAreas — их площади.
    static func measure(facePoints: [SIMD3<Float>],
                        faceNormals: [SIMD3<Float>],
                        faceAreas: [Float]) -> SmartBoxResult? {
        guard faceNormals.count >= minPoints,
              facePoints.count == faceNormals.count * 3,
              faceAreas.count == faceNormals.count else { return nil }

        let clusters = clusterAxes(normals: faceNormals, weights: faceAreas)
        guard let plane = clusters.first else { return nil }
        let total = faceAreas.reduce(0, +)
        let share = total > 0 ? plane.weight / total : 0
        let second = clusters.count > 1 ? clusters[1].weight : 0
        let tableLike = share >= minPlaneShare && plane.weight >= minPlaneMargin * second

        if tableLike {
            // положение плоскости — медиана проекций точек её граней
            var planeValues: [Float] = []
            for f in 0..<faceNormals.count where plane.mask[f] {
                for k in 0..<3 { planeValues.append(dot(facePoints[f * 3 + k], plane.axis)) }
            }
            guard !planeValues.isEmpty else { return nil }
            let planePosition = median(planeValues)

            // выбрасываем полосу ±8 мм вокруг плоскости: это стол и низ предмета
            var objectPoints: [SIMD3<Float>] = []
            objectPoints.reserveCapacity(facePoints.count)
            for p in facePoints where abs(dot(p, plane.axis) - planePosition) > bandMeters {
                objectPoints.append(p)
            }

            // нормали оставляем все: обрезка тонкая, а кластеры осей от неё не меняются
            if objectPoints.count >= minPoints,
               let found = obbAxes(normals: faceNormals, weights: faceAreas) {
                let coverage = found.coverage
                var axes = found.axes
                var vertical = 0
                var best: Float = -1
                for i in 0..<3 {
                    let value = abs(dot(axes[i], plane.axis))
                    if value > best { best = value; vertical = i }
                }
                if median(projections(objectPoints, axis: axes[vertical])) < 0 {
                    axes[vertical] = -axes[vertical]
                }
                var size = SIMD3<Float>.zero
                for i in 0..<3 {
                    if i == vertical {
                        let top = topMean(projections(objectPoints, axis: axes[i]))
                        let planeOnAxis = planePosition * dot(axes[i], plane.axis)
                        size[i] = abs(top - planeOnAxis)
                    } else {
                        size[i] = tailExtent(projections(objectPoints, axis: axes[i]))
                    }
                }
                return SmartBoxResult(size: size, axes: axes, method: "TABLE",
                                      coverage: coverage, planeShare: share)
            }
        }

        return obb(points: facePoints, normals: faceNormals, weights: faceAreas)
    }

    /// Собирает точки/нормали/площади прямо из ARMeshAnchor-ов в мировых координатах.
    static func measure(anchors: [ARMeshAnchor], maxFaces: Int = 120_000) -> SmartBoxResult? {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var areas: [Float] = []
        points.reserveCapacity(min(maxFaces, 60_000) * 3)

        var totalFaces = 0
        for anchor in anchors { totalFaces += anchor.geometry.faces.count }
        let faceStride = max(1, totalFaces / max(1, maxFaces))

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let source = geometry.vertices
            let base = source.buffer.contents().advanced(by: source.offset)
            let vertexCount = source.count
            let vertexStride = source.stride
            // ARGeometryElement не имеет offset (в отличие от ARGeometrySource) — индексы начинаются с нуля буфера.
            let indexBase = geometry.faces.buffer.contents()
            let bytesPerIndex = geometry.faces.bytesPerIndex
            let faceCount = geometry.faces.count

            func vertex(_ index: Int) -> SIMD3<Float> {
                let p = base.advanced(by: index * vertexStride).assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(p[0], p[1], p[2])
                let world = transform * SIMD4<Float>(local, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }

            func corner(_ face: Int, _ k: Int) -> Int {
                let offset = (face * 3 + k) * bytesPerIndex
                let p = indexBase.advanced(by: offset)
                if bytesPerIndex == 2 {
                    return Int(p.assumingMemoryBound(to: UInt16.self).pointee)
                }
                return Int(p.assumingMemoryBound(to: UInt32.self).pointee)
            }

            var f = 0
            while f < faceCount {
                let i0 = corner(f, 0), i1 = corner(f, 1), i2 = corner(f, 2)
                if i0 < vertexCount, i1 < vertexCount, i2 < vertexCount {
                    let a = vertex(i0), b = vertex(i1), c = vertex(i2)
                    let normal = cross(b - a, c - a)
                    let area2 = length(normal)
                    if area2 > 1e-9 {
                        points.append(a); points.append(b); points.append(c)
                        normals.append(normal / area2)
                        areas.append(area2 * 0.5)
                    }
                }
                f += faceStride
            }
        }

        return measure(facePoints: points, faceNormals: normals, faceAreas: areas)
    }
}
