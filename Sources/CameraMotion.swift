import Foundation

/// Compact, time-local correction over the retained motion. The weight and its
/// first derivative vanish at both ends, so adjacent footage keeps its motion.
struct CameraLocalOffset: Codable, Equatable, Sendable {
    var start: Double
    var time: Double
    var end: Double
    var x: Double
    var y: Double

    func weight(at value: Double) -> Double {
        guard value >= start, value <= end else { return 0 }
        if abs(value - time) < 1e-12 { return 1 }
        let distance = value < time ? (time - value) / max(1e-12, time - start)
            : (value - time) / max(1e-12, end - time)
        let t = min(1, max(0, distance))
        return 1 - t * t * (3 - 2 * t)
    }

    func shifted(by delta: Double) -> CameraLocalOffset {
        var value = self
        value.start += delta; value.time += delta; value.end += delta
        return value
    }
}

/// A smooth correction relative to the retained automatic center path.
struct CameraCenterOffset: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    var slopeX: Double? = nil
    var slopeY: Double? = nil
}

/// An authored absolute pan overlays the retained route only inside this span.
struct CameraPanSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
    var startSlopeX: Double = 0
    var startSlopeY: Double = 0
    var endSlopeX: Double = 0
    var endSlopeY: Double = 0

    func sample(at time: Double) -> CameraCenterOffset {
        let span = end - start
        guard span > 0 else { return CameraCenterOffset(time: time, x: startX, y: startY) }
        let t = min(1, max(0, (time - start) / span))
        return CameraCenterOffset(time: time,
            x: CameraMotion.hermite(startX, endX, startSlopeX, endSlopeX, span, t),
            y: CameraMotion.hermite(startY, endY, startSlopeY, endSlopeY, span, t),
            slopeX: CameraMotion.hermiteDerivative(startX, endX, startSlopeX, endSlopeX, span, t),
            slopeY: CameraMotion.hermiteDerivative(startY, endY, startSlopeY, endSlopeY, span, t))
    }

    func trimmed(from lower: Double, to upper: Double) -> CameraPanSpan? {
        let a = max(start, lower), b = min(end, upper)
        guard b - a > 0.000000001 else { return nil }
        let first = sample(at: a), last = sample(at: b)
        return CameraPanSpan(start: a, end: b, startX: first.x, startY: first.y,
            endX: last.x, endY: last.y, startSlopeX: first.slopeX ?? 0, startSlopeY: first.slopeY ?? 0,
            endSlopeX: last.slopeX ?? 0, endSlopeY: last.slopeY ?? 0)
    }

    var isFinite: Bool {
        [start, end, startX, startY, endX, endY, startSlopeX, startSlopeY, endSlopeX, endSlopeY].allSatisfy(\.isFinite)
    }

    mutating func useSmoothstepTiming() {
        startSlopeX = 0; startSlopeY = 0; endSlopeX = 0; endSlopeY = 0
    }
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
