import SwiftUI

/// Вкладка «Скан»: автоматический обход предмета — основной режим,
/// Apple Object Capture — запасной, когда нужен его меш и USDZ.
struct Scan3DTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "Авто"
        case apple = "Apple 3D"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .auto

    var body: some View {
        VStack(spacing: 0) {
            Picker("Режим", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            switch mode {
            case .auto:
                AutoScanView()
            case .apple:
                CaptureTabView()
            }
        }
        .background(Color.black)
    }
}
