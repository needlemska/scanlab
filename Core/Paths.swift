import Foundation

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var scans: URL {
        let url = documents.appendingPathComponent("Scans", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Имя папки с точностью до секунды: две серии в одну секунду попали бы
    /// в одну папку и перезаписали img_001.jpg. Поэтому при совпадении — счётчик.
    static func newScanDirectory(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(prefix)-\(formatter.string(from: Date()))"

        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt + 1)"
            let url = scans.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            } catch {
                continue
            }
        }

        // Крайний случай: 100 одинаковых имён подряд.
        let fallback = scans.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func zipURL(for directory: URL) -> URL {
        directory
            .deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".zip")
    }
}

struct ScanRecord: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }

    var name: String { url.lastPathComponent }

    var kind: String {
        String(url.lastPathComponent.split(separator: "-").first ?? "scan")
    }

    var createdAt: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    var byteSize: Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}
