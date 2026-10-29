import Foundation

/// Сведения о подписи, которой установлено приложение.
///
/// Зачем: бесплатный Apple ID даёт профиль на 7 дней, потом приложение перестаёт
/// запускаться. Приложение читает `embedded.mobileprovision` из своего бандла и
/// показывает, сколько дней осталось, — иначе дату переподписи приходится держать
/// в голове, а забытая переподпись выглядит как «приложение сломалось».
enum Provisioning {

    struct Info {
        let name: String
        let expires: Date
        let teamIdentifier: String?
        let daysLeft: Int
        let isExpired: Bool
    }

    /// Читает профиль из бандла. `nil`, если приложение собрано без профиля
    /// (например, запущено из Xcode без подписи) — это не ошибка.
    static func load(bundle: Bundle = .main) -> Info? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data)
    }

    /// Профиль — это CMS-контейнер: внутри лежит XML-плист. Достаём его по границам
    /// `<?xml` … `</plist>`, не разбирая саму подпись.
    static func parse(_ data: Data) -> Info? {
        let bytes = [UInt8](data)
        guard let start = find([0x3C, 0x3F, 0x78, 0x6D, 0x6C], in: bytes),  // "<?xml"
              let end = find([0x3C, 0x2F, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x3E], in: bytes, from: start + 5) else {
            return nil
        }
        let finish = end + 8
        guard finish <= bytes.count else { return nil }
        let plist = data.subdata(in: start..<finish)
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        let name = dictionary["Name"] as? String ?? "профиль без имени"
        let expires = dictionary["ExpirationDate"] as? Date
            ?? (dictionary["CreationDate"] as? Date).map { $0.addingTimeInterval(7 * 24 * 3600) }
            ?? Date.distantPast
        let team = (dictionary["TeamIdentifier"] as? [String])?.first
        let secondsLeft = expires.timeIntervalSinceNow
        let daysLeft = Int((secondsLeft / 86_400).rounded(.down))
        return Info(name: name,
                    expires: expires,
                    teamIdentifier: team,
                    daysLeft: max(0, daysLeft),
                    isExpired: secondsLeft <= 0)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Поиск по байтам

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        var index = max(0, start)
        while index <= lastStart {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }
}
