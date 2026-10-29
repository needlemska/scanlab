// Локальные тесты логики сканера: компилируются и запускаются прямо на Windows.
//
//   pwsh -File tools/logic-test.ps1
//
// Тестируются только файлы без ARKit/UIKit — сейчас это ScanCoach. Идея простая:
// то, что можно проверить без телефона и без CI, проверяется здесь за секунды.

import Foundation

var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("ok   \(name)")
    } else {
        print("FAIL \(name) \(detail)")
        failures.append(name)
    }
}

func circle(radius: Float, elevationDeg: Float, count: Int) -> [SIMD3<Float>] {
    var out: [SIMD3<Float>] = []
    let elevation = elevationDeg * .pi / 180
    for index in 0..<count {
        let azimuth = 2 * Float.pi * Float(index) / Float(count)
        out.append(SIMD3<Float>(
            radius * cos(elevation) * sin(azimuth),
            radius * sin(elevation),
            radius * cos(elevation) * cos(azimuth)
        ))
    }
    return out
}

let center = SIMD3<Float>(0, 0, 0)

// 1. Направления: 16 штук, без низа и без строгого верха, без дублей.
let directions = ScanCoach.directions
check("направлений 16", directions.count == 16, "получено \(directions.count)")
check("нет нижних ракурсов", directions.allSatisfy { $0.y > -0.4 })
check("нет строгого верха", directions.allSatisfy { $0.y < 0.9 })
var unique = Set<String>()
for direction in directions {
    unique.insert(String(format: "%.3f/%.3f/%.3f", direction.x, direction.y, direction.z))
}
check("направления уникальны", unique.count == directions.count, "уникальных \(unique.count)")

// 2. Один кадр закрывает мало.
var covered = [Bool](repeating: false, count: ScanCoach.count)
ScanCoach.markCovered(&covered, camera: SIMD3<Float>(0, 0, 0.5), center: center)
check("один кадр < 20 %", ScanCoach.coverage(covered) < 0.2, "\(ScanCoach.coverage(covered))")

// 3. Круг по горизонтали = половина, и подсказка просит наклонить телефон.
covered = [Bool](repeating: false, count: ScanCoach.count)
for camera in circle(radius: 0.5, elevationDeg: 0, count: 36) {
    ScanCoach.markCovered(&covered, camera: camera, center: center)
}
let ringCoverage = ScanCoach.coverage(covered)
check("круг по горизонтали = 50 %", abs(ringCoverage - 0.5) < 0.001, "\(ringCoverage)")
let ringHint = ScanCoach.hint(covered: covered, distance: 0.5, tracking: "normal")
check("совет наклонить сверху", ringHint.contains("Наклоните"), ringHint)

// 4. Круг + верх = 100 %, подсказка «достаточно».
for camera in circle(radius: 0.5, elevationDeg: 45, count: 12) {
    ScanCoach.markCovered(&covered, camera: camera, center: center)
}
check("круг + верх = 100 %", ScanCoach.coverage(covered) > 0.999, "\(ScanCoach.coverage(covered))")
let doneHint = ScanCoach.hint(covered: covered, distance: 0.5, tracking: "normal")
check("совет собирать", doneHint.contains("достаточно"), doneHint)

// 5. Дистанции и трекинг.
let empty = [Bool](repeating: false, count: ScanCoach.count)
check("слишком близко", ScanCoach.hint(covered: empty, distance: 0.1, tracking: "normal").contains("Отойдите"))
check("слишком далеко", ScanCoach.hint(covered: empty, distance: 2.0, tracking: "normal").contains("Подойдите"))
check("трекинг сбит", ScanCoach.hint(covered: empty, distance: 0.5, tracking: "limited").contains("трекинг"))
check("нет дистанции", ScanCoach.hint(covered: empty, distance: nil, tracking: "normal") == "Наведите камеру на предмет")

// 6. Второй круг не добавляет ракурсов, но и не ломает покрытие.
var changed = 0
covered = [Bool](repeating: false, count: ScanCoach.count)
for camera in circle(radius: 0.6, elevationDeg: 0, count: 36) {
    if ScanCoach.markCovered(&covered, camera: camera, center: center) { changed += 1 }
}
check("первый круг закрывает 8 направлений", changed == 8, "\(changed)")
var again = 0
for camera in circle(radius: 0.6, elevationDeg: 0, count: 36) {
    if ScanCoach.markCovered(&covered, camera: camera, center: center) { again += 1 }
}
check("второй круг не добавляет", again == 0, "\(again)")

// 7. Углы и вырожденные векторы.
let angle = ScanCoach.angleDegrees(SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
check("угол между осями 90°", abs(angle - 90) < 0.01, "\(angle)")
let zero = ScanCoach.normalized(SIMD3<Float>(0, 0, 0))
check("нормализация нуля не даёт nan", zero.y == 1 && zero.x == 0 && zero.z == 0, "\(zero)")

// 8. Камера строго в центре не должна ломать покрытие.
covered = [Bool](repeating: false, count: ScanCoach.count)
ScanCoach.markCovered(&covered, camera: center, center: center)
check("камера в центре: покрытие 0", ScanCoach.coverage(covered) == 0)

print("")
if failures.isEmpty {
    print("все проверки прошли (\(ScanCoach.count) направлений)")
    exit(0)
} else {
    print("провалено: \(failures.joined(separator: ", "))")
    exit(1)
}
