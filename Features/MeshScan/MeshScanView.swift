import SwiftUI
import RealityKit
import UIKit

struct MeshScanView: View {
    @StateObject private var scan = MeshScanSession()
    @State private var knownText = "100"
    /// У decimalPad нет кнопки «Готово»: без явного фокуса клавиатура закрывала
    /// нижние кнопки и убрать её было нечем.
    @FocusState private var knownFocused: Bool

    var body: some View {
        ZStack {
            MeshARContainer(scan: scan)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                statsBar
                if let warning = scan.trackingWarning {
                    warningBanner(warning)
                }
                sizeLine
                smartLine
                rulerBar
                calibrationBar
                Spacer(minLength: 0)
                hint
                controls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert("Ошибка", isPresented: errorBinding) {
            Button("OK", role: .cancel) { scan.errorText = nil }
        } message: {
            Text(scan.errorText ?? "")
        }
        // ARSession живёт отдельно от UIView: при уходе на другую вкладку камера
        // остаётся занятой ARKit, и «Фото» не может открыть свой AVCaptureSession.
        .onDisappear { scan.stop() }
        // Автопилот: включается переменными окружения при запуске через DVT (см. runAutoPilot).
        .task { await runAutoPilot() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { knownFocused = false }
            }
        }
    }

    // MARK: - Автопилот

    /// Полный проход «старт → скан → стоп → калибровка эталоном → экспорт» по таймеру,
    /// без единого касания экрана.
    ///
    /// Зачем: с Windows нажать на экран телефона нечем — DVT умеет запускать приложение,
    /// снимать скриншот и читать логи, но тапов не умеет. Поэтому «проверить самому от начала
    /// до конца» можно только так: приложение само делает все шаги и пишет отчёт файлом,
    /// который забирается с компьютера по USB.
    ///
    /// Включается при запуске через `developer dvt launch --env`:
    /// - `SCANLAB_AUTO` — сколько секунд сканировать (например `25`);
    /// - `SCANLAB_AUTO_REF` — `a4`, `card` или `coin` (необязательно: автокалибровка эталоном);
    /// - `SCANLAB_AUTO_WAIT` — сколько ждать экспорт, секунды (по умолчанию 120).
    private func runAutoPilot() async {
        let env = ProcessInfo.processInfo.environment
        guard let rawSeconds = env["SCANLAB_AUTO"],
              let seconds = Double(rawSeconds),
              seconds > 0.5 else { return }

        let kind = env["SCANLAB_AUTO_REF"].flatMap { ReferenceKind(rawValue: $0) }
        let maxExportWait = env["SCANLAB_AUTO_WAIT"].flatMap { Double($0) } ?? 120

        // Экран не должен погаснуть посреди скана: локскрин останавливает ARKit-сессию,
        // и отчёт получится пустым.
        UIApplication.shared.isIdleTimerDisabled = true

        let startedAt = Date()
        scan.reset()
        scan.start()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        let scannedFor = Date().timeIntervalSince(startedAt)
        scan.stop()

        if let kind = kind {
            // Vision ищет прямоугольник на последнем кадре с картой глубины, а он появляется
            // не мгновенно после остановки — даём камере отдать ещё несколько кадров.
            try? await Task.sleep(nanoseconds: 800_000_000)
            scan.calibrate(withReference: kind)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let statusAfterStop = scan.status
        scan.finishAndExport()

        var waited = 0.0
        while scan.isBusy && waited < maxExportWait {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 0.5
        }
        UIApplication.shared.isIdleTimerDisabled = false

        let report = autoPilotReport(
            startedAt: startedAt,
            scannedFor: scannedFor,
            kind: kind,
            statusAfterStop: statusAfterStop,
            exportSeconds: waited
        )
        try? report.write(
            to: Paths.scans.appendingPathComponent("autopilot-latest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Отчёт автопилота в JSON: те же поля читает `tools/ios_autopilot.py`.
    private func autoPilotReport(
        startedAt: Date,
        scannedFor: Double,
        kind: ReferenceKind?,
        statusAfterStop: String,
        exportSeconds: Double
    ) -> String {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "time": iso.string(from: startedAt),
            "finishedAt": iso.string(from: Date()),
            "scanSeconds": (scannedFor * 10).rounded() / 10,
            "exportSeconds": (exportSeconds * 10).rounded() / 10,
            "statusAfterStop": statusAfterStop,
            "status": scan.status,
            "anchors": scan.anchorCount,
            "vertices": scan.vertexCount,
            "triangles": scan.faceCount,
            "sizeMeters": [
                Double(scan.sizeMeters.x),
                Double(scan.sizeMeters.y),
                Double(scan.sizeMeters.z),
            ],
            "calibrationFactor": (scan.calibrationFactor * 10_000).rounded() / 10_000,
        ]
        if let kind = kind {
            payload["reference"] = kind.rawValue
        }
        if let smart = scan.smartSize {
            payload["smartMeters"] = [Double(smart.x), Double(smart.y), Double(smart.z)]
            payload["smartMethod"] = scan.smartMethod ?? ""
        }
        if let known = scan.calibrationKnownMM {
            payload["calibrationKnownMM"] = known
        }
        if let measured = scan.calibrationMeasuredMM {
            payload["calibrationMeasuredMM"] = measured
        }
        if let archive = scan.lastArchive {
            payload["archive"] = archive.lastPathComponent
        }
        if let error = scan.errorText {
            payload["error"] = error
        }
        payload["result"] = (scan.lastArchive != nil && scan.errorText == nil) ? "ok" : "failed"

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{\"result\": \"failed\", \"error\": \"report not serialized\"}"
        }
        return text
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { scan.errorText != nil },
            set: { if !$0 { scan.errorText = nil } }
        )
    }

    private var statsBar: some View {
        HStack(spacing: 10) {
            chip("вершин", scan.vertexCount)
            chip("полигонов", scan.faceCount)
            chip("кусков", scan.anchorCount)
            Spacer(minLength: 0)
            Text(appVersion)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private var sizeLine: some View {
        Group {
            if scan.sizeMeters.x > 0 {
                Text("Габарит: \(mm(scan.sizeMeters.x * scale)) x \(mm(scan.sizeMeters.y * scale)) x \(mm(scan.sizeMeters.z * scale)) мм")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("Габарит появится, когда LiDAR увидит объект")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Поправка калибровки, применённая к показываемым размерам.
    private var scale: Float { Float(scan.calibrationFactor) }

    private func mm(_ meters: Float) -> String {
        String(format: "%.0f", Double(meters * 1000))
    }

    /// Габарит по осям предмета: AABB зависит от того, как повёрнута коробка,
    /// а этот считается от плоскостей самого предмета.
    private var smartLine: some View {
        HStack(spacing: 8) {
            if let size = scan.smartSize {
                Text("Предмет: \(mm(size.x * scale)) x \(mm(size.y * scale)) x \(mm(size.z * scale)) мм")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.green)
                Text(scan.smartMethod == "TABLE" ? "от стола" : "по осям")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Предмет: нажмите «Умный», чтобы померить по осям предмета")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            Button {
                scan.computeSmartBox()
            } label: {
                if scan.smartBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .disabled(scan.smartBusy || scan.anchorCount == 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundStyle(.white)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rulerBar: some View {
        HStack(spacing: 10) {
            if let distance = scan.rulerDistance {
                Text(String(format: "%.1f мм", Double(distance * 1000)))
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(.green)
                Button {
                    scan.clearRuler()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else {
                Text(scan.rulerPoints.isEmpty
                     ? "Линейка: тапните две точки на объекте"
                     : "Точка A есть — тапните точку B")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Калибровка по эталону: две точки на детали известной длины + ввод этой длины.
    /// LiDAR ошибается систематически на 1–3 %, поправка переносится на весь меш.
    private var calibrationBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ReferenceKind.allCases) { kind in
                    Button(kind.title) {
                        scan.calibrate(withReference: kind)
                    }
                }
            } label: {
                Image(systemName: "viewfinder")
                    .foregroundStyle(Color.cyan)
            }
            .disabled(scan.isBusy)
            if let known = scan.calibrationKnownMM, let measured = scan.calibrationMeasuredMM {
                Image(systemName: "ruler.fill")
                    .foregroundStyle(Color.green)
                Text(String(format: "эталон %.1f мм, замер %.1f, ×%.4f",
                            known, measured, scan.calibrationFactor))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    scan.clearCalibration()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Image(systemName: "ruler")
                    .foregroundStyle(.white.opacity(0.7))
                Text("эталон, мм")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                TextField("100", text: $knownText)
                    .keyboardType(.decimalPad)
                    .focused($knownFocused)
                    .multilineTextAlignment(.center)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(width: 72)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                Button("Калибровать") {
                    knownFocused = false
                    let text = knownText.replacingOccurrences(of: ",", with: ".")
                    scan.calibrate(withKnownMM: Double(text) ?? 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(scan.rulerDistance == nil ? Color.white.opacity(0.4) : Color.green)
                .disabled(scan.rulerDistance == nil)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hint: some View {
        Text(scan.status)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let archive = scan.lastArchive {
                ShareLink(item: archive) {
                    Label("Отдать архив на ПК", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                Button {
                    if scan.isScanning {
                        scan.stop()
                    } else if scan.anchorCount > 0 {
                        // после «Паузы» продолжаем ту же сцену, а не начинаем новую
                        scan.resume()
                    } else {
                        scan.start()
                    }
                } label: {
                    Label(scan.isScanning ? "Пауза" : (scan.anchorCount > 0 ? "Продолжить" : "Старт"),
                          systemImage: scan.isScanning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }

                Button {
                    scan.finishAndExport()
                } label: {
                    Label(scan.isBusy ? "…" : "Экспорт", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.green.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .disabled(scan.isBusy || scan.anchorCount == 0)

                Button {
                    scan.reset()
                } label: {
                    Image(systemName: "trash")
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

struct MeshARContainer: UIViewRepresentable {
    let scan: MeshScanSession

    func makeCoordinator() -> Coordinator {
        Coordinator(scan: scan)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.environment.sceneUnderstanding.options = [.occlusion]
        view.debugOptions = [.showSceneUnderstanding]
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        scan.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    /// Жест приходит на главном потоке, но метод сессии помечен @MainActor,
    /// поэтому прыгаем в него через Task — так не спорим с изоляцией.
    final class Coordinator: NSObject {
        private let scan: MeshScanSession

        init(scan: MeshScanSession) {
            self.scan = scan
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let size = view.bounds.size
            Task { @MainActor in
                self.scan.addRulerPoint(at: location, in: size)
            }
        }
    }
}
