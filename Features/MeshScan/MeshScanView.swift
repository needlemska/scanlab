import SwiftUI
import RealityKit

struct MeshScanView: View {
    @StateObject private var scan = MeshScanSession()

    var body: some View {
        ZStack {
            MeshARContainer(scan: scan)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                statsBar
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    scan.isScanning ? scan.stop() : scan.start()
                } label: {
                    Label(scan.isScanning ? "Пауза" : "Старт",
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

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.environment.sceneUnderstanding.options = [.occlusion]
        view.debugOptions = [.showSceneUnderstanding]
        scan.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
