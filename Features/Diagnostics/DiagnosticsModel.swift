import Foundation
import UIKit
import ARKit
import RealityKit
import simd

/// Одна проверка самодиагностики.
struct DiagnosticCheck: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let passed: Bool
    let critical: Bool
}

/// Самопроверка прямо на телефоне: алгоритмы, которые легко проверить без сцены.
///
/// Зачем: локально собрать Swift негде (Windows), поэтому единственный способ
/// убедиться, что порт алгоритма жив на устройстве — прогнать его на синтетике
/// с известным ответом. Если «Умный габарит» на эталонной коробке даёт правильные
/// миллиметры — порт верен; если нет — видно, сколько именно он врёт.
@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var checks: [DiagnosticCheck] = []
    @Published private(set) var isRunning = false

    var failedCount: Int { checks.filter { !$0.passed }.count }
    var isAllGreen: Bool { !checks.isEmpty && failedCount == 0 }
    var hasRun: Bool { !checks.isEmpty }

    /// Текст отчёта — его удобно скопировать и вставить в чат.
    var report: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "ScanLab \(version) (\(build)) diagnostics",
            "device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
            "time: \(Self.stamp())"
        ]
        if checks.isEmpty {
            lines.append("no checks run")
        } else {
            for c in checks {
                lines.append("\(c.passed ? "PASS" : "FAIL") | \(c.title) | \(c.detail)")
            }
            lines.append(failedCount == 0 ? "RESULT: all checks passed" : "RESULT: \(failedCount) failed")
        }
        return lines.joined(separator: "\n")
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        var result: [DiagnosticCheck] = []
        result.append(storageCheck())
        result.append(spaceCheck())
        result.append(zipCheck())
        result.append(environmentCheck())
        result.append(smartBoxCheck())
        checks = result
        isRunning = false
    }

    // MARK: - Проверки

    private func storageCheck() -> DiagnosticCheck {
        let fileManager = FileManager.default
        let probe = Paths.scans.appendingPathComponent("write-test.txt")
        let title = "Запись в Documents/Scans"
        do {
            try fileManager.createDirectory(at: Paths.scans, withIntermediateDirectories: true)
            try "scanlab".write(to: probe, atomically: true, encoding: .utf8)
            let back = try String(contentsOf: probe, encoding: .utf8)
            try? fileManager.removeItem(at: probe)
            let ok = back == "scanlab"
            return DiagnosticCheck(title: title,
                                   detail: ok ? "папка доступна, чтение совпало" : "запись прошла, прочиталось другое",
                                   passed: ok,
                                   critical: true)
        } catch {
            return DiagnosticCheck(title: title,
                                   detail: "ошибка: \(error.localizedDescription)",
                                   passed: false,
                                   critical: true)
        }
    }

    private func spaceCheck() -> DiagnosticCheck {
        let title = "Свободное место"
        var ok = false
        var detail = "объём неизвестен"
        if let values = try? Paths.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            let gigabytes = Double(bytes) / 1_000_000_000
            detail = String(format: "свободно %.1f ГБ", gigabytes)
            ok = gigabytes > 1.0
        }
        return DiagnosticCheck(title: title, detail: detail, passed: ok, critical: false)
    }

    private func zipCheck() -> DiagnosticCheck {
        let title = "ZIP-упаковщик"
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("scanlab-zip-selftest")
        let archive = fileManager.temporaryDirectory.appendingPathComponent("scanlab-zip-selftest.zip")
        defer {
            try? fileManager.removeItem(at: folder)
            try? fileManager.removeItem(at: archive)
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "scanlab".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try ZipWriter.write(directory: folder, to: archive)
            let data = try Data(contentsOf: archive)
            let localHeader = Data([0x50, 0x4B, 0x03, 0x04])
            let endOfCentral = Data([0x50, 0x4B, 0x05, 0x06])
            let hasHead = data.count > 4 && data.prefix(4) == localHeader
            let hasTail = data.count > 22 && data.suffix(22).prefix(4) == endOfCentral
            let ok = hasHead && hasTail
            return DiagnosticCheck(title: title,
                                   detail: ok ? "\(data.count) байт, заголовки на месте" : "нет сигнатур ZIP",
                                   passed: ok,
                                   critical: true)
        } catch {
            return DiagnosticCheck(title: title,
                                   detail: "ошибка: \(error.localizedDescription)",
                                   passed: false,
                                   critical: true)
        }
    }

    private func environmentCheck() -> DiagnosticCheck {
        let title = "Возможности телефона"
        let lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let photogrammetry = PhotogrammetrySession.isSupported
        let wifi = FileServer.wifiAddress()
        var parts: [String] = []
        parts.append(lidar ? "LiDAR-меш: да" : "LiDAR-меш: нет")
        parts.append(photogrammetry ? "Photogrammetry: да" : "Photogrammetry: нет")
        if let wifi {
            parts.append("Wi-Fi: \(wifi)")
        } else {
            parts.append("Wi-Fi: адреса нет")
        }
        return DiagnosticCheck(title: title,
                               detail: parts.joined(separator: ", "),
                               passed: lidar && photogrammetry,
                               critical: true)
    }

    private func smartBoxCheck() -> DiagnosticCheck {
        let title = "Умный габарит"
        let dims = SIMD3<Float>(0.10, 0.06, 0.04)
        let rotation = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(1, 1, 0.4)))
        let sample = Self.syntheticBox(dims: dims, cells: 12, rotation: rotation)
        guard let result = SmartBox.measure(facePoints: sample.points,
                                            faceNormals: sample.normals,
                                            faceAreas: sample.areas) else {
            return DiagnosticCheck(title: title,
                                   detail: "алгоритм вернул nil на эталонной коробке (граней: \(sample.normals.count))",
                                   passed: false,
                                   critical: true)
        }
        let expected: [Float] = [0.04, 0.06, 0.10]
        let got = [result.size.x, result.size.y, result.size.z].sorted()
        var worst: Float = 0
        for (index, value) in expected.enumerated() {
            worst = max(worst, abs(value - got[index]) * 1000)
        }
        let sizes = String(format: "%.1f × %.1f × %.1f мм", got[0] * 1000, got[1] * 1000, got[2] * 1000)
        let error = String(format: "%.2f", worst)
        return DiagnosticCheck(title: title,
                               detail: "\(sizes), ошибка \(error) мм, метод \(result.method)",
                               passed: worst < 3,
                               critical: true)
    }

    // MARK: - Синтетика

    /// Коробка из треугольников: 6 граней, каждая разбита на cells × cells четырёхугольников.
    /// Возвращает по три точки на грань — ровно тот вход, который ждёт `SmartBox.measure`.
    static func syntheticBox(dims: SIMD3<Float>,
                             cells: Int,
                             rotation: simd_quatf) -> (points: [SIMD3<Float>], normals: [SIMD3<Float>], areas: [Float]) {
        let half = dims / 2
        let steps = max(1, cells)
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var areas: [Float] = []
        points.reserveCapacity(6 * steps * steps * 3)
        normals.reserveCapacity(6 * steps * steps)
        areas.reserveCapacity(6 * steps * steps)

        for axis in 0..<3 {
            let u = (axis + 1) % 3
            let v = (axis + 2) % 3
            let du = (half[u] * 2) / Float(steps)
            let dv = (half[v] * 2) / Float(steps)
            for sign in [Float(1), -1] {
                var normal = SIMD3<Float>(repeating: 0)
                normal[axis] = sign

                func corner(_ i: Int, _ j: Int) -> SIMD3<Float> {
                    var point = SIMD3<Float>(repeating: 0)
                    point[axis] = sign * half[axis]
                    point[u] = -half[u] + Float(i) * du
                    point[v] = -half[v] + Float(j) * dv
                    return point
                }

                for i in 0..<steps {
                    for j in 0..<steps {
                        let a = corner(i, j)
                        let b = corner(i + 1, j)
                        let c = corner(i + 1, j + 1)
                        let d = corner(i, j + 1)
                        for triangle in [[a, b, c], [a, c, d]] {
                            for point in triangle {
                                points.append(rotation.act(point))
                            }
                            normals.append(rotation.act(normal))
                            areas.append(du * dv / 2)
                        }
                    }
                }
            }
        }
        return (points, normals, areas)
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
