import SwiftUI
import RealityKit
import UIKit

/// Сессия Object Capture (iOS 17): приложение само подсказывает, как обходить объект,
/// и сохраняет кадры прямо в папку скана. Дальше — тот же `PhotogramModel`, что и в
/// «Библиотеке», поэтому модель собирается на телефоне.
///
/// Важные правила API, из-за которых раньше ломался экран «3D»:
/// - `start(imagesDirectory:configuration:)` допустим только один раз на сессии;
/// - `startDetecting()` работает только в состоянии `.ready`, в `.initializing` возвращает false;
/// - после `cancel()` сессия уходит в `.failed` и переиспользовать её нельзя — нужна новая.
@MainActor
final class CaptureSessionModel: ObservableObject {
    @Published private(set) var session = ObjectCaptureSession()

    @Published private(set) var state: ObjectCaptureSession.CaptureState = .initializing
    @Published private(set) var shots = 0
    @Published private(set) var passDone = false
    @Published private(set) var isPaused = false
    @Published private(set) var folder: URL?
    @Published var message: String?

    private var tasks: [Task<Void, Never>] = []
    private var detectRequested = false
    private var detectAttempts = 0

    var canBeginCapture: Bool {
        if case .detecting = state { return true }
        return false
    }

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var isStarting: Bool {
        if case .initializing = state { return folder != nil }
        return false
    }

    /// Папка скана создаётся сразу: кадры пишутся в Documents, значит переживут переподпись.
    func start() {
        guard folder == nil else { return }

        // Сессию, которая уже отменялась или падала, API оживить не даёт.
        if hasFailed {
            session = ObjectCaptureSession()
            state = .initializing
        }

        let target = Paths.newScanDirectory(prefix: "photo3d")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            message = "Не удалось создать папку: \(error.localizedDescription)"
            return
        }

        detectRequested = false
        detectAttempts = 0
        shots = 0
        passDone = false
        isPaused = false
        message = nil

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = nil
        session.start(imagesDirectory: target, configuration: configuration)
        folder = target
        watch()
    }

    /// Отменить текущий скан и начать новый: «Заново» после ошибки.
    func restart() {
        cancel()
        message = nil
        start()
    }

    func beginCapture() {
        session.startCapturing()
    }

    func pause() {
        session.pause()
        isPaused = true
    }

    func resume() {
        session.resume()
        isPaused = false
    }

    func flip() {
        session.beginNewScanPassAfterFlip()
        passDone = false
    }

    func shot() {
        guard session.canRequestImageCapture else { return }
        session.requestImageCapture()
    }

    func finish() {
        session.finish()
    }

    func cancel() {
        stopWatching()
        if folder != nil {
            session.cancel()
        }
        session = ObjectCaptureSession()
        folder = nil
        state = .initializing
        shots = 0
        passDone = false
        isPaused = false
        detectRequested = false
        detectAttempts = 0
        message = "Сканирование отменено"
    }

    /// Автозапуск определения объекта, как только сессия готова.
    /// Без этого экран «3D» висел на «Готовлю камеру…» и кнопка съёмки не появлялась.
    private func requestDetection() {
        guard !detectRequested else { return }
        guard case .ready = state else { return }
        detectRequested = true
        detectAttempts += 1
        if session.startDetecting() {
            message = "Выберите объект в рамке"
            return
        }
        // Плоскость не нашлась: остаёмся в .ready и пробуем ещё раз чуть позже.
        detectRequested = false
        if detectAttempts < 20 {
            message = "Наведите телефон на предмет: нужна поверхность под ним"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.requestDetection()
            }
        } else {
            message = "Не вижу плоскость под предметом. Положите объект на стол и нажмите «Повторить»"
        }
    }

    private func watch() {
        stopWatching()
        let current = session
        tasks.append(Task { @MainActor in
            for await value in current.stateUpdates {
                self.state = value
                switch value {
                case .ready:
                    self.requestDetection()
                case .capturing:
                    self.isPaused = false
                case .finishing, .completed:
                    self.isPaused = false
                case .failed(let error):
                    self.message = "Ошибка: \(error.localizedDescription)"
                default:
                    break
                }
            }
        })
        tasks.append(Task { @MainActor in
            for await value in current.numberOfShotsTakenUpdates {
                self.shots = value
            }
        })
        tasks.append(Task { @MainActor in
            for await value in current.userCompletedScanPassUpdates {
                self.passDone = value
            }
        })
    }

    private func stopWatching() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }
}

struct CaptureTabView: View {
    @StateObject private var model = CaptureSessionModel()
    @StateObject private var photogram = PhotogramModel()

    var body: some View {
        Group {
            if ObjectCaptureSession.isSupported {
                capture
            } else {
                unsupported
            }
        }
    }

    private var unsupported: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Object Capture недоступен на этом устройстве")
                .font(.headline)
            Text("Нужен iPhone или iPad с LiDAR. Для остальных есть «LiDAR» и «Фото».")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var capture: some View {
        ZStack(alignment: .bottom) {
            ObjectCaptureView(session: model.session)
                .id(ObjectIdentifier(model.session))
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    chip(text: stateText)
                    if model.shots > 0 {
                        chip(text: "\(model.shots) кадров")
                    }
                    if model.passDone {
                        chip(text: "круг пройден", color: .green)
                    }
                }

                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if photogram.isRunning {
                    ProgressView(value: photogram.progress)
                        .tint(.green)
                    Text(photogram.stage)
                        .font(.caption)
                } else if let message = photogram.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.isCompleted {
                    Button {
                        guard let folder = model.folder else { return }
                        Task { await photogram.run(folder: folder) }
                    } label: {
                        Label("Собрать 3D", systemImage: "cube.transparent")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(photogram.isRunning)
                }

                controls
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .task { model.start() }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            if model.canBeginCapture {
                Button("Начать съёмку") { model.beginCapture() }
                    .buttonStyle(.borderedProminent)
            }

            if model.isCapturing {
                if model.isPaused {
                    Button("Продолжить") { model.resume() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Пауза") { model.pause() }
                        .buttonStyle(.bordered)
                }
                if model.passDone {
                    Button("Перевернул") { model.flip() }
                        .buttonStyle(.bordered)
                }
                Button("Стоп") { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            if model.hasFailed || model.folder == nil {
                Button(model.hasFailed ? "Повторить" : "Новый скан") { model.restart() }
                    .buttonStyle(.borderedProminent)
            }

            if model.folder != nil && !model.isCompleted {
                Button(role: .destructive) {
                    model.cancel()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func chip(text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private var stateText: String {
        switch model.state {
        case .initializing:
            return "Готовлю камеру…"
        case .ready:
            return "Наведите камеру на объект"
        case .detecting:
            return "Выберите объект в рамке"
        case .capturing:
            return model.isPaused ? "Пауза" : "Медленно обходите объект"
        case .finishing:
            return "Сохраняю кадры…"
        case .completed:
            return "Готово: \(model.shots) кадров"
        case .failed(let error):
            return "Ошибка: \(error.localizedDescription)"
        }
    }
}
