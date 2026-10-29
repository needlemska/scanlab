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
    var body: some View {
        TabView {
            MeshScanView()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }

            ProCaptureView()
                .tabItem { Label("Фото", systemImage: "camera.aperture") }

            CaptureTabView()
                .tabItem { Label("3D", systemImage: "viewfinder") }

            LibraryView()
                .tabItem { Label("Сканы", systemImage: "folder") }

            DiagnosticsView()
                .tabItem { Label("Тест", systemImage: "checkmark.seal") }
        }
    }
}
