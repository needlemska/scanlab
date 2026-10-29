import Foundation
import ARKit
import CoreVideo
import UIKit
import simd

/// Перевод точки кадра в метрическую точку поверхности через LiDAR-глубину.
///
/// Почему не raycast по мешу: у ARView с `sceneReconstruction` нет коллизий
/// у реконструированных поверхностей, а собственная триангуляция по кускам
/// меша тянула бы весь экспорт в интерактивный слой. Карта глубины даёт ту же
/// точку дешевле и честнее: именно её ARKit получает от LiDAR.
enum RulerPicker {

    /// Точка поверхности в мировых координатах ARKit (метры) или nil,
    /// если глубины в этом пикселе нет. Тап по экрану.
    static func worldPoint(tap: CGPoint, viewSize: CGSize, frame: ARFrame) -> SIMD3<Float>? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }

        // 1. Тап в координатах вью → нормализованные координаты изображения.
        let normalizedView = CGPoint(x: tap.x / viewSize.width, y: tap.y / viewSize.height)
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
        let normalizedImage = normalizedView.applying(toImage)
        guard normalizedImage.x >= 0, normalizedImage.x <= 1,
              normalizedImage.y >= 0, normalizedImage.y <= 1 else { return nil }

        let resolution = frame.camera.imageResolution
        let point = CGPoint(x: normalizedImage.x * resolution.width,
                            y: normalizedImage.y * resolution.height)
        return worldPoint(imagePoint: point, frame: frame)
    }

    /// То же самое, но точка задана в пикселях полного кадра камеры (начало — левый
    /// верхний угол). Нужно распознавателю эталона: Vision отдаёт углы в долях кадра.
    static func worldPoint(imagePoint: CGPoint, frame: ARFrame) -> SIMD3<Float>? {
        guard let sceneDepth = frame.sceneDepth else { return nil }

        let depthMap = sceneDepth.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 1, depthHeight > 1 else { return nil }

        let imageResolution = frame.camera.imageResolution
        guard imageResolution.width > 0, imageResolution.height > 0 else { return nil }

        let normalizedX = imagePoint.x / imageResolution.width
        let normalizedY = imagePoint.y / imageResolution.height
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else { return nil }

        let rawX = Int(normalizedX * CGFloat(depthWidth))
        let rawY = Int(normalizedY * CGFloat(depthHeight))
        let depthX = min(max(rawX, 0), depthWidth - 1)
        let depthY = min(max(rawY, 0), depthHeight - 1)

        guard let distance = medianDepth(depthMap, x: depthX, y: depthY),
              distance > 0.05, distance < 8.0 else { return nil }

        // 2. Карта глубины меньше кадра камеры, поэтому интринсики масштабируем.
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(depthWidth) / Float(imageResolution.width)
        let scaleY = Float(depthHeight) / Float(imageResolution.height)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        guard fx > 0, fy > 0 else { return nil }

        let cameraX = (Float(depthX) + 0.5 - cx) / fx * distance
        let cameraY = (Float(depthY) + 0.5 - cy) / fy * distance

        // 3. Система камеры ARKit: X вправо, Y вверх, взгляд вдоль -Z.
        let cameraPoint = SIMD3<Float>(cameraX, -cameraY, -distance)
        let world = frame.camera.transform * SIMD4<Float>(cameraPoint, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Медиана окрестности 3×3: одиночный пиксель LiDAR шумит на кромках объекта.
    private static func medianDepth(_ map: CVPixelBuffer, x: Int, y: Int) -> Float? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values: [Float] = []
        values.reserveCapacity(9)

        for dy in -1...1 {
            for dx in -1...1 {
                let px = x + dx
                let py = y + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let row = base
                    .advanced(by: py * rowBytes)
                    .assumingMemoryBound(to: Float32.self)
                let value = row[px]
                if value.isFinite, value > 0 {
                    values.append(value)
                }
            }
        }

        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
