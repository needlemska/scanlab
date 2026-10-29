import Foundation
import ARKit
import CoreImage
import UIKit

/// Автоматический фотозахват: телефон сам решает, когда сделать кадр.
///
/// Смысл: пользователю не нужно ни считать кадры, ни думать о ракурсах —
/// он просто обходит предмет, а приложение снимает, когда появился новый ракурс
/// и предмет влезает в кадр. Кадры сразу ложатся в папку скана в формате,
/// который понимает `PhotogramModel` и ПК-пайплайн.
@MainActor
final class AutoScanModel: NSObject, ObservableObject {
    @Published private(set) var shots = 0
    @Published private(set) var coverage: Float = 0
    @Published private(set) var hint = "Наведите камеру на предмет"
    @Published private(set) var isScanning = false
    @Published private(set) var folder: URL?
    @Published private(set) var status = ""
    @Published var autoShoot = true

    private weak var session: ARSession?
    private var covered = [Bool](repeating: false, count: ScanCoach.count)
    private var center: SIMD3<Float>?
    private var lastShotAt = Date.distantPast
    private var lastDirection: SIMD3<Float>?
    private var framesSinceStart = 0
    private let ciContext = CIContext()
    private var shotsMeta: [[String: Any]] = []
    private var intrinsics: [String: Double] = [:]
    private var imageSize = CGSize.zero

    /// Вызывается из вью, когда ARView создан: модель должна знать сессию.
    func mount(_ session: ARSession) {
        self.session = session
    }

    func startScan() {
        guard let session else {
            hint = "Камера ещё не готова"
            return
        }
        folder = Paths.newScanDirectory(prefix: "auto")
        covered = [Bool](repeating: false, count: ScanCoach.count)
        center = nil
        lastShotAt = .distantPast
        lastDirection = nil
        shotsMeta = []
        intrinsics = [:]
        shots = 0
        coverage = 0
        framesSinceStart = 0
        status = ""
        hint = "Обойдите предмет по кругу"

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
    }

    func stopScan() {
        session?.pause()
        isScanning = false
        writeMeta()
    }

    /// Ошибка ARKit приходит из делегата — показываем её, а не молчим.
    func note(sessionError: String) {
        isScanning = false
        status = "ARKit: \(sessionError)"
        hint = "Перезапустите скан: ARKit сообщил об ошибке"
    }

    func reset() {
        stopScan()
        folder = nil
        shots = 0
        coverage = 0
        center = nil
        covered = [Bool](repeating: false, count: ScanCoach.count)
        shotsMeta = []
        hint = "Наведите камеру на предмет"
        status = ""
    }

    // MARK: - Кадры

    /// Кормится делегатом ARSession.
    func ingest(_ frame: ARFrame, session: ARSession) {
        guard isScanning else { return }
        framesSinceStart += 1

        let tracking = Self.trackingName(frame.camera.trackingState)
        guard tracking == "normal" else {
            hint = ScanCoach.hint(covered: covered, distance: nil, tracking: tracking)
            return
        }

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        if center == nil || framesSinceStart % 30 == 0 {
            center = Self.raycastCenter(frame: frame, session: session) ?? center
        }
        guard let center else {
            hint = "Наведите камеру на предмет"
            return
        }

        let distance = ScanCoach.distance(cameraPosition, center)
        ScanCoach.markCovered(&covered, camera: cameraPosition, center: center)
        coverage = ScanCoach.coverage(covered)
        hint = ScanCoach.hint(covered: covered, distance: distance, tracking: tracking)

        if intrinsics.isEmpty {
            let matrix = frame.camera.intrinsics
            intrinsics = [
                "fx": Double(matrix.columns.0.x),
                "fy": Double(matrix.columns.1.y),
                "cx": Double(matrix.columns.2.x),
                "cy": Double(matrix.columns.2.y)
            ]
            imageSize = frame.camera.imageResolution
        }

        guard autoShoot, shots < ScanCoach.maxShots else { return }
        guard distance >= ScanCoach.minDistance, distance <= ScanCoach.maxDistance else { return }

        let direction = ScanCoach.normalized(cameraPosition - center)
        if let lastDirection {
            let angle = ScanCoach.angleDegrees(direction, lastDirection)
            guard angle >= ScanCoach.minShotAngleDeg else { return }
        }
        guard Date().timeIntervalSince(lastShotAt) >= ScanCoach.minInterval else { return }

        if capture(frame: frame, cameraPosition: cameraPosition, session: session) {
            lastShotAt = Date()
            lastDirection = direction
            shots += 1
            status = "Снято \(shots)"
        }
    }

    private func capture(frame: ARFrame, cameraPosition: SIMD3<Float>, session: ARSession) -> Bool {
        guard let folder else { return false }
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let data = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            status = "Кадр не сконвертировался"
            return false
        }
        let name = String(format: "img_%03d.jpg", shots + 1)
        let url = folder.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            status = "Не записался \(name): \(error.localizedDescription)"
            return false
        }

        let transform = frame.camera.transform
        var pose: [Double] = []
        for column in 0..<4 {
            for row in 0..<4 {
                pose.append(Double(transform[column][row]))
            }
        }
        shotsMeta.append([
            "file": name,
            "transform": pose,
            "distance": Double(ScanCoach.distance(cameraPosition, center ?? cameraPosition)),
            "coverage": Double(coverage)
        ])
        return true
    }

    private func writeMeta() {
        guard let folder, !shotsMeta.isEmpty else { return }
        var payload: [String: Any] = [
            "kind": "auto-scan",
            "shots": shotsMeta,
            "intrinsics": intrinsics,
            "imageWidth": Double(imageSize.width),
            "imageHeight": Double(imageSize.height),
            "note": "Fotogrammetriya: obhod vokrug predmeta, kadry avtomaticheskie"
        ]
        payload["count"] = shotsMeta.count
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: folder.appendingPathComponent("shots.json"), options: .atomic)
    }

    // MARK: - Помощники

    private static func raycastCenter(frame: ARFrame, session: ARSession) -> SIMD3<Float>? {
        let point = CGPoint(x: 0.5, y: 0.5)
        let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        guard let hit = session.raycast(query).first else { return nil }
        let matrix = hit.worldTransform
        // Поднимаем точку на 4 см: центр предмета обычно выше поверхности стола.
        return SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y + 0.04, matrix.columns.3.z)
    }

    private static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited:
            return "limited"
        }
    }
}
