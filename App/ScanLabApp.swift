import SwiftUI

@main
struct ScanLabApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var selection = RootView.initialTab

    /// Начальная вкладка. Обычно 0; в симуляторе можно переопределить переменной
    /// окружения `SCANLAB_TAB` (0…4), чтобы снять экран конкретной вкладки без тапов.
    /// `SCANLAB_DIAGNOSE=1` открывает «Тест» и запускает самопроверку в файл.
    static var initialTab: Int {
        if let raw = ProcessInfo.processInfo.environment["SCANLAB_TAB"],
           let value = Int(raw), (0...4).contains(value) {
            return value
        }
        if ProcessInfo.processInfo.environment["SCANLAB_DIAGNOSE"] == "1" {
            return 4
        }
        return 0
    }

    var body: some View {
        TabView(selection: $selection) {
            MeshScanView()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
                .tag(0)

            ProCaptureView()
                .tabItem { Label("Фото", systemImage: "camera.aperture") }
                .tag(1)

            Scan3DTabView()
                .tabItem { Label("Скан", systemImage: "viewfinder") }
                .tag(2)

            LibraryView()
                .tabItem { Label("Сканы", systemImage: "folder") }
                .tag(3)

            DiagnosticsView()
                .tabItem { Label("Тест", systemImage: "checkmark.seal") }
                .tag(4)
        }
    }
}
