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

    /// Колбэк приходит на главном потоке, значение — 0…360° от старта.
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
                if delta < 0 { delta += 360 }
                self.yawDegrees = delta
                handler(delta)
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
