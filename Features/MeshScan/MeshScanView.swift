import SwiftUI
import RealityKit
import UIKit

struct MeshScanView: View {
    @StateObject private var scan = MeshScanSession()

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
                Text("Габарит: \(mm(scan.sizeMeters.x)) x \(mm(scan.sizeMeters.y)) x \(mm(scan.sizeMeters.z)) мм")
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

    private func mm(_ meters: Float) -> String {
        String(format: "%.0f", Double(meters * 1000))
    }

    /// Габарит по осям предмета: AABB зависит от того, как повёрнута коробка,
    /// а этот считается от плоскостей самого предмета.
    private var smartLine: some View {
        HStack(spacing: 8) {
            if let size = scan.smartSize {
                Text("Предмет: \(mm(size.x)) x \(mm(size.y)) x \(mm(size.z)) мм")
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
