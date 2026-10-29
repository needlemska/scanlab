import Foundation
import CoreMotion

/// Следит за поворотом телефона вокруг вертикали (yaw) относительно начала съёмки.
///
/// Нужен для съёмки на поворотном столе: фотограмметрия любит равномерные углы,
/// а не «десять кадров с одной стороны и три с другой». Отсчёт идёт от момента
/// старта, поэтому держите телефон неподвижно, пока приложение не начнёт серию.
final class TurntableTracker {

    private let motion = CMMotionManager()
    private var referenceYaw: Double?
    private(set) var yawDegrees: Double = 0

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    /// Колбэк приходит на главном потоке, значение — накопленный угол от старта
    /// (растёт и в плюс, и в минус: назад на 5° это −5°, а не 355°).
    func start(_ handler: @escaping (Double) -> Void) {
        guard motion.isDeviceMotionAvailable else { return }
        referenceYaw = nil
        yawDegrees = 0
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let yaw = data.attitude.yaw * 180.0 / Double.pi
            if let reference = self.referenceYaw {
                var delta = (yaw - reference).truncatingRemainder(dividingBy: 360)
                // В диапазон −180…180: иначе поворот назад даёт фантомный сектор.
                delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180
                self.yawDegrees += delta
                self.referenceYaw = yaw
                handler(self.yawDegrees)
            } else {
                self.referenceYaw = yaw
                handler(0)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        referenceYaw = nil
        yawDegrees = 0
    }
}
