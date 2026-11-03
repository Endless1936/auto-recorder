import AppKit
import CoreMedia

struct CursorSample: Codable, Sendable {
    let time: Double
    let x: Double
    let y: Double
    let inside: Bool
    let clicked: Bool
}

struct CursorTrace: Codable, Sendable {
    var version = 1
    let samples: [CursorSample]

    var hasClicks: Bool { samples.contains { $0.inside && $0.clicked && $0.time >= 0 } }

    static func normalized(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: (point.x - bounds.minX) / bounds.width,
                y: (point.y - bounds.minY) / bounds.height)
    }

    static func aligned(_ samples: [CursorSample], origin: Double) -> CursorTrace {
        CursorTrace(samples: samples.compactMap { sample in
            let time = sample.time - origin
            guard time.isFinite, time >= 0 else { return nil }
            return CursorSample(time: time, x: sample.x, y: sample.y, inside: sample.inside, clicked: sample.clicked)
        })
    }
}

/// Polls pointer position and mouse buttons only; no event tap or keyboard monitoring.
@MainActor
final class CursorCapture {
    private var timer: Timer?
    private var samples: [CursorSample] = []
    private var bounds = CGRect.zero
    private var buttonsDown = false
    private var paused = false
    private var boundsProvider: (() -> CGRect?)?
    private var timeMapper: ((CMTime) -> CMTime?)?

    func start(bounds: CGRect, boundsProvider: (() -> CGRect?)? = nil, timeMapper: ((CMTime) -> CMTime?)? = nil) {
        timer?.invalidate()
        self.bounds = bounds
        self.boundsProvider = boundsProvider
        self.timeMapper = timeMapper
        paused = false
        samples = []
        buttonsDown = Self.pressed()
        sample()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finish(origin: CMTime) -> CursorTrace {
        sample()
        timer?.invalidate(); timer = nil
        let result = CursorTrace.aligned(samples, origin: origin.seconds)
        samples = []
        boundsProvider = nil; timeMapper = nil
        return result
    }

    func cancel() {
        timer?.invalidate(); timer = nil; samples = []
        boundsProvider = nil; timeMapper = nil
    }

    func pause() { paused = true }
    func resume() { paused = false; buttonsDown = Self.pressed() }

    private static func pressed() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left) ||
        CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    private func sample() {
        guard !paused else { return }
        if let boundsProvider {
            guard let current = boundsProvider() else { return }
            bounds = current
        }
        guard bounds.width > 0, bounds.height > 0, let position = CGEvent(source: nil)?.location else { return }
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let mapped: CMTime
        if let timeMapper {
            guard let time = timeMapper(host) else { return }
            mapped = time
        } else { mapped = host }
        let pressed = Self.pressed()
        let clicked = pressed && !buttonsDown
        buttonsDown = pressed
        let point = CursorTrace.normalized(position, in: bounds)
        let time = mapped.seconds
        let inside = bounds.contains(position)
        // Keep stationary recordings small while still checking buttons at 60 Hz.
        if let last = samples.last, !clicked, last.inside == inside,
           hypot(point.x - last.x, point.y - last.y) < 0.0005, time - last.time < 0.25 { return }
        samples.append(CursorSample(time: time, x: point.x, y: point.y, inside: inside, clicked: clicked))
    }
}

struct ZoomPose: Sendable {
    var scale: Double = 1
    var x: Double = 0.5
    var y: Double = 0.5

    var viewport: CGRect {
        CGRect(x: x - 0.5 / scale, y: y - 0.5 / scale, width: 1 / scale, height: 1 / scale)
    }
}

enum CameraPositionTiming: String, Codable, Sendable {
    case smooth, linear, viewport
}

struct CameraPositionWaypoint: Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    // Timing for the outgoing edge. It never changes the magnification curve.
    var timing: CameraPositionTiming = .smooth
}

/// TD-TR style simplification of positions only. Every accepted shortcut is
/// checked at the original cursor times and the actual render times. A difficult
/// interval retains more position points; the planner cannot lower magnification.
enum SimplifiedCameraPath {
    private static let tolerance = 0.0000001

    private struct Sample {
        var time: Double
        var x: Double
        var y: Double
    }

    private struct Evaluation {
        var error: Double
        var index: Int
        var timing: CameraPositionTiming
    }

    static func plan(trace: CursorTrace, reference: [CameraPositionWaypoint],
                     mandatoryTimes: [Double], scaleAt: (Double) -> Double,
                     fps: Int) -> [CameraPositionWaypoint] {
        let reference = reference.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        guard let first = reference.first, let last = reference.last, last.time > first.time else { return reference }
        let raw = trace.samples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        var times = reference.map(\.time) + mandatoryTimes.filter { $0.isFinite && $0 >= first.time && $0 <= last.time }
        times += raw.map(\.time).filter { $0 >= first.time && $0 <= last.time }

        // Global frame times must be explicit: an interval-local grid can miss
        // video frames when a cursor sample falls between nominal frame times.
        for frequency in Set([240, max(1, min(60, fps))]) {
            let start = Int(ceil(first.time * Double(frequency)))
            let end = Int(floor(last.time * Double(frequency)))
            if start <= end {
                times += (start...end).map { Double($0) / Double(frequency) }
            }
        }

        // Include the moments at which a finite cursor segment enters or leaves
        // the recorded image, even if both captured endpoints are outside it.
        for (a, b) in zip(raw, raw.dropFirst()) where b.time > a.time {
            var entry = 0.0, exit = 1.0
            for (value, change) in [(a.x, b.x - a.x), (a.y, b.y - a.y)] {
                if abs(change) < 0.000000000001 {
                    if !(0...1).contains(value) { entry = 1; exit = 0 }
                } else {
                    let lower = -value / change, upper = (1 - value) / change
                    entry = max(entry, min(lower, upper)); exit = min(exit, max(lower, upper))
                }
            }
            if entry <= exit {
                for amount in [entry, exit] {
                    let time = a.time + (b.time - a.time) * amount
                    if time >= first.time && time <= last.time { times.append(time) }
                }
            }
        }
        times = unique(times)
        let samples = raw.map { Sample(time: $0.time, x: $0.x, y: $0.y) }
        let preferred = reference.map { Sample(time: $0.time, x: $0.x, y: $0.y) }

        func radius(_ time: Double) -> Double {
            let scale = scaleAt(time)
            return 0.5 / (scale.isFinite ? max(1, scale) : 1)
        }
        func cursor(_ time: Double) -> Sample? {
            guard var value = interpolate(samples, at: time),
                  value.x >= -1e-12, value.x <= 1 + 1e-12,
                  value.y >= -1e-12, value.y <= 1 + 1e-12 else { return nil }
            value.x = min(1, max(0, value.x)); value.y = min(1, max(0, value.y))
            return value
        }
        var points = times.map { time -> CameraPositionWaypoint in
            let desired = interpolate(preferred, at: time) ?? Sample(time: time, x: 0.5, y: 0.5)
            let half = radius(time)
            var x = min(1 - half, max(half, desired.x))
            var y = min(1 - half, max(half, desired.y))
            if let pointer = cursor(time) {
                // Use a small buffer when the image boundary permits it. This
                // preserves sub-frame slack without creating black crop borders.
                func protected(_ value: Double, _ coordinate: Double) -> Double {
                    let inner = half * 0.95
                    let lower = max(half, coordinate - inner), upper = min(1 - half, coordinate + inner)
                    if lower <= upper { return min(upper, max(lower, value)) }
                    return min(1 - half, max(half, min(coordinate + half, max(coordinate - half, value))))
                }
                x = protected(x, pointer.x); y = protected(y, pointer.y)
            }
            return CameraPositionWaypoint(time: time, x: x, y: y)
        }
        guard points.count >= 2 else { return points }

        func fraction(_ time: Double, _ a: CameraPositionWaypoint, _ b: CameraPositionWaypoint,
                      _ timing: CameraPositionTiming) -> Double {
            let linear = min(1, max(0, (time - a.time) / max(0.000000000001, b.time - a.time)))
            switch timing {
            case .linear: return linear
            case .smooth: return linear * linear * (3 - 2 * linear)
            case .viewport:
                let start = radius(a.time), end = radius(b.time)
                if abs(end - start) > 0.000000000001 {
                    return min(1, max(0, (radius(time) - start) / (end - start)))
                }
                return linear * linear * (3 - 2 * linear)
            }
        }

        func evaluate(_ lower: Int, _ upper: Int, _ timing: CameraPositionTiming) -> Evaluation {
            let a = points[lower], b = points[upper]
            var worst = Evaluation(error: 0, index: (lower + upper) / 2, timing: timing)
            for index in lower...upper {
                let time = points[index].time, half = radius(time)
                let amount = fraction(time, a, b, timing)
                let x = a.x + (b.x - a.x) * amount, y = a.y + (b.y - a.y) * amount
                var error = max(half - x, x + half - 1, half - y, y + half - 1)
                if let pointer = cursor(time) {
                    error = max(error, abs(pointer.x - x) - half, abs(pointer.y - y) - half)
                }
                if error > worst.error { worst.error = error; worst.index = index }
            }
            return worst
        }

        var selected: Set<Int> = [0, points.count - 1]
        for time in mandatoryTimes {
            if let index = points.indices.min(by: { abs(points[$0].time - time) < abs(points[$1].time - time) }),
               abs(points[index].time - time) < 0.000001 { selected.insert(index) }
        }
        let mandatory = selected
        let boundaries = selected.sorted()
        var pending = Array(zip(boundaries, boundaries.dropFirst()))
        while let (lower, upper) = pending.popLast() {
            let zooming = abs(radius(points[lower].time) - radius(points[upper].time)) > 0.000000000001
            let preferredTiming: CameraPositionTiming = zooming ? .viewport : .smooth
            let preferredFit = evaluate(lower, upper, preferredTiming)
            if preferredFit.error <= tolerance {
                points[lower].timing = preferredTiming
                continue
            }
            let linearFit = evaluate(lower, upper, .linear)
            if linearFit.error <= tolerance {
                points[lower].timing = .linear
                continue
            }
            // Iterative subdivision avoids recursion depth depending on the
            // recording length. No node-count budget can discard a valid zoom.
            let failure = preferredFit.error <= linearFit.error ? preferredFit : linearFit
            let split = min(upper - 1, max(lower + 1, failure.index))
            if split > lower && split < upper {
                selected.insert(split)
                pending.append((split, upper)); pending.append((lower, split))
            } else {
                // Adjacent protected samples have no intermediate render/cursor
                // timestamp. Keep their direct connection rather than inventing
                // unshown movement or changing the fixed scale schedule.
                points[lower].timing = .linear
            }
        }
        // TD-TR splits at the worst violation, which can leave a redundant
        // neighbor after later splits. Remove it only when the complete new
        // edge passes the same cursor and crop checks; phase boundaries stay.
        var changed = true
        while changed {
            changed = false
            let ordered = selected.sorted()
            for index in 1..<(ordered.count - 1) where !mandatory.contains(ordered[index]) {
                let lower = ordered[index - 1], upper = ordered[index + 1]
                let zooming = abs(radius(points[lower].time) - radius(points[upper].time)) > 0.000000000001
                let preferred: CameraPositionTiming = zooming ? .viewport : .smooth
                if evaluate(lower, upper, preferred).error <= tolerance {
                    points[lower].timing = preferred
                } else if evaluate(lower, upper, .linear).error <= tolerance {
                    points[lower].timing = .linear
                } else { continue }
                selected.remove(ordered[index])
                changed = true
                break
            }
        }
        return selected.sorted().map { points[$0] }
    }

    private static func unique(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values.filter(\.isFinite).sorted()
            where result.last.map({ value - $0 > 0.0000000001 }) ?? true { result.append(value) }
        return result
    }

    private static func interpolate(_ values: [Sample], at time: Double) -> Sample? {
        guard let first = values.first, let last = values.last else { return nil }
        if time <= first.time { return Sample(time: time, x: first.x, y: first.y) }
        if time >= last.time { return Sample(time: time, x: last.x, y: last.y) }
        var lower = 0, upper = values.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if values[middle].time <= time { lower = middle } else { upper = middle }
        }
        let a = values[lower], b = values[upper]
        let amount = (time - a.time) / max(0.000000000001, b.time - a.time)
        return Sample(time: time, x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }
}

/// A precomputed path makes random-access export requests deterministic.
struct AutoZoomPlan: Sendable {
    static let safeZoneFraction = 0.7
    let fps: Int
    let poses: [ZoomPose]

    init(trace: CursorTrace, duration: Double, fps: Int) {
        self.fps = max(1, min(60, fps))
        let duration = duration.isFinite ? max(0, duration) : 0
        let samples = trace.samples.filter {
            $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite
        }.sorted { $0.time < $1.time }
        let step = 1 / Double(self.fps)
        let alpha = 1 - exp(-step / 0.14)
        var pose = ZoomPose()
        var targetX = 0.5, targetY = 0.5
        var pointer: CursorSample?
        var activityPointer: CursorSample?
        var lastActivity = -Double.infinity
        var active = false
        var index = 0
        var result: [ZoomPose] = []
        result.reserveCapacity(Int(ceil(duration * Double(self.fps))) + 2)
        for frame in 0...Int(ceil(duration * Double(self.fps))) + 1 {
            let time = Double(frame) * step
            var click = false
            while index < samples.count, samples[index].time <= time {
                let next = samples[index]
                if next.inside {
                    // Compare with the last meaningful position so slow movement
                    // counts as activity without accumulating stationary jitter.
                    if next.clicked {
                        active = true; click = true; lastActivity = time
                        activityPointer = next
                    } else if let anchor = activityPointer,
                              hypot(anchor.x - next.x, anchor.y - next.y) > 0.002 {
                        lastActivity = time
                        activityPointer = next
                    }
                } else { active = false; activityPointer = nil }
                pointer = next
                index += 1
            }
            if time - lastActivity > 1 { active = false }
            let scale = active ? 1.6 : 1.0
            if active, let pointer {
                let margin = 0.5 / scale
                let deadZone = margin * Self.safeZoneFraction
                if click { targetX = pointer.x; targetY = pointer.y }
                else {
                    if abs(pointer.x - targetX) > deadZone { targetX = pointer.x - copysign(deadZone, pointer.x - targetX) }
                    if abs(pointer.y - targetY) > deadZone { targetY = pointer.y - copysign(deadZone, pointer.y - targetY) }
                }
                targetX = min(1 - margin, max(margin, targetX))
                targetY = min(1 - margin, max(margin, targetY))
            } else { targetX = 0.5; targetY = 0.5 }
            pose.scale += (scale - pose.scale) * alpha
            pose.x += (targetX - pose.x) * alpha
            pose.y += (targetY - pose.y) * alpha
            let margin = 0.5 / pose.scale
            pose.x = min(1 - margin, max(margin, pose.x))
            pose.y = min(1 - margin, max(margin, pose.y))
            result.append(pose)
        }
        poses = result
    }

    func pose(at time: Double) -> ZoomPose {
        guard time.isFinite else { return ZoomPose() }
        let position = min(Double(poses.count - 1), max(0, time * Double(fps)))
        let a = Int(position), b = min(a + 1, poses.count - 1)
        let amount = position - Double(a)
        return ZoomPose(scale: poses[a].scale + (poses[b].scale - poses[a].scale) * amount,
                        x: poses[a].x + (poses[b].x - poses[a].x) * amount,
                        y: poses[a].y + (poses[b].y - poses[a].y) * amount)
    }
}
