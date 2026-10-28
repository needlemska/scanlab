import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LibraryView: View {
    @State private var items: [ScanRecord] = []
    @State private var shareItem: ShareItem?
    @State private var isWorking = false
    @StateObject private var wifi = FileServerModel()

    var body: some View {
        NavigationStack {
            List {
                if wifi.running || wifi.message != nil {
                    wifiRow
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        "Пока пусто",
                        systemImage: "cube.transparent",
                        description: Text("Сканы из вкладок LiDAR и Фото появятся здесь.\nФайлы всегда доступны в приложении «Файлы» → На iPhone → ScanLab.")
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(items) { item in
                    row(for: item)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Сканы")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        wifi.toggle()
                    } label: {
                        Image(systemName: wifi.running ? "wifi" : "wifi.slash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var wifiRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: wifi.running ? "wifi" : "wifi.slash")
                    .foregroundStyle(wifi.running ? .green : .secondary)
                Text(wifi.running ? "Выгрузка по Wi-Fi включена" : "Выгрузка по Wi-Fi")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if wifi.running {
                    Button("Выключить") { wifi.toggle() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }

            if let address = wifi.address {
                Text(address)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Откройте этот адрес на компьютере: каждый скан скачается ZIP-архивом.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = wifi.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(for item: ScanRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == "lidar" ? "cube.transparent" : "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(item.kind == "lidar" ? .green : .blue)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(item.formattedSize) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                share(item)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .padding(8)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private func reload() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: Paths.scans,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        items = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { ScanRecord(url: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func share(_ item: ScanRecord) {
        guard !isWorking else { return }
        isWorking = true

        let archive = Paths.zipURL(for: item.url)
        if FileManager.default.fileExists(atPath: archive.path) {
            shareItem = ShareItem(url: archive)
            isWorking = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? ZipWriter.write(directory: item.url, to: archive)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: archive.path) {
                    shareItem = ShareItem(url: archive)
                }
                isWorking = false
            }
        }
    }

    private func delete(_ item: ScanRecord) {
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: Paths.zipURL(for: item.url))
        reload()
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
