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
    /// Габарит всего отсканированного меша в метрах (world-space AABB).
    @Published var sizeMeters: SIMD3<Float> = .zero
    /// Предупреждение от ARKit о качестве трекинга.
    @Published var trackingWarning: String?
    /// Габарит по осям предмета (умный), например 100.2 × 60.1 × 40.3 мм.
    @Published var smartSize: SIMD3<Float>?
    /// "TABLE" — считали от плоскости стола, "OBB" — по осям предмета, nil — не удалось.
    @Published var smartMethod: String?
    @Published var smartBusy = false

    /// Расстояние между двумя поставленными точками, метры.
    var rulerDistance: Float? {
        guard rulerPoints.count == 2 else { return nil }
        return simd_distance(rulerPoints[0], rulerPoints[1])
    }

    private(set) var anchors: [UUID: ARMeshAnchor] = [:]
    weak var arView: ARView?
    private var lastRecount = Date.distantPast

    /// Кэш локального AABB якоря: пока число вершин не изменилось, вершины не перечитываем.
    private struct AnchorBox {
        var count: Int
        var lo: SIMD3<Float>
        var hi: SIMD3<Float>
    }
    private var anchorBoxes: [UUID: AnchorBox] = [:]

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
        anchorBoxes.removeAll()
        vertexCount = 0
        faceCount = 0
        anchorCount = 0
        sizeMeters = .zero
        smartSize = nil
        smartMethod = nil
        smartBusy = false
        trackingWarning = nil
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

    // MARK: - Умный габарит

    /// Габарит по осям предмета, а не по осям мира.
    /// Тяжелее, чем AABB (десятки тысяч граней), поэтому не на каждом кадре.
    func computeSmartBox() {
        guard !anchors.isEmpty else {
            status = "Меш пуст: сначала просканируйте объект"
            return
        }
        guard !smartBusy else { return }
        smartBusy = true
        status = "Считаю габарит по осям предмета…"
        let snapshot = Array(anchors.values)

        Task.detached(priority: .userInitiated) {
            let result = SmartBox.measure(anchors: snapshot)
            await MainActor.run {
                self.smartBusy = false
                if let result = result {
                    self.smartSize = result.size
                    self.smartMethod = result.method
                    self.status = String(
                        format: "Габарит: %.1f × %.1f × %.1f мм",
                        result.size.x * 1000, result.size.y * 1000, result.size.z * 1000
                    )
                } else {
                    self.smartSize = nil
                    self.smartMethod = nil
                    self.status = "Не хватило данных: обойдите объект с трёх сторон"
                }
            }
        }
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
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

        for anchor in anchors.values {
            let count = anchor.geometry.vertices.count
            vertices += count
            faces += anchor.geometry.faces.count
            guard count > 0 else { continue }
            let box = worldBox(for: anchor)
            lo = simd_min(lo, box.lo)
            hi = simd_max(hi, box.hi)
        }

        vertexCount = vertices
        faceCount = faces
        anchorCount = anchors.count
        if vertices > 0, lo.x <= hi.x, hi.x.isFinite {
            sizeMeters = hi - lo
        } else {
            sizeMeters = .zero
        }
    }

    /// Габарит одного якоря в мировых координатах.
    private func worldBox(for anchor: ARMeshAnchor) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let geometry = anchor.geometry
        let count = geometry.vertices.count

        var localLo: SIMD3<Float>
        var localHi: SIMD3<Float>
        if let cached = anchorBoxes[anchor.identifier], cached.count == count {
            localLo = cached.lo
            localHi = cached.hi
        } else {
            let base = geometry.vertices.buffer.contents().advanced(by: geometry.vertices.offset)
            let stride = geometry.vertices.stride
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            for index in 0..<count {
                let vertex = base.advanced(by: index * stride)
                    .assumingMemoryBound(to: Float32.self)
                let point = SIMD3<Float>(vertex[0], vertex[1], vertex[2])
                lo = simd_min(lo, point)
                hi = simd_max(hi, point)
            }
            localLo = lo
            localHi = hi
            anchorBoxes[anchor.identifier] = AnchorBox(count: count, lo: lo, hi: hi)
        }

        var worldLo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var worldHi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for x in [localLo.x, localHi.x] {
            for y in [localLo.y, localHi.y] {
                for z in [localLo.z, localHi.z] {
                    let corner = anchor.transform * SIMD4<Float>(x, y, z, 1)
                    let point = SIMD3<Float>(corner.x, corner.y, corner.z)
                    worldLo = simd_min(worldLo, point)
                    worldHi = simd_max(worldHi, point)
                }
            }
        }
        return (worldLo, worldHi)
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
                self.anchorBoxes[identifier] = nil
            }
            self.recount()
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let warning: String?
        switch camera.trackingState {
        case .normal:
            warning = nil
        case .notAvailable:
            warning = "Трекинг недоступен: нужно больше света и деталей"
        case .limited(let reason):
            switch reason {
            case .initializing:
                warning = "Инициализация — поводите телефоном"
            case .excessiveMotion:
                warning = "Слишком быстро — ведите телефон медленнее"
            case .insufficientFeatures:
                warning = "Мало деталей: наведите на текстурированную поверхность"
            case .relocalizing:
                warning = "Восстановление трекинга…"
            @unknown default:
                warning = "Трекинг ограничен"
            }
        @unknown default:
            warning = "Трекинг ограничен"
        }
        Task { @MainActor in
            self.trackingWarning = warning
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
