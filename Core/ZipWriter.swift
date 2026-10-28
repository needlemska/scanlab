import Foundation

/// Минимальный ZIP-писатель: метод STORE (без сжатия).
///
/// Зачем свой: в iOS нет публичного API упаковать папку в архив, а тащить
/// стороннюю библиотеку ради одного экрана бессмысленно. Формат простой:
/// локальные заголовки + central directory + EOCD. Размеры < 4 ГБ, имя UTF-8.
enum ZipWriter {

    /// Упаковывает все обычные файлы из папки (рекурсивно), пути — относительные.
    static func write(directory: URL, to output: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ZipError.directoryUnreadable
        }

        var entries: [(String, URL)] = []
        for case let file as URL in enumerator {
            let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let relative = relativePath(of: file, in: directory)
            entries.append((relative, file))
        }

        guard !entries.isEmpty else { throw ZipError.empty }

        try write(entries: entries.sorted { $0.0 < $1.0 }, to: output)
    }

    static func write(entries: [(name: String, url: URL)], to output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw ZipError.cannotCreate
        }

        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var central = Data()
        var entryCount: UInt16 = 0
        var offset: UInt32 = 0

        for (name, url) in entries {
            let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
            let checksum = crc32(payload)
            let nameData = Data(name.replacingOccurrences(of: "\\", with: "/").utf8)
            let size = UInt32(payload.count)

            var local = Data()
            local.appendLE(UInt32(0x0403_4b50))   // local file header
            local.appendLE(UInt16(20))            // version needed
            local.appendLE(UInt16(0))             // flags
            local.appendLE(UInt16(0))             // method: store
            local.appendLE(UInt16(0))             // mod time
            local.appendLE(UInt16(0x21))          // mod date: 1980-01-01
            local.appendLE(checksum)
            local.appendLE(size)                  // compressed
            local.appendLE(size)                  // uncompressed
            local.appendLE(UInt16(nameData.count))
            local.appendLE(UInt16(0))             // extra length
            local.append(nameData)

            try handle.write(contentsOf: local)
            try handle.write(contentsOf: payload)

            central.appendLE(UInt32(0x0201_4b50)) // central directory header
            central.appendLE(UInt16(20))          // version made by
            central.appendLE(UInt16(20))          // version needed
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x21))
            central.appendLE(checksum)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))           // extra
            central.appendLE(UInt16(0))           // comment
            central.appendLE(UInt16(0))           // disk number
            central.appendLE(UInt16(0))           // internal attrs
            central.appendLE(UInt32(0))           // external attrs
            central.appendLE(offset)
            central.append(nameData)

            offset += UInt32(local.count + payload.count)
            entryCount &+= 1
        }

        let centralOffset = offset
        try handle.write(contentsOf: central)

        var end = Data()
        end.appendLE(UInt32(0x0605_4b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(entryCount)
        end.appendLE(entryCount)
        end.appendLE(UInt32(central.count))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
    }

    // MARK: - Helpers

    private static func relativePath(of file: URL, in directory: URL) -> String {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        if file.path.hasPrefix(base) {
            return String(file.path.dropFirst(base.count))
        }
        return file.lastPathComponent
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for byte in bytes {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    enum ZipError: LocalizedError {
        case empty
        case cannotCreate
        case directoryUnreadable

        var errorDescription: String? {
            switch self {
            case .empty: return "Нечего упаковывать: папка пуста"
            case .cannotCreate: return "Не удалось создать архив"
            case .directoryUnreadable: return "Не удалось прочитать папку"
            }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
