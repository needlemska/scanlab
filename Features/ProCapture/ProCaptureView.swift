import SwiftUI
import AVFoundation
import UIKit

struct ProCaptureView: View {
    @StateObject private var model = ProCaptureModel()

    var body: some View {
        ZStack {
            CameraPreview(session: model.session)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer(minLength: 0)
                panel
            }
            .padding(16)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Ошибка камеры", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )
    }

    private var topBar: some View {
        HStack {
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.5), in: Capsule())

            Spacer()

            if model.isCapturing {
                Text("\(model.shotCount)/\(model.burstCount)")
                    .font(.system(.footnote, design: .monospaced).bold())
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            Toggle("Ручная экспозиция", isOn: $model.manualExposure)
                .onChange(of: model.manualExposure) { _, _ in model.applySettings() }

            if model.manualExposure {
                HStack {
                    Text("ISO")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 34, alignment: .leading)
                    Slider(value: $model.iso, in: model.safeISORange)
                        .onEditingChanged { editing in
                            if !editing { model.applySettings() }
                        }
                    Text("\(Int(model.iso))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Выдержка")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Menu {
                        ForEach(model.shutterChoices, id: \.self) { value in
                            Button("1/\(Int(value))") {
                                model.shutterDenominator = value
                                model.applySettings()
                            }
                        }
                    } label: {
                        Text("1/\(Int(model.shutterDenominator))")
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack {
                Text("Фокус")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(model.focusLocked ? "Зафиксирован" : "Автофокус") {
                    model.toggleFocusLock()
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(model.focusLocked ? .orange.opacity(0.7) : .white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
            }

            HStack {
                Text("Кадров")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Stepper("\(model.burstCount)", value: $model.burstCount, in: 1...60)
                    .foregroundStyle(.white)
                    .fixedSize()
            }

            HStack {
                Text("Интервал")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                Slider(value: $model.burstInterval, in: 0.3...2.0)
                Text(String(format: "%.1f с", model.burstInterval))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 48, alignment: .trailing)
            }

            actionButtons
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        .tint(.white)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let archive = model.lastArchive {
                ShareLink(item: archive) {
                    Label("Отдать кадры на ПК", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }

            Button {
                model.startBurst()
            } label: {
                Label(model.isCapturing ? "Снимаю…" : "Снять серию",
                      systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(model.isReady && !model.isCapturing ? .red.opacity(0.85) : .gray.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .disabled(!model.isReady || model.isCapturing)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("layer is not AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}
