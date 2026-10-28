import Foundation
import Network

/// Крошечный HTTP-сервер внутри приложения: отдаёт каждую папку скана как ZIP.
/// Зачем: забирать данные с телефона по Wi-Fi, без провода, iTunes и «Файлов».
///
/// Протокол максимально простой: один запрос — один ответ, `Connection: close`.
/// Полноценный HTTP/1.1 с keep-alive здесь не нужен, а сложность только добавила бы.
final class FileServer {
    enum ServerError: LocalizedError {
        case badPort
        case cannotStart

        var errorDescription: String? {
            switch self {
            case .badPort: return "Неверный порт"
            case .cannotStart: return "Не удалось открыть порт (возможно, занят)"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.scanlab.fileserver")
    private var listener: NWListener?
    private(set) var isRunning = false

    func start(root: URL, port: UInt16 = 8080) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ServerError.badPort }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw ServerError.cannotStart
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, root: root)
        }
        listener.start(queue: queue)

        self.listener = listener
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Соединение

    private func accept(_ connection: NWConnection, root: URL) {
        connection.start(queue: queue)
        readRequest(connection, root: root, buffer: Data(), rounds: 0)
    }

    private func readRequest(_ connection: NWConnection, root: URL, buffer: Data, rounds: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self = self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data = data, !data.isEmpty { buffer.append(data) }

            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, root: root, on: connection)
                return
            }

            if isComplete || buffer.count > 32 * 1024 || rounds > 6 {
                connection.cancel()
                return
            }
            self.readRequest(connection, root: root, buffer: buffer, rounds: rounds + 1)
        }
    }

    // MARK: - Ответ

    private func respond(to head: String, root: URL, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", type: "text/plain; charset=utf-8",
                 body: Data("Плохой запрос".utf8), on: connection)
            return
        }

        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target

        if path == "/" || path == "/index.html" {
            send(status: "200 OK", type: "text/html; charset=utf-8",
                 body: listing(root: root), on: connection)
            return
        }

        if path.hasPrefix("/zip/") {
            let raw = String(path.dropFirst("/zip/".count))
            let name = raw.removingPercentEncoding ?? raw
            if let (fileName, data) = makeZip(name: name, root: root) {
                send(status: "200 OK", type: "application/zip", body: data,
                     filename: fileName, on: connection)
            } else {
                send(status: "404 Not Found", type: "text/plain; charset=utf-8",
                     body: Data("Нет такого скана: \(name)".utf8), on: connection)
            }
            return
        }

        send(status: "404 Not Found", type: "text/plain; charset=utf-8",
             body: Data("Только / и /zip/<имя>".utf8), on: connection)
    }

    private func send(status: String, type: String, body: Data, filename: String? = nil,
                      on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "\r\n"

        var out = Data(header.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Содержимое

    private func makeZip(name: String, root: URL) -> (String, Data)? {
        // Защита от выхода за пределы папки сканов.
        guard !name.isEmpty, !name.contains(".."), !name.contains("/"), !name.contains("\\") else {
            return nil
        }
        let fm = FileManager.default
        let directory = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let temporary = fm.temporaryDirectory.appendingPathComponent("scanlab-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporary) }

        do {
            try ZipWriter.write(directory: directory, to: temporary)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: temporary) else { return nil }
        return ("\(name).zip", data)
    }

    private func listing(root: URL) -> Data {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let directories = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var rows = ""
        for directory in directories {
            let name = directory.lastPathComponent
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let size = Self.sizeText(of: directory)
            rows += "<li><a href=\"/zip/\(encoded)\">\(Self.escape(name))</a> <small>\(size)</small></li>\n"
        }
        if rows.isEmpty {
            rows = "<li>пока пусто — снимите что-нибудь во вкладке LiDAR или Фото</li>"
        }

        let html = """
        <!doctype html>
        <html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ScanLab</title>
        <style>
        body{font:16px -apple-system,system-ui,sans-serif;margin:24px;color:#111}
        h1{font-size:20px;margin:0 0 4px}
        p.hint{color:#666;font-size:13px;margin:0 0 16px}
        li{margin:8px 0}
        a{color:#0a7a3b;text-decoration:none}
        small{color:#888}
        </style></head>
        <body>
        <h1>ScanLab</h1>
        <p class="hint">Каждая ссылка — ZIP с мешем, метаданными и кадрами. Скачайте и распакуйте на компьютере.</p>
        <ul>
        \(rows)
        </ul>
        </body></html>
        """

        return Data(html.utf8)
    }

    private static func sizeText(of directory: URL) -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                    total += Int64(size)
                }
            }
        }
        let mb = Double(total) / 1_048_576.0
        return String(format: "%.1f МБ", mb)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Адрес

    /// IPv4-адрес Wi-Fi интерфейса (en0). nil — телефон не в Wi-Fi.
    static func wifiAddress() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            if isUp, let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: current.pointee.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                }
            }
            pointer = current.pointee.ifa_next
        }
        return result
    }
}
