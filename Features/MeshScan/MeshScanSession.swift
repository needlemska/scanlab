import Foundation
import ARKit
import RealityKit
import Combine
import simd

@MainActor
final class MeshScanSession: NSObject, ObservableObject {

    @Published var isScanning = false
    @Published var isBusy = false
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var anchorCount = 0
    @Published var status = "Нажмите «Старт» и обойдите объект"
    @Published var lastArchive: URL?
    @Published var errorText: String?
    @Published var rulerPoints: [SIMD3<Float>] = []

    /// Расстояние между двумя поставленными точками, метры.
    var rulerDistance: Float? {
        guard rulerPoints.count == 2 else { return nil }
        return simd_distance(rulerPoints[0], rulerPoints[1])
    }

    private(set) var anchors: [UUID: ARMeshAnchor] = [:]
    weak var arView: ARView?
    private var lastRecount = Date.distantPast

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
    }

    // MARK: - Управление

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorText = "ARKit не поддерживается на этом устройстве"
            return
        }

        let configuration = ARWorldTrackingConfiguration()

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorText = "LiDAR-реконструкция недоступна"
            return
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            configuration.sceneReconstruction = .mesh
        }

        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        anchors.removeAll()
        vertexCount = 0
        faceCount = 0
        anchorCount = 0
        errorText = nil

        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        status = "Сканирование: ведите телефоном медленно, 0.3–2 м"
    }

    func stop() {
        arView?.session.pause()
        isScanning = false
        status = "Пауза. Можно продолжить или экспортировать"
    }

    func reset() {
        arView?.session.pause()
        anchors.removeAll()
        vertexCount = 0
        faceCount = 0
        anchorCount = 0
        isScanning = false
        lastArchive = nil
        rulerPoints.removeAll()
        status = "Сброшено"
    }

    // MARK: - Линейка

    /// Тап по экрану: ставит точку A и B, третьим тапом начинает заново.
    func addRulerPoint(at tap: CGPoint, in viewSize: CGSize) {
        guard let frame = arView?.session.currentFrame else {
            status = "Кадр AR ещё не готов — подождите секунду"
            return
        }

        guard let point = RulerPicker.worldPoint(tap: tap, viewSize: viewSize, frame: frame) else {
            status = "В этой точке нет глубины — наведите на поверхность объекта"
            return
        }

        if rulerPoints.count >= 2 {
            rulerPoints.removeAll()
        }
        rulerPoints.append(point)

        if let distance = rulerDistance {
            status = String(format: "Расстояние: %.1f мм", distance * 1000)
        } else {
            status = "Точка A есть, тапните точку B"
        }
    }

    func clearRuler() {
        rulerPoints.removeAll()
        status = "Линейка сброшена"
    }

    // MARK: - Экспорт

    func finishAndExport() {
        guard !anchors.isEmpty else {
            errorText = "Меш пуст: LiDAR не увидел поверхность"
            return
        }

        isBusy = true
        arView?.session.pause()
        isScanning = false
        status = "Экспорт…"

        let snapshot = anchors

        Task.detached(priority: .userInitiated) {
            do {
                let directory = Paths.newScanDirectory(prefix: "lidar")
                let objURL = directory.appendingPathComponent("mesh.obj")
                let stats = try MeshExporter.exportOBJ(anchors: snapshot, to: objURL)
                try MeshExporter.writeMeta(to: directory, stats: stats)

                let archive = Paths.zipURL(for: directory)
                try? FileManager.default.removeItem(at: archive)
                try ZipWriter.write(directory: directory, to: archive)

                let size = stats.size
                await MainActor.run {
                    self.lastArchive = archive
                    self.isBusy = false
                    self.status = String(
                        format: "Готово: %d вершин, габарит %.2f × %.2f × %.2f м",
                        stats.vertices, size.x, size.y, size.z
                    )
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.isBusy = false
                    self.status = "Ошибка экспорта"
                }
            }
        }
    }

    // MARK: - Учёт меша

    private func ingest(_ meshes: [ARMeshAnchor]) {
        for mesh in meshes {
            anchors[mesh.identifier] = mesh
        }
        if Date().timeIntervalSince(lastRecount) > 0.25 {
            recount()
            lastRecount = Date()
        }
    }

    private func recount() {
        var vertices = 0
        var faces = 0
        for anchor in anchors.values {
            vertices += anchor.geometry.vertices.count
            faces += anchor.geometry.faces.count
        }
        vertexCount = vertices
        faceCount = faces
        anchorCount = anchors.count
    }
}

extension MeshScanSession: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor in
            self.ingest(meshes)
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let identifiers = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !identifiers.isEmpty else { return }
        Task { @MainActor in
            for identifier in identifiers {
                self.anchors[identifier] = nil
            }
            self.recount()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            self.errorText = text
            self.isScanning = false
            self.status = "Сессия AR остановлена"
        }
    }
}
