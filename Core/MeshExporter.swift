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

    /// - Parameter scale: поправка калибровки (1 = как измерил LiDAR).
    static func exportOBJ(anchors: [UUID: ARMeshAnchor], to url: URL, scale: Float = 1) throws -> Stats {
        let sink = try TextSink(url: url)
        defer { sink.close() }

        sink.write("# ScanLab LiDAR mesh\n# units: meters, ARKit world space (Y up)\n")
        if abs(scale - 1) > 0.0001 {
            sink.write("# scale applied: \(scale) (calibrated against a known length)\n")
        }
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

            // ARKit иногда отдаёт неконечные вершины (nan/inf) там, где глубина не
            // восстановилась. Писать их в OBJ нельзя: импортеры считают такой меш битым,
            // а границы превращаются в nan. Такие вершины выбрасываем и перенумеровываем
            // индексы граней через remap.
            var remap = [Int32](repeating: -1, count: count)
            var kept = 0

            for index in 0..<count {
                let pointer = base
                    .advanced(by: offset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                let transformed = transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(transformed.x, transformed.y, transformed.z) * scale
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }

                if world.x < minBound.x { minBound.x = world.x }
                if world.y < minBound.y { minBound.y = world.y }
                if world.z < minBound.z { minBound.z = world.z }
                if world.x > maxBound.x { maxBound.x = world.x }
                if world.y > maxBound.y { maxBound.y = world.y }
                if world.z > maxBound.z { maxBound.z = world.z }

                sink.write("v \(world.x) \(world.y) \(world.z)\n")
                remap[index] = Int32(kept)
                kept += 1
            }

            let faces = geometry.faces
            let faceCount = faces.count
            var writtenFaces = 0

            // ARGeometryElement.subscript(index) -> [Int32]: одна грань на индекс.
            // Грань с индексом вне диапазона или с выброшенной вершиной пропускаем целиком,
            // иначе OBJ получит ссылку на несуществующую вершину.
            for faceIndex in 0..<faceCount {
                var line = "f"
                var valid = true
                for raw in faces[faceIndex] {
                    let vertexIndex = Int(raw)
                    guard vertexIndex >= 0, vertexIndex < count, remap[vertexIndex] >= 0 else {
                        valid = false
                        break
                    }
                    line += " \(Int(remap[vertexIndex]) + 1 + indexOffset)"
                }
                if valid {
                    sink.write(line + "\n")
                    writtenFaces += 1
                }
            }

            indexOffset += kept
            vertexTotal += kept
            faceTotal += writtenFaces
        }

        if vertexTotal == 0 {
            throw ExportError.emptyMesh
        }
        sink.flush()
        if let writeError = sink.writeError {
            throw writeError
        }

        return Stats(
            vertices: vertexTotal,
            faces: faceTotal,
            anchors: ordered.count,
            min: minBound,
            max: maxBound
        )
    }

    /// Бинарный STL — формат, который слайсеры (Bambu Studio, Cura, PrusaSlicer)
    /// открывают напрямую, без конвертации из OBJ.
    ///
    /// Раскладка: 80 байт заголовка, `UInt32` число треугольников, дальше по 50 байт
    /// на грань — нормаль (3 × Float32), три вершины (9 × Float32), `UInt16` атрибут.
    static func exportSTL(anchors: [UUID: ARMeshAnchor], to url: URL, scale: Float = 1) throws -> Stats {
        let ordered = anchors.sorted { $0.key.uuidString < $1.key.uuidString }

        let fm = FileManager.default
        // Пишем во временный файл: если экспорт упадёт на середине, в архиве
        // не останется mesh.stl с нулевым числом треугольников.
        let temp = url.appendingPathExtension("tmp")
        if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temp)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? fm.removeItem(at: temp) }
        }

        var buffer = Data()
        buffer.reserveCapacity(1_100_000)

        var header = Data(repeating: 0, count: 80)
        // Единицы и коэффициент пишем честно: STL их не хранит, а шапку читают люди.
        let signature = Array("ScanLab LiDAR mesh; units=meters; scale=\(scale)".utf8)
        header.replaceSubrange(0..<min(signature.count, 80), with: signature.prefix(80))
        buffer.append(header)
        // Число треугольников проставим в конце, когда узнаем, сколько граней прошло проверки.
        buffer.append(Data(repeating: 0, count: 4))

        var vertexTotal = 0
        var triangleTotal = 0
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for (_, anchor) in ordered {
            let geometry = anchor.geometry
            let source = geometry.vertices
            let count = source.count
            guard count > 0 else { continue }

            let transform = anchor.transform
            let base = source.buffer.contents()
            let stride = source.stride
            let offset = source.offset

            var world = [SIMD3<Float>]()
            world.reserveCapacity(count)
            // Неконечные вершины ARKit выбрасываем: nan в STL ломает слайсер целиком.
            var remap = [Int32](repeating: -1, count: count)
            var kept = 0
            for index in 0..<count {
                let pointer = base
                    .advanced(by: offset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                let transformed = transform * SIMD4<Float>(local, 1)
                let point = SIMD3<Float>(transformed.x, transformed.y, transformed.z) * scale
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }

                remap[index] = Int32(kept)
                kept += 1
                world.append(point)

                if point.x < minBound.x { minBound.x = point.x }
                if point.y < minBound.y { minBound.y = point.y }
                if point.z < minBound.z { minBound.z = point.z }
                if point.x > maxBound.x { maxBound.x = point.x }
                if point.y > maxBound.y { maxBound.y = point.y }
                if point.z > maxBound.z { maxBound.z = point.z }
            }

            let faces = geometry.faces
            for faceIndex in 0..<faces.count {
                let indices = faces[faceIndex]
                guard indices.count >= 3 else { continue }
                let i0 = Int(indices[0]), i1 = Int(indices[1]), i2 = Int(indices[2])
                guard i0 >= 0, i1 >= 0, i2 >= 0,
                      i0 < count, i1 < count, i2 < count,
                      remap[i0] >= 0, remap[i1] >= 0, remap[i2] >= 0 else { continue }

                let a = world[Int(remap[i0])]
                let b = world[Int(remap[i1])]
                let c = world[Int(remap[i2])]
                let cross = simd_cross(b - a, c - a)
                let length = simd_length(cross)
                let normal = (length.isFinite && length > 0) ? cross / length : SIMD3<Float>(0, 1, 0)

                appendFloat(normal.x, to: &buffer)
                appendFloat(normal.y, to: &buffer)
                appendFloat(normal.z, to: &buffer)
                for point in [a, b, c] {
                    appendFloat(point.x, to: &buffer)
                    appendFloat(point.y, to: &buffer)
                    appendFloat(point.z, to: &buffer)
                }
                appendUInt16(0, to: &buffer)
                triangleTotal += 1

                if buffer.count >= 1_000_000 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            vertexTotal += kept
        }

        if triangleTotal == 0 || vertexTotal == 0 {
            throw ExportError.emptyMesh
        }

        // Ставим настоящее число треугольников в шапку и дописываем хвост.
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        var countBytes = Data()
        appendUInt32(UInt32(triangleTotal), to: &countBytes)
        _ = try handle.seek(toOffset: 80)
        try handle.write(contentsOf: countBytes)
        _ = try handle.seekToEnd()

        try handle.close()
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temp, to: url)
        completed = true

        return Stats(
            vertices: vertexTotal,
            faces: triangleTotal,
            anchors: ordered.count,
            min: minBound,
            max: maxBound
        )
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { raw in data.append(contentsOf: raw) }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { raw in data.append(contentsOf: raw) }
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        appendUInt32(value.bitPattern, to: &data)
    }

    static func writeMeta(to directory: URL, stats: Stats, extra: [String: Any] = [:]) throws {
        // JSONSerialization падает с исключением на nan/inf, поэтому значения проверяем
        // заранее: пусть лучше будет понятная ошибка, чем «Ошибка экспорта» без причины.
        let values: [Float] = [stats.min.x, stats.min.y, stats.min.z,
                               stats.max.x, stats.max.y, stats.max.z,
                               stats.size.x, stats.size.y, stats.size.z]
        guard values.allSatisfy({ $0.isFinite }) else { throw ExportError.invalidBounds }

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
        case invalidBounds

        var errorDescription: String? {
            switch self {
            case .emptyMesh:
                return "Меш пуст: LiDAR не собрал ни одной вершины"
            case .invalidBounds:
                return "Габариты меша не числа (nan/inf): обойдите объект заново"
            }
        }
    }
}

/// Буферизованная запись текста: OBJ комнаты — это десятки мегабайт,
/// поэтому пишем порциями, а не копим одну гигантскую строку.
final class TextSink {
    private let handle: FileHandle
    private var buffer = ""
    private let flushThreshold = 1_000_000
    /// Ошибка записи (кончилось место, диск отвалился). Раньше она глоталась через `try?`,
    /// и пользователь получал молча обрезанный OBJ вместо сообщения об ошибке.
    private(set) var writeError: Error?

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
        do {
            try handle.write(contentsOf: data)
        } catch {
            if writeError == nil { writeError = error }
        }
    }

    func close() {
        flush()
        try? handle.close()
    }
}
