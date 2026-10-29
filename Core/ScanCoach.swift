import Foundation

/// Подсказки сканера и покрытие ракурсов.
///
/// Здесь нет ни ARKit, ни UIKit, ни модуля `simd`: только Foundation и `SIMD3`
/// из стандартной библиотеки. Это не самоцель — так файл компилируется и
/// прогоняется прямо на Windows (`swiftc ScanCoach.swift CoachTests.swift`),
/// а значит ошибки в математике ловятся за секунды, без раунда CI.
enum ScanCoach {
    /// Ближе этого телефон к предмету подносить нельзя: объект не влезает в кадр.
    static let minDistance: Float = 0.22
    /// Дальше этого фотограмметрии уже не хватает деталей.
    static let maxDistance: Float = 1.45
    /// Минимальный угол между соседними кадрами, градусы.
    static let minShotAngleDeg: Float = 15
    /// Пауза между кадрами, секунды.
    static let minInterval: TimeInterval = 0.35
    /// Верхний предел кадров: больше сессия не переварит, а памяти уйдёт много.
    static let maxShots = 150
    /// Ракурс закрыт, если камера смотрит в эту сторону с точностью до градусов.
    static let coverAngleDeg: Float = 32
    /// Если сверху не снято больше этой доли — советуем наклонить телефон.
    static let topShareThreshold: Float = 0.55

    /// Направления вокруг центра предмета. Низ исключён: предмет стоит на столе,
    /// снизу его всё равно не снять. Строго верх тоже исключён: чтобы смотреть
    /// на предмет вертикально сверху, телефон надо держать объективом вниз —
    /// такой ракурс никто не снимает, а незакрытый он держал бы «94 %» вечно.
    static let directions: [SIMD3<Float>] = buildDirections()

    static var count: Int { directions.count }

    static func buildDirections() -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let grid: [Float] = [-1, 0, 1]
        for x in grid {
            for y in grid {
                for z in grid {
                    if x == 0 && y == 0 && z == 0 { continue }
                    // Фильтр по нормализованной высоте: у угловых направлений
                    // координата сетки равна 1, а нормализованная — 0.577.
                    let direction = normalized(SIMD3<Float>(x, y, z))
                    if direction.y < -0.4 { continue }
                    if direction.y > 0.9 { continue }
                    out.append(direction)
                }
            }
        }
        return out
    }

    // MARK: - Векторная арифметика без модуля simd

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    static func length(_ a: SIMD3<Float>) -> Float {
        (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
    }

    static func normalized(_ a: SIMD3<Float>) -> SIMD3<Float> {
        let long = length(a)
        guard long > 0.000001 else { return SIMD3<Float>(0, 1, 0) }
        return a / long
    }

    static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        length(a - b)
    }

    /// Угол между направлениями в градусах.
    static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let cosValue = min(max(dot(normalized(a), normalized(b)), -1), 1)
        return acos(cosValue) * 180 / .pi
    }

    // MARK: - Покрытие

    /// Отмечает закрытые ракурсы. Возвращает true, если появился новый.
    @discardableResult
    static func markCovered(_ covered: inout [Bool], camera: SIMD3<Float>, center: SIMD3<Float>) -> Bool {
        guard covered.count == directions.count else { return false }
        let delta = camera - center
        let long = length(delta)
        guard long > 0.001 else { return false }
        let dir = delta / long
        let limit = cos(coverAngleDeg * .pi / 180)
        var changed = false
        for index in directions.indices where !covered[index] {
            if dot(dir, directions[index]) >= limit {
                covered[index] = true
                changed = true
            }
        }
        return changed
    }

    static func coverage(_ covered: [Bool]) -> Float {
        guard !covered.isEmpty else { return 0 }
        let done = covered.reduce(0) { $0 + ($1 ? 1 : 0) }
        return Float(done) / Float(covered.count)
    }

    /// Доля незакрытых верхних ракурсов среди всех незакрытых.
    static func topShare(_ covered: [Bool]) -> Float {
        var missing = 0
        var missingTop = 0
        for index in directions.indices where !covered[index] {
            missing += 1
            if directions[index].y > 0.5 { missingTop += 1 }
        }
        guard missing > 0 else { return 0 }
        return Float(missingTop) / Float(missing)
    }

    /// Текст подсказки по состоянию сканирования.
    static func hint(covered: [Bool], distance: Float?, tracking: String) -> String {
        if tracking != "normal" {
            return "Держите телефон ровнее: трекинг сбился"
        }
        guard let distance else {
            return "Наведите камеру на предмет"
        }
        if distance < minDistance {
            return "Отойдите немного: предмет не влезает в кадр"
        }
        if distance > maxDistance {
            return "Подойдите ближе: деталей не хватит"
        }
        let share = coverage(covered)
        if share >= 0.95 {
            return "Ракурсов достаточно — жмите «Собрать 3D»"
        }
        if share < 0.55, topShare(covered) > topShareThreshold {
            return "Наклоните телефон сверху и обойдите предмет"
        }
        let percent = Int((share * 100).rounded())
        return "Обойдите предмет по кругу: закрыто \(percent) %"
    }
}
