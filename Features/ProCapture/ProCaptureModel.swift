import Foundation
import AVFoundation
import CoreVideo
import UIKit
import Combine

/// Профессиональный фотозахват: ручная экспозиция, фиксированный баланс белого,
/// фиксированный фокус, серия кадров и синхронные карты глубины LiDAR.
///
/// Всё, чего не хватает магазинным приложениям: контроль над камерой и
/// предсказуемый набор файлов для фотограмметрии.
final class ProCaptureModel: NSObject, ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var shotCount = 0
    @Published private(set) var status = "Готовим камеру…"
    @Published private(set) var lastArchive: URL?
    @Published var errorText: String?

    @Published var manualExposure = true
    @Published var iso: Float = 100
    @Published var shutterDenominator: Double = 120
    @Published var burstCount: Int = 12
    @Published var burstInterval: Double = 0.7
    @Published var lockWhiteBalance = true
    @Published var focusLocked = false

    // Поворотный стол: считаем сектора вокруг объекта, чтобы кадры шли равномерно.
    @Published var turntableMode = false
    @Published var sectorCount = 24
    @Published private(set) var yawDegrees: Double = 0
    @Published private(set) var coveredSectors: Set<Int> = []

    private let tracker = TurntableTracker()

    var sectorsTotal: Int { max(4, sectorCount) }

    var sectorStep: Double { 360.0 / Double(sectorsTotal) }

    var currentSector: Int {
        let index = Int((yawDegrees / sectorStep).rounded(.down))
        return min(sectorsTotal - 1, max(0, index))
    }

    var coverageText: String {
        "Секторы: \(coveredSectors.count)/\(sectorsTotal)"
    }

    let session = AVCaptureSession()

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.scanlab.capture", qos: .userInitiated)
    private(set) var device: AVCaptureDevice?
    private(set) var isoRange: ClosedRange<Float> = 25...3200
    private(set) var shutterRange: ClosedRange<Double> = 1.0 / 8000.0 ... 1.0

    private var configured = false
    private var folder: URL?
    private var remaining = 0
    private var fileIndex = 0
    private var shots: [[String: Any]] = []

    let shutterChoices: [Double] = [1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1]

    /// Slider падает на пустом диапазоне, поэтому всегда отдаём валидный.
    var safeISORange: ClosedRange<Float> {
        isoRange.lowerBound < isoRange.upperBound ? isoRange : 25...3200
    }

    // MARK: - Жизненный цикл

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.applySettingsLocked()
        }
    }

    func stop() {
        tracker.stop()
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func applySettings() {
        queue.async { [weak self] in
            self?.applySettingsLocked()
        }
    }

    // MARK: - Настройка

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .photo

        let candidates: [AVCaptureDevice.DeviceType] = [.builtInLiDARDepthCamera, .builtInWideAngleCamera]
        var chosen: AVCaptureDevice?
        for type in candidates {
            if let candidate = AVCaptureDevice.default(type, for: .video, position: .back) {
                chosen = candidate
                break
            }
        }

        guard let device = chosen,
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            ui {
                self.status = "Камера недоступна"
                self.errorText = "Не удалось открыть камеру"
            }
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        if output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }
        output.maxPhotoQualityPrioritization = .quality

        session.commitConfiguration()

        let format = device.activeFormat
        let isoRange = format.minISO...format.maxISO
        let minShutter = max(format.minExposureDuration.seconds, 1.0 / 8000.0)
        let maxShutter = min(max(format.maxExposureDuration.seconds, 0.5), 2.0)

        self.device = device
        ui {
            self.isoRange = isoRange
            self.shutterRange = minShutter...maxShutter
            self.iso = min(max(100, isoRange.lowerBound), isoRange.upperBound)
            self.isReady = true
            self.status = "Готово. Наведите на объект."
        }
    }

    // MARK: - Ручные настройки

    private func applySettingsLocked() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }

        let format = device.activeFormat

        if manualExposure, device.isExposureModeSupported(.custom) {
            let target = 1.0 / max(1.0, shutterDenominator)
            let clamped = min(max(target, format.minExposureDuration.seconds),
                              format.maxExposureDuration.seconds)
            let duration = CMTime(seconds: clamped, preferredTimescale: 1_000_000)
            let isoValue = min(max(iso, format.minISO), format.maxISO)
            device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        if lockWhiteBalance, device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        if focusLocked, device.isFocusModeSupported(.locked) {
            device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    func toggleFocusLock() {
        focusLocked.toggle()
        applySettings()
    }

    // MARK: - Поворотный стол

    func turntableDidChange() {
        if turntableMode {
            startTracking()
        } else {
            tracker.stop()
            yawDegrees = 0
        }
    }

    private func startTracking() {
        guard tracker.isAvailable else {
            turntableMode = false
            status = "Гироскоп недоступен — режим стола выключен"
            return
        }
        tracker.start { [weak self] yaw in
            self?.yawDegrees = yaw
        }
    }

    // MARK: - Съёмка

    func startBurst() {
        guard isReady, !isCapturing else { return }

        let directory = Paths.newScanDirectory(prefix: "photo")
        folder = directory
        fileIndex = 0
        remaining = max(1, burstCount)
        shots.removeAll()
        coveredSectors.removeAll()
        if turntableMode { startTracking() }
        isCapturing = true
        shotCount = 0
        status = "Съёмка \(burstCount) кадров…"

        queue.async { [weak self] in
            guard let self else { return }
            self.applySettingsLocked()
            self.shootNext()
        }
    }

    private func shootNext() {
        guard remaining > 0 else {
            finishBurst()
            return
        }
        remaining -= 1

        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        if output.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = true
        }

        output.capturePhoto(with: settings, delegate: self)
    }

    private func finishBurst() {
        guard let folder else { return }
        writeSessionMeta(to: folder)

        let archive = Paths.zipURL(for: folder)
        try? FileManager.default.removeItem(at: archive)
        var zipped = true
        do {
            try ZipWriter.write(directory: folder, to: archive)
        } catch {
            zipped = false
            print("ScanLab: zip failed — \(error)")
        }

        let count = fileIndex
        ui {
            self.isCapturing = false
            if zipped {
                self.lastArchive = archive
                if self.turntableMode {
                    self.status = "Снято \(count), секторов \(self.coveredSectors.count)/\(self.sectorsTotal)"
                } else {
                    self.status = "Снято \(count) кадров"
                }
            } else {
                self.status = "Кадры сняты, архив не собрался"
            }
        }
    }

    // MARK: - Метаданные

    private func writeSessionMeta(to folder: URL) {
        let meta: [String: Any] = [
            "app": "ScanLab",
            "kind": "photo-set",
            "created": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.model,
            "systemVersion": UIDevice.current.systemVersion,
            "shots": shots,
            "burstInterval": burstInterval,
            "manualExposure": manualExposure,
            "shutterDenominator": shutterDenominator,
            "iso": Double(iso),
            "note": "img_%03d.jpg — фото; img_%03d_depth.f32 — сырая глубина LiDAR (Float32, построчно, ширина×высота из shots[].depthSize)"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("shots.json"))
        }

        let readme = """
        Набор кадров для фотограмметрии.

        img_NNN.jpg          — JPEG, полное разрешение
        img_NNN_depth.f32    — карта глубины LiDAR, Float32 little-endian, построчно
        shots.json           — интринсики камеры, размеры глубины, параметры съёмки

        Пайплайн: RealityCapture / Meshroom / COLMAP — см. pc/PIPELINE.md
        """
        try? readme.write(to: folder.appendingPathComponent("README.txt"),
                          atomically: true, encoding: .utf8)
    }

    // MARK: - Утилиты

    private func ui(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension ProCaptureModel: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // Следующий кадр планируем в любом случае: иначе один сбой
        // (перегрев, занятый буфер) навсегда вешает всю серию.
        defer {
            queue.asyncAfter(deadline: .now() + burstInterval) { [weak self] in
                self?.shootNext()
            }
        }

        guard error == nil, let folder else { return }

        fileIndex += 1
        let base = String(format: "img_%03d", fileIndex)

        if let data = photo.fileDataRepresentation() {
            try? data.write(to: folder.appendingPathComponent(base + ".jpg"))
        }

        var shot: [String: Any] = [
            "file": base + ".jpg",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        if let depth = photo.depthData {
            // В SDK iOS 26 converting(toDepthDataType:) возвращает AVDepthData, а не опционал.
            let converted = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let map = converted.depthDataMap
            CVPixelBufferLockBaseAddress(map, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

            let width = CVPixelBufferGetWidth(map)
            let height = CVPixelBufferGetHeight(map)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

            if let baseAddress = CVPixelBufferGetBaseAddress(map), width > 0, height > 0 {
                var raw = Data(capacity: width * height * 4)
                for row in 0..<height {
                    raw.append(Data(bytes: baseAddress.advanced(by: row * bytesPerRow),
                                    count: width * 4))
                }
                try? raw.write(to: folder.appendingPathComponent(base + "_depth.f32"))
                shot["depthFile"] = base + "_depth.f32"
                shot["depthSize"] = [width, height]
                shot["depthAccuracy"] = converted.depthDataAccuracy.rawValue
            }
        }

        if let calibration = photo.cameraCalibrationData {
            let matrix = calibration.intrinsicMatrix
            let reference = calibration.intrinsicMatrixReferenceDimensions
            shot["intrinsics"] = [
                "fx": Double(matrix.columns.0.x),
                "fy": Double(matrix.columns.1.y),
                "cx": Double(matrix.columns.2.x),
                "cy": Double(matrix.columns.2.y),
                "refWidth": Double(reference.width),
                "refHeight": Double(reference.height)
            ]
        }

        if turntableMode {
            shot["yawDeg"] = yawDegrees
            shot["sector"] = currentSector
        }

        shots.append(shot)

        let index = fileIndex
        let sector = currentSector
        ui {
            self.shotCount = index
            if self.turntableMode {
                self.coveredSectors.insert(sector)
                self.status = "Сектор \(sector + 1)/\(self.sectorsTotal) · закрыто \(self.coveredSectors.count)"
            }
        }
    }
}
