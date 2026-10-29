import Foundation
import RealityKit

/// Фотограмметрия прямо на телефоне: серия кадров → текстурированный USDZ.
///
/// До iOS 17 `PhotogrammetrySession` была только в macOS, поэтому фотограмметрия
/// считалась «только на ПК». На iPhone 15 Pro Max сессия работает локально —
/// компьютер нужен лишь для тяжёлых сцен (сотни кадров, 4K).
///
/// Кадры для сессии копируются в отдельную папку `photogram-input`: рядом с ними
/// в скане лежат `shots.json` и сырые карты глубины `.f32`, которые сессия не
/// должна читать как изображения.
@MainActor
final class PhotogramModel: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage = ""
    @Published private(set) var message: String?
    @Published private(set) var folderName: String?

    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    /// Собирает модель по кадрам из папки скана. Кладёт `model.usdz` рядом с кадрами
    /// и обновляет ZIP-архив папки.
    func run(folder: URL, detail: PhotogrammetrySession.Request.Detail = .medium) async {
        guard !isRunning else { return }
        guard Self.isSupported else {
            message = "Фотограмметрия недоступна на этом устройстве"
            return
        }

        let prepared: (url: URL, count: Int)
        do {
            prepared = try prepareInput(folder: folder)
        } catch {
            message = "Не удалось подготовить кадры: \(error.localizedDescription)"
            return
        }
        let input = prepared.url
        let count = prepared.count

        guard count >= 3 else {
            message = "Нужно хотя бы 3 кадра, а в папке \(count)"
            try? FileManager.default.removeItem(at: input)
            return
        }

        isRunning = true
        folderName = folder.lastPathComponent
        progress = 0
        stage = "Сессия: \(count) кадров"
        message = nil

        let output = folder.appendingPathComponent("model.usdz")
        try? FileManager.default.removeItem(at: output)

        defer {
            isRunning = false
            folderName = nil
            try? FileManager.default.removeItem(at: input)
        }

        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.sampleOrdering = .unordered
            configuration.featureSensitivity = .normal

            let session = try PhotogrammetrySession(input: input, configuration: configuration)
            try session.process(requests: [.modelFile(url: output, detail: detail)])

            for try await event in session.outputs {
                switch event {
                case .requestProgress(_, let fraction):
                    progress = fraction
                    stage = "Строю модель: \(Int(fraction * 100)) %"
                case .requestError(_, let error):
                    message = "Реконструкция не удалась: \(error)"
                    stage = "Ошибка"
                case .processingComplete:
                    stage = "Сессия завершена"
                default:
                    break
                }
            }
        } catch {
            message = error.localizedDescription
            stage = "Ошибка сессии"
            return
        }

        guard FileManager.default.fileExists(atPath: output.path) else {
            message = message ?? "Модель не собралась: нет model.usdz (мало перекрытия между кадрами?)"
            stage = "Без результата"
            return
        }

        // Обновляем архив, чтобы USDZ уехал на компьютер вместе с кадрами.
        stage = "Упаковываю архив…"
        let archive = Paths.zipURL(for: folder)
        try? FileManager.default.removeItem(at: archive)
        try? ZipWriter.write(directory: folder, to: archive)

        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? Int) ?? 0
        message = "Готово: model.usdz, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        stage = "Готово"
        progress = 1
    }

    /// Копирует в отдельную папку только изображения — сессия читает всю папку на вход.
    private func prepareInput(folder: URL) throws -> (url: URL, count: Int) {
        let fm = FileManager.default
        let input = folder.appendingPathComponent("photogram-input")
        try? fm.removeItem(at: input)
        try fm.createDirectory(at: input, withIntermediateDirectories: true)

        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var copied = 0
        for name in names {
            let lower = name.lowercased()
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                    || lower.hasSuffix(".png") || lower.hasSuffix(".heic") else { continue }
            let target = input.appendingPathComponent(name)
            try fm.copyItem(at: folder.appendingPathComponent(name), to: target)
            copied += 1
        }
        return (input, copied)
    }
}
