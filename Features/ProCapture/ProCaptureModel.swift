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
        // yawDegrees накапливается и может уйти за 360° в любую сторону.
        let wrapped = yawDegrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let index = Int((positive / sectorStep).rounded(.down))
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
    /// Расширение текущей серии: если JPEG недоступен, фотоустройство отдаст HEIC,
    /// и писать такие байты в файл `.jpg` нельзя — фотограмметрия их не прочитает.
    private var photoExtension = "jpg"
    /// Отложенный кадр серии. Без хэндла stop() не может его отменить,
    /// и «Снимаю…» залипает после ухода с вкладки.
    private var pendingShot: DispatchWorkItem?
    /// Значения на момент затвора: в делегате они читались на сотни мс позже,
    /// на 24 секторах это промах на целый сектор.
    private var pendingYaw: Double = 0
    private var pendingSector = 0
    private var sessionObservers: [NSObjectProtocol] = []

    let shutterChoices: [Double] = [1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1]

    /// Slider падает на пустом диапазоне, поэтому всегда отдаём валидный.
    var safeISORange: ClosedRange<Float> {
        isoRange.lowerBound < isoRange.upperBound ? isoRange : 25...3200
    }

    // MARK: - Жизненный цикл

    func start() {
        // Без явной проверки прав AVCaptureSession молча не стартует, а пользователь
        // видит «Готово. Наведите на объект.» и чёрный экран.
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .denied || auth == .restricted {
            status = "Разрешите камеру: Настройки → ScanLab → Камера"
            errorText = "Нет доступа к камере"
            return
        }
        if auth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.start()
                } else {
                    self.ui {
                        self.status = "Разрешите камеру: Настройки → ScanLab → Камера"
                        self.errorText = "Нет доступа к камере"
                    }
                }
            }
            return
        }

        observeSession()

        queue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.applySettingsLocked()

            let running = self.session.isRunning
            self.ui {
                self.isReady = running
                if running {
                    if self.errorText == nil { self.status = "Готово. Наведите на объект." }
                } else if self.errorText == nil {
                    self.status = "Камера не запустилась"
                }
            }
        }
    }

    func stop() {
        tracker.stop()
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingShot?.cancel()
            self.pendingShot = nil
            self.remaining = 0
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.ui {
                self.isCapturing = false
                self.isReady = false
            }
        }
    }

    /// iOS останавливает камеру при уходе в фон и при звонке. Без подписки
    /// isReady остаётся true, и серия стартует на уже мёртвой сессии.
    private func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] _ in
            self?.isReady = false
            self?.status = "Камера прервана: закройте другие приложения с камерой"
        })

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            self?.start()
        })

        sessionObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !self.session.isRunning { self.start() }
        })
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
        // Формат выбираем сами: нужен тот, что умеет отдавать карту глубины.
        // Пресет .photo перекрывает activeFormat своим, поэтому .inputPriority.
        session.sessionPreset = .inputPriority

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
            // Иначе повторный заход на вкладку уже не попробует открыть камеру.
            configured = false
            ui {
                self.status = "Камера недоступна"
                self.errorText = "Не удалось открыть камеру"
            }
            return
        }

        // Без формата с поддержкой глубины photo.depthData всегда nil:
        // у LiDAR-устройства пресетный формат глубину не отдаёт.
        var depthFormatChosen = false
        if let depthFormat = device.formats.last(where: { !$0.supportedDepthDataFormats.isEmpty }) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = depthFormat
                // Первый поддерживаемый формат глубины: у LiDAR-устройств он один-два
                // и оба дают одинаковую точность — сортировать по размеру не за чем.
                if let depthDataFormat = depthFormat.supportedDepthDataFormats.first {
                    device.activeDepthDataFormat = depthDataFormat
                }
                device.unlockForConfiguration()
                depthFormatChosen = true
            } catch {
                depthFormatChosen = false
            }
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            configured = false
            ui {
                self.status = "Камера занята"
                self.errorText = "Не удалось подключить камеру к сессии"
            }
            return
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            configured = false
            ui {
                self.status = "Камера не отдаёт фото"
                self.errorText = "Не удалось подключить фото-выход"
            }
            return
        }
        session.addOutput(output)

        output.maxPhotoQualityPrioritization = .quality
        if output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }

        session.commitConfiguration()

        let depthOn = output.isDepthDataDeliveryEnabled
        let depthNote: String? = depthOn ? nil
            : (depthFormatChosen ? "Глубина недоступна для этого формата" : "Глубина LiDAR недоступна")

        let format = device.activeFormat
        let isoRange = format.minISO...format.maxISO
        let minShutter = max(format.minExposureDuration.seconds, 1.0 / 8000.0)
        let maxShutter = min(max(format.maxExposureDuration.seconds, 0.5), 2.0)

        self.device = device
        ui {
            self.isoRange = isoRange
            self.shutterRange = minShutter...maxShutter
            self.iso = min(max(100, isoRange.lowerBound), isoRange.upperBound)
            if let depthNote { self.errorText = depthNote }
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
            status = "Гироскоп недоступен — обход по кругу выключен"
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
        photoExtension = "jpg"
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
            photoExtension = "jpg"
        } else {
            settings = AVCapturePhotoSettings()
            photoExtension = output.availablePhotoCodecTypes.contains(.hevc) ? "heic" : "jpg"
        }
        settings.photoQualityPrioritization = .quality
        if output.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = true
        }

        // Позицию фиксируем в момент затвора: делегат приходит позже,
        // а за это время телефон успевает повернуться на сектор.
        pendingYaw = yawDegrees
        pendingSector = currentSector

        output.capturePhoto(with: settings, delegate: self)
    }

    private func finishBurst() {
        guard let folder else {
            ui { self.isCapturing = false }
            return
        }
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
            "note": "img_%03d.jpg или .heic — фото; img_%03d_depth.f32 — сырая глубина LiDAR (Float32, построчно, ширина×высота из shots[].depthSize)"
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
        // Следующий кадр планируем в любом случае: иначе один сбой
        // (перегрев, занятый буфер) навсегда вешает всю серию.
        defer {
            queue.async { [weak self] in
                guard let self else { return }
                let work = DispatchWorkItem { [weak self] in self?.shootNext() }
                self.pendingShot?.cancel()
                self.pendingShot = work
                self.queue.asyncAfter(deadline: .now() + self.burstInterval, execute: work)
            }
        }

        if let error {
            ui {
                self.errorText = "Кадр не снялся: \(error.localizedDescription)"
                self.status = "Сбой камеры"
            }
        }

        guard error == nil, let folder else { return }

        fileIndex += 1
        let base = String(format: "img_%03d", fileIndex)
        let photoName = base + "." + photoExtension

        guard let data = photo.fileDataRepresentation() else {
            ui { self.status = "Кадр \(base) не сохранился: нет данных" }
            return
        }
        do {
            try data.write(to: folder.appendingPathComponent(photoName), options: .atomic)
        } catch {
            ui { self.status = "Кадр не записался: \(error.localizedDescription)" }
            return
        }

        var shot: [String: Any] = [
            "file": photoName,
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
            shot["yawDeg"] = pendingYaw
            shot["sector"] = pendingSector
        }

        shots.append(shot)

        let index = fileIndex
        let sector = pendingSector
        ui {
            self.shotCount = index
            if self.turntableMode {
                self.coveredSectors.insert(sector)
                self.status = "Сектор \(sector + 1)/\(self.sectorsTotal) · закрыто \(self.coveredSectors.count)"
            }
        }
    }
}
