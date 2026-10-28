import Foundation
import ARKit
import simd

/// Экспорт LiDAR-меша ARKit в Wavefront OBJ (мировые координаты, метры).
///
/// ARKit отдаёт меш кусками (`ARMeshAnchor`), каждый в своей локальной системе.
/// Мы применяем `anchor.transform` и складываем всё в один файл — так его
/// открывает Blender, CloudCompare, RealityCapture и слайсеры.
enum MeshExporter {

    struct Stats {
        let vertices: Int
        let faces: Int
        let anchors: Int
        let min: SIMD3<Float>
        let max: SIMD3<Float>

        var size: SIMD3<Float> { max - min }
    }

    static func exportOBJ(anchors: [UUID: ARMeshAnchor], to url: URL) throws -> Stats {
        let sink = try TextSink(url: url)
        defer { sink.close() }

        sink.write("# ScanLab LiDAR mesh\n# units: meters, ARKit world space (Y up)\n")
        sink.write("o scan\n")

        var indexOffset = 0
        var vertexTotal = 0
        var faceTotal = 0
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        let ordered = anchors.sorted { $0.key.uuidString < $1.key.uuidString }

        for (_, anchor) in ordered {
            let geometry = anchor.geometry
            let source = geometry.vertices
            let count = source.count
            guard count > 0 else { continue }

            let transform = anchor.transform
            let base = source.buffer.contents()
            let stride = source.stride
            let offset = source.offset

            for index in 0..<count {
                let pointer = base
                    .advanced(by: offset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                let world = transform * SIMD4<Float>(local, 1)

                if world.x < minBound.x { minBound.x = world.x }
                if world.y < minBound.y { minBound.y = world.y }
                if world.z < minBound.z { minBound.z = world.z }
                if world.x > maxBound.x { maxBound.x = world.x }
                if world.y > maxBound.y { maxBound.y = world.y }
                if world.z > maxBound.z { maxBound.z = world.z }

                sink.write("v \(world.x) \(world.y) \(world.z)\n")
            }

            let faces = geometry.faces
            let faceCount = faces.count

            // ARGeometryElement.subscript(index) -> [Int32]: одна грань на индекс.
            for faceIndex in 0..<faceCount {
                var line = "f"
                for raw in faces[faceIndex] {
                    line += " \(Int(raw) + 1 + indexOffset)"
                }
                sink.write(line + "\n")
            }

            indexOffset += count
            vertexTotal += count
            faceTotal += faceCount
        }

        if vertexTotal == 0 {
            throw ExportError.emptyMesh
        }

        return Stats(
            vertices: vertexTotal,
            faces: faceTotal,
            anchors: ordered.count,
            min: minBound,
            max: maxBound
        )
    }

    static func writeMeta(to directory: URL, stats: Stats, extra: [String: String] = [:]) throws {
        var meta: [String: Any] = [
            "app": "ScanLab",
            "kind": "lidar-mesh",
            "created": ISO8601DateFormatter().string(from: Date()),
            "units": "meters",
            "coordinateSystem": "ARKit world, right-handed, Y up",
            "vertices": stats.vertices,
            "faces": stats.faces,
            "anchors": stats.anchors,
            "boundsMin": [Double(stats.min.x), Double(stats.min.y), Double(stats.min.z)],
            "boundsMax": [Double(stats.max.x), Double(stats.max.y), Double(stats.max.z)],
            "sizeMeters": [Double(stats.size.x), Double(stats.size.y), Double(stats.size.z)],
            "note": "OBJ без текстур. Для печати: закрыть дыры, проверить manifold, масштаб уже в метрах."
        ]
        for (key, value) in extra { meta[key] = value }

        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("meta.json"))
    }

    enum ExportError: LocalizedError {
        case emptyMesh
        var errorDescription: String? { "Меш пуст: LiDAR не собрал ни одной вершины" }
    }
}

/// Буферизованная запись текста: OBJ комнаты — это десятки мегабайт,
/// поэтому пишем порциями, а не копим одну гигантскую строку.
final class TextSink {
    private let handle: FileHandle
    private var buffer = ""
    private let flushThreshold = 1_000_000

    init(url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ text: String) {
        buffer += text
        if buffer.utf8.count >= flushThreshold {
            flush()
        }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        buffer.removeAll(keepingCapacity: true)
        try? handle.write(contentsOf: data)
    }

    func close() {
        flush()
        try? handle.close()
    }
}
