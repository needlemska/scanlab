import Foundation
import SwiftUI

/// Состояние сервера выгрузки для интерфейса библиотеки.
@MainActor
final class FileServerModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var address: String?
    @Published private(set) var message: String?

    private let server = FileServer()

    var port: UInt16 { 8080 }

    func toggle() {
        if running {
            server.stop()
            running = false
            address = nil
            message = "Выгрузка выключена"
            return
        }

        guard let ip = FileServer.wifiAddress() else {
            address = nil
            message = "Телефон не в Wi-Fi. Подключите его к той же сети, что и компьютер."
            return
        }

        do {
            try server.start(root: Paths.scans, port: port)
            running = true
            address = "http://\(ip):\(port)"
            message = nil
        } catch {
            running = false
            address = nil
            message = "Не удалось запустить: \(error.localizedDescription)"
        }
    }

    func stopIfNeeded() {
        guard running else { return }
        server.stop()
        running = false
        address = nil
    }
}
