import Foundation

/// A smooth correction relative to the retained automatic center path.
struct CameraCenterOffset: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    var slopeX: Double? = nil
    var slopeY: Double? = nil
}

struct CameraMotionSample: Sendable {
    var time: Double
    var x: Double
    var y: Double
    var scale: Double
    var scaleSlope: Double
}

enum CameraMotion {
    static let maximumAutomaticControls = 12
    static let editingErrorTolerance = 0.02

    /// These controls are editing guides. The complete sampled route remains
    /// authoritative, including when a complex route reaches the guide budget.
    static func automaticAnchorTimes(samples: [CameraMotionSample], mandatoryTimes: [Double]) -> [Double] {
        guard samples.count > 1 else { return mandatoryTimes }
        var selected = Set<Int>()
        for time in mandatoryTimes {
            if let index = samples.firstIndex(where: { abs($0.time - time) < 0.000001 }) { selected.insert(index) }
        }
        selected.insert(0); selected.insert(samples.count - 1)
        let limit = max(selected.count, maximumAutomaticControls)
        while selected.count < limit {
            let ordered = selected.sorted()
            var worstIndex: Int?
            var worstError = editingErrorTolerance
            for pair in zip(ordered, ordered.dropFirst()) where pair.1 - pair.0 > 1 {
                let a = samples[pair.0], b = samples[pair.1]
                let span = b.time - a.time
                guard span > 0 else { continue }
                for index in (pair.0 + 1)..<pair.1 {
                    let point = samples[index]
                    let t = (point.time - a.time) / span
                    let x = a.x + (b.x - a.x) * t
                    let y = a.y + (b.y - a.y) * t
                    let predictedScale = hermite(a.scale, b.scale, a.scaleSlope, b.scaleSlope, span, t)
                    let positionError = hypot(point.x - x, point.y - y) * point.scale
                    let scaleError = abs(log(max(1, point.scale) / max(1, predictedScale)))
                    let error = max(positionError, scaleError)
                    if error > worstError { worstError = error; worstIndex = index }
                }
            }
            guard let worstIndex else { break }
            selected.insert(worstIndex)
        }
        return selected.sorted().map { samples[$0].time }
    }

    static func hermite(_ a: Double, _ b: Double, _ slopeA: Double, _ slopeB: Double,
                        _ span: Double, _ t: Double) -> Double {
        (2*t*t*t - 3*t*t + 1) * a + (t*t*t - 2*t*t + t) * span * slopeA +
            (-2*t*t*t + 3*t*t) * b + (t*t*t - t*t) * span * slopeB
    }

    static func hermiteDerivative(_ a: Double, _ b: Double, _ slopeA: Double, _ slopeB: Double,
                                  _ span: Double, _ t: Double) -> Double {
        ((6*t*t - 6*t) * a + (-6*t*t + 6*t) * b) / span +
            (3*t*t - 4*t + 1) * slopeA + (3*t*t - 2*t) * slopeB
    }
}
