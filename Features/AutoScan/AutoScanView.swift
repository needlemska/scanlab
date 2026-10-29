import SwiftUI
import ARKit
import RealityKit

/// Главный экран «просто навёл и обошёл»: кадры снимаются сами.
struct AutoScanView: View {
    @StateObject private var model = AutoScanModel()
    @StateObject private var photogram = PhotogramModel()

    var body: some View {
        ZStack {
            ScanARContainer(model: model)
                .ignoresSafeArea()

            VStack {
                coverageCard
                Spacer()
                controls
            }
            .padding()
        }
        .background(Color.black)
    }

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ring
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hint)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.isScanning
                         ? "Кадров: \(model.shots) · закрыто \(Int((model.coverage * 100).rounded())) %"
                         : "Нажмите «Старт» и обойдите предмет")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            if photogram.isRunning {
                ProgressView(value: photogram.progress)
                    .tint(.green)
                Text(photogram.stage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            } else if let message = photogram.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(model.coverage, 0), 1)))
                .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: model.coverage >= 0.95 ? "checkmark" : "viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 48, height: 48)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle("Снимать автоматически", isOn: $model.autoShoot)
                .toggleStyle(.switch)
                .tint(.green)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())

            HStack(spacing: 10) {
                if model.isScanning {
                    Button {
                        model.stopScan()
                    } label: {
                        label("Стоп", "stop.circle.fill")
                    }
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        label("Старт", "camera.circle.fill")
                    }
                }

                Button {
                    build()
                } label: {
                    label(photogram.isRunning ? "Собираю…" : "Собрать 3D", "cube.transparent")
                }
                .disabled(photogram.isRunning || model.shots < 12 || model.folder == nil)

                Button {
                    model.reset()
                } label: {
                    label("Заново", "arrow.counterclockwise.circle.fill")
                }
                .disabled(photogram.isRunning)
            }
        }
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    private func build() {
        guard let folder = model.folder else { return }
        model.stopScan()
        Task {
            await photogram.run(folder: folder)
        }
    }
}

/// ARView, чьи кадры уходят в модель.
struct ScanARContainer: UIViewRepresentable {
    let model: AutoScanModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = context.coordinator
        model.mount(view.session)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        private let model: AutoScanModel

        init(model: AutoScanModel) {
            self.model = model
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            Task { @MainActor in
                model.ingest(frame, session: session)
            }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor in
                model.note(sessionError: error.localizedDescription)
            }
        }
    }
}
