import Foundation
import ARKit
import Vision
import UIKit
import simd

/// Поиск эталона (листа A4, карты, монеты) в текущем кадре и вычисление поправки.
///
/// Как это работает: Vision находит четырёхугольник на кадре, LiDAR даёт глубину
/// в каждом из четырёх углов, поэтому стороны считаются в метрах прямо по 3D-точкам.
/// Наклон листа при этом не мешает: искажение перспективы снимается тем, что углы
/// берутся не в пикселях, а в метрах. Мешает только кромка: угол, снятый через
/// полмиллиметра мимо бумаги, уводит сторону — поэтому в `ReferenceRect` сторона
/// берётся как среднее по паре, а соотношение сторон отсекает «не тот» прямоугольник.
enum ReferenceScanner {

    struct Detection {
        var corners: [SIMD3<Float>]
        var factor: Float
        var measuredMM: Float
        var nominalMM: Float
        var confidence: Float
    }

    enum Failure: Error {
        case noFrame
        case visionFailed
        case noRectangle
        case noDepth
        case degenerate
        case wrongShape(ReferenceKind)

        var message: String {
            switch self {
            case .noFrame:
                return "Кадр AR ещё не готов — подождите секунду"
            case .visionFailed:
                return "Не удалось разобрать кадр"
            case .noRectangle:
                return "Не вижу ровный прямоугольник: положите эталон на стол и наведите камеру"
            case .noDepth:
                return "Глубина эталона не читается: подойдите ближе и не задевайте край"
            case .degenerate:
                return "Углы эталона схлопнулись — наведите камеру ровнее"
            case .wrongShape(let kind):
                return "Прямоугольник не похож на \(kind.title): проверьте эталон и ракурс"
            }
        }
    }

    /// Ищет эталон в кадре. Вызывать на главном потоке: работа короткая (один кадр),
    /// а ARFrame нельзя уносить в другую очередь надолго.
    static func detect(kind: ReferenceKind, frame: ARFrame?) -> Result<Detection, Failure> {
        guard let frame else { return .failure(.noFrame) }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 30
        request.minimumSize = 0.12
        request.minimumConfidence = 0.4
        request.maximumObservations = 4

        // Телефон держат портретом, а камера смотрит «боком» — Vision нужен поворот.
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: .right,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return .failure(.visionFailed)
        }

        let observations = (request.results ?? [])
        guard let best = observations.max(by: { $0.confidence < $1.confidence }) else {
            return .failure(.noRectangle)
        }
        let confidence = observations.first?.confidence ?? best.confidence

        let resolution = frame.camera.imageResolution
        guard resolution.width > 0, resolution.height > 0 else { return .failure(.noFrame) }

        // Vision считает нормализованные координаты от левого НИЖНЕГО угла,
        // кадр камеры — от левого верхнего. Отсюда разворот по Y.
        func imagePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * resolution.width, y: (1 - point.y) * resolution.height)
        }

        let pixelCorners = [
            imagePoint(best.topLeft),
            imagePoint(best.topRight),
            imagePoint(best.bottomRight),
            imagePoint(best.bottomLeft)
        ]

        var world: [SIMD3<Float>] = []
        world.reserveCapacity(4)
        for corner in pixelCorners {
            guard let point = RulerPicker.worldPoint(imagePoint: corner, frame: frame) else {
                return .failure(.noDepth)
            }
            world.append(point)
        }

        guard let sides = ReferenceRect.sides(world) else { return .failure(.degenerate) }
        guard let factor = ReferenceRect.factor(measured: sides, kind: kind) else {
            return .failure(.wrongShape(kind))
        }

        return .success(Detection(
            corners: world,
            factor: factor,
            measuredMM: sqrt(sides.a * sides.b) * 1000,
            nominalMM: ReferenceRect.nominalSideMM(kind),
            confidence: confidence
        ))
    }
}
