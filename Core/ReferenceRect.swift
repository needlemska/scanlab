import Foundation

/// Эталон, который можно положить рядом с объектом: лист A4, банковская карта, монета.
///
/// Зачем: LiDAR врёт систематически, и поправку проще всего взять с предмета,
/// чей размер известен. В отличие от ручной линейки, прямоугольник можно найти
/// автоматически по кадру — это шаг к «нажал одну кнопку».
enum ReferenceKind: String, CaseIterable, Identifiable {
    case a4
    case card
    case coin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: return "A4 210×297 мм"
        case .card: return "Карта 85,6×54 мм"
        case .coin: return "Монета 25 мм"
        }
    }

    /// Короткая сторона в миллиметрах.
    var widthMM: Float {
        switch self {
        case .a4: return 210
        case .card: return 85.6
        case .coin: return 25
        }
    }

    /// Длинная сторона в миллиметрах (у монеты совпадает с короткой).
    var heightMM: Float {
        switch self {
        case .a4: return 297
        case .card: return 53.98
        case .coin: return 25
        }
    }
}

/// Чистая геометрия эталона: размеры по четырём углам и поправка масштаба.
/// Без ARKit и Vision, чтобы проверяться обычным модульным тестом на компьютере.
enum ReferenceRect {

    /// Поправка меньше 0,05 или больше 20 — это не эталон, а промах распознавания.
    static let minFactor: Float = 0.05
    static let maxFactor: Float = 20

    /// Сторона короче 3 мм не бывает у наших эталонов: это шум, а не предмет.
    static let minSideMeters: Float = 0.003

    /// Насколько измеренное соотношение сторон может отличаться от паспортного.
    /// 25 % — с запасом на перспективу и срезанный угол, но отсекает «не тот» прямоугольник.
    static let maxAspectError: Float = 0.25

    /// Стороны прямоугольника по четырём углам, в каком бы порядке они ни шли.
    ///
    /// Порядок углов (0-1-2-3) задаёт обход: стороны 0-1 и 2-3 — это одна пара,
    /// 1-2 и 3-0 — другая. Берём среднее по паре: один срезанный угол не должен
    /// сдвигать результат целиком.
    static func sides(_ corners: [SIMD3<Float>]) -> (a: Float, b: Float)? {
        guard corners.count == 4 else { return nil }

        let lengths = (0..<4).map { index in
            distance(corners[index], corners[(index + 1) % 4])
        }
        let a = (lengths[0] + lengths[2]) / 2
        let b = (lengths[1] + lengths[3]) / 2

        guard a.isFinite, b.isFinite else { return nil }
        guard a >= minSideMeters, b >= minSideMeters else { return nil }
        return (a, b)
    }

    /// Во сколько раз нужно увеличить измеренное, чтобы получить настоящий размер.
    ///
    /// Считаем по площади, а не по одной стороне: так ошибка на одном угле
    /// делится между двумя измерениями и не тянет результат в одну сторону.
    static func factor(measured: (a: Float, b: Float), kind: ReferenceKind) -> Float? {
        let knownWidth = kind.widthMM / 1000
        let knownHeight = kind.heightMM / 1000
        guard knownWidth > 0, knownHeight > 0 else { return nil }

        let measuredAspect = max(measured.a, measured.b) / min(measured.a, measured.b)
        let knownAspect = max(knownWidth, knownHeight) / min(knownWidth, knownHeight)
        guard knownAspect > 0 else { return nil }
        guard abs(measuredAspect - knownAspect) / knownAspect <= maxAspectError else { return nil }

        let measuredArea = measured.a * measured.b
        guard measuredArea > 0 else { return nil }

        let value = sqrt(knownWidth * knownHeight / measuredArea)
        guard value.isFinite, value >= minFactor, value <= maxFactor else { return nil }
        return value
    }

    /// Известная «средняя» сторона эталона — её показываем в отчёте пользователю.
    static func nominalSideMM(_ kind: ReferenceKind) -> Float {
        sqrt(kind.widthMM * kind.heightMM)
    }

    private static func distance(_ one: SIMD3<Float>, _ two: SIMD3<Float>) -> Float {
        let delta = two - one
        return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    }
}
