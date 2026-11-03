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

struct SimplifiedCameraWaypoint: Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    var scale: Double
}

/// Plans the actual editable route. Center and viewport half-size use the same
/// easing; interpolating raw magnification instead would clip edge cursors.
enum SimplifiedCameraPath {
    private static let tolerance = 0.00000001

    private struct Observation {
        var time: Double
        var x: Double
        var y: Double
    }

    private struct PointerSpan {
        var start: Double
        var end: Double
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double

        func point(at time: Double) -> Observation {
            Observation(time: time, x: x + vx * (time - start), y: y + vy * (time - start))
        }
    }

    private struct Row {
        var first: Int
        var second: Int
        var weight: Double
        var radius: Double
        var point: Observation
    }

    static func plan(trace: CursorTrace, mandatory: [SimplifiedCameraWaypoint], fps: Int) -> [SimplifiedCameraWaypoint] {
        let base = mandatory.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.scale.isFinite && $0.scale >= 1
        }.sorted { $0.time < $1.time }
        guard base.count >= 2, let first = base.first, let last = base.last, last.time > first.time else { return base }
        let samples = trace.samples.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite
        }.sorted { $0.time < $1.time }
        func valid(_ sample: CursorSample) -> Bool {
            sample.inside && (0...1).contains(sample.x) && (0...1).contains(sample.y)
        }
        var spans: [PointerSpan] = []
        for index in samples.indices {
            let sample = samples[index]
            if index + 1 < samples.count {
                let following = samples[index + 1], duration = following.time - sample.time
                guard duration > 0 else { continue }
                var entry = 0.0, exit = 1.0
                for (value, change) in [(sample.x, following.x - sample.x), (sample.y, following.y - sample.y)] {
                    if abs(change) < 0.000000000001 {
                        if !(0...1).contains(value) { entry = 1; exit = 0 }
                    } else {
                        let a = -value / change, b = (1 - value) / change
                        entry = max(entry, min(a, b)); exit = min(exit, max(a, b))
                    }
                }
                guard exit >= entry else { continue }
                let start = max(first.time, sample.time + duration * entry)
                let end = min(last.time, sample.time + duration * exit)
                guard end > start else { continue }
                let vx = (following.x - sample.x) / duration, vy = (following.y - sample.y) / duration
                spans.append(PointerSpan(start: start, end: end,
                    x: sample.x + vx * (start - sample.time), y: sample.y + vy * (start - sample.time), vx: vx, vy: vy))
            } else if valid(sample) {
                let start = max(first.time, sample.time)
                if last.time > start {
                    spans.append(PointerSpan(start: start, end: last.time, x: sample.x, y: sample.y, vx: 0, vy: 0))
                }
            }
        }
        var observations = samples.filter { valid($0) && $0.time >= first.time && $0.time <= last.time }
            .map { Observation(time: $0.time, x: $0.x, y: $0.y) }
        for span in spans {
            observations.append(span.point(at: span.start))
            observations.append(span.point(at: span.end))
            for point in base where point.time > span.start && point.time < span.end {
                observations.append(span.point(at: point.time))
            }
        }
        guard !observations.isEmpty else { return bounded(base) }

        // A local loop or irregular gesture which fits one crop needs no pan at
        // all. The nested zoom rectangles all contain this same activity area.
        if let stationary = stationaryFit(base, observations: observations) { return stationary }

        var points = bounded(base)
        let minimumSpacing = max(0.00001, 0.5 / Double(max(1, min(60, fps))))
        while true {
            let solution = solve(points, observations: observations, spans: spans)
            points = solution.points
            guard let missing = solution.missing else { return points }
            guard points.count < max(8, base.count) else { break }
            var refinement = motionRefinement(points, observations: observations, spans: spans,
                                               minimumSpacing: minimumSpacing) ?? missing
            if !points.allSatisfy({ abs($0.time - refinement.time) > minimumSpacing }) {
                let candidates = observations.filter { observation in
                    points.allSatisfy { abs($0.time - observation.time) > minimumSpacing }
                }
                guard let alternative = observedViolation(points, observations: candidates) else { break }
                refinement = alternative
            }
            let desired = interpolated(base, at: refinement.time)
            let previous = interpolated(points, at: refinement.time)
            let radius = 0.5 / desired.scale
            points.append(SimplifiedCameraWaypoint(time: refinement.time,
                x: min(1 - radius, max(radius, min(refinement.x + radius, max(refinement.x - radius, previous.x)))),
                y: min(1 - radius, max(radius, min(refinement.y + radius, max(refinement.y - radius, previous.y)))),
                scale: desired.scale))
            points.sort { $0.time < $1.time }
        }

        // Cursor coverage wins over the soft node budget. Very rapid, wide
        // gestures use a wider authored crop instead of hidden corrective motion.
        let xs = observations.map(\.x), ys = observations.map(\.y)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let peak = base.map(\.scale).max() ?? 1
        let fittingPeak = min(peak, max(1, 1 / max(0.000001, span + 0.000002)))
        let fraction = peak > 1 ? (fittingPeak - 1) / (peak - 1) : 0
        let wider = base.map {
            SimplifiedCameraWaypoint(time: $0.time, x: $0.x, y: $0.y, scale: 1 + ($0.scale - 1) * fraction)
        }
        return stationaryFit(wider, observations: observations) ?? base.map {
            SimplifiedCameraWaypoint(time: $0.time, x: 0.5, y: 0.5, scale: 1)
        }
    }

    private static func bounded(_ points: [SimplifiedCameraWaypoint]) -> [SimplifiedCameraWaypoint] {
        points.map { point in
            let radius = 0.5 / point.scale
            return SimplifiedCameraWaypoint(time: point.time,
                x: min(1 - radius, max(radius, point.x)), y: min(1 - radius, max(radius, point.y)), scale: point.scale)
        }
    }

    private static func stationaryFit(_ points: [SimplifiedCameraWaypoint], observations: [Observation]) -> [SimplifiedCameraWaypoint]? {
        let radius = 0.5 / (points.map(\.scale).max() ?? 1)
        let xs = observations.map(\.x), ys = observations.map(\.y)
        let lowX = max(radius, xs.max()! - radius), highX = min(1 - radius, xs.min()! + radius)
        let lowY = max(radius, ys.max()! - radius), highY = min(1 - radius, ys.min()! + radius)
        guard lowX <= highX + tolerance, lowY <= highY + tolerance else { return nil }
        let focusX = min(highX, max(lowX, (xs.min()! + xs.max()!) / 2))
        let focusY = min(highY, max(lowY, (ys.min()! + ys.max()!) / 2))
        return points.map { point in
            let amount = radius < 0.5 ? (0.5 - 0.5 / point.scale) / (0.5 - radius) : 0
            return SimplifiedCameraWaypoint(time: point.time,
                x: 0.5 + (focusX - 0.5) * amount, y: 0.5 + (focusY - 0.5) * amount, scale: point.scale)
        }
    }

    private static func interval(_ points: [SimplifiedCameraWaypoint], at time: Double) -> (Int, Int, Double) {
        let upper = points.firstIndex { $0.time > time } ?? points.count - 1
        let lower = max(0, upper - 1)
        let span = points[upper].time - points[lower].time
        let t = span > 0 ? min(1, max(0, (time - points[lower].time) / span)) : 0
        return (lower, upper, t * t * (3 - 2 * t))
    }

    private static func interpolated(_ points: [SimplifiedCameraWaypoint], at time: Double) -> SimplifiedCameraWaypoint {
        let (a, b, weight) = interval(points, at: time)
        let first = points[a], second = points[b]
        return SimplifiedCameraWaypoint(time: time,
            x: first.x + (second.x - first.x) * weight, y: first.y + (second.y - first.y) * weight,
            scale: 1 / (1 / first.scale + (1 / second.scale - 1 / first.scale) * weight))
    }

    private static func rows(_ points: [SimplifiedCameraWaypoint], observations: [Observation]) -> [Row] {
        observations.map { point in
            let (a, b, weight) = interval(points, at: point.time)
            let radius = (0.5 / points[a].scale) * (1 - weight) + (0.5 / points[b].scale) * weight
            return Row(first: a, second: b, weight: weight, radius: radius, point: point)
        }
    }

    private static func project(_ values: inout [Double], radii: [Double], row: Row, pointer: Double) {
        for _ in 0..<2 {
            let a = row.first, b = row.second, wa = 1 - row.weight, wb = row.weight
            let value = values[a] * wa + values[b] * wb
            let delta = min(pointer + row.radius, max(pointer - row.radius, value)) - value
            guard abs(delta) > tolerance * 0.1 else { return }
            func movable(_ index: Int, _ weight: Double) -> Bool {
                weight > 0 && (delta > 0 ? values[index] < 1 - radii[index] - 0.0000000001 : values[index] > radii[index] + 0.0000000001)
            }
            let firstWeight = movable(a, wa) ? wa : 0
            let secondWeight = movable(b, wb) ? wb : 0
            let denominator = firstWeight * firstWeight + secondWeight * secondWeight
            guard denominator > 0 else { return }
            values[a] = min(1 - radii[a], max(radii[a], values[a] + delta * firstWeight / denominator))
            values[b] = min(1 - radii[b], max(radii[b], values[b] + delta * secondWeight / denominator))
        }
    }

    private static func solve(_ original: [SimplifiedCameraWaypoint], observations: [Observation], spans: [PointerSpan])
        -> (points: [SimplifiedCameraWaypoint], missing: Observation?) {
        var points = original
        // Limit repeated projection work on long recordings. Full raw spans and
        // observations remain the final authority and add any missing cuts.
        var constraints = compactObservations(observations, anchors: points)
        let radii = points.map { 0.5 / $0.scale }
        for _ in 0..<12 {
            let equations = rows(points, observations: constraints)
            var xs = points.map(\.x), ys = points.map(\.y)
            for _ in 0..<180 {
                for row in equations {
                    project(&xs, radii: radii, row: row, pointer: row.point.x)
                    project(&ys, radii: radii, row: row, pointer: row.point.y)
                }
                let maximum = equations.reduce(0.0) { worst, row in
                    let x = xs[row.first] * (1 - row.weight) + xs[row.second] * row.weight
                    let y = ys[row.first] * (1 - row.weight) + ys[row.second] * row.weight
                    return max(worst, max(abs(x - row.point.x), abs(y - row.point.y)) - row.radius)
                }
                if maximum <= tolerance { break }
            }
            for index in points.indices { points[index].x = xs[index]; points[index].y = ys[index] }
            var worstError = tolerance
            var missing: Observation?
            for row in equations {
                let value = interpolated(points, at: row.point.time)
                let error = max(abs(value.x - row.point.x), abs(value.y - row.point.y)) - row.radius
                if error > worstError { worstError = error; missing = row.point }
            }
            if let missing { return (points, missing) }
            guard let interior = observedViolation(points, observations: observations) ?? continuousViolation(points, spans: spans)
                else { return (points, nil) }
            if constraints.contains(where: { abs($0.time - interior.time) < 0.0000000001 &&
                abs($0.x - interior.x) < tolerance && abs($0.y - interior.y) < tolerance }) {
                return (points, interior)
            }
            constraints.append(interior)
        }
        return (points, observedViolation(points, observations: observations) ?? continuousViolation(points, spans: spans))
    }

    private static func compactObservations(_ values: [Observation], anchors: [SimplifiedCameraWaypoint]) -> [Observation] {
        let budget = 1024
        guard values.count > budget else { return values }
        var indices: Set<Int> = [0, values.count - 1]
        for keyPath in [\Observation.x, \Observation.y] {
            if let index = values.indices.min(by: { values[$0][keyPath: keyPath] < values[$1][keyPath: keyPath] }) { indices.insert(index) }
            if let index = values.indices.max(by: { values[$0][keyPath: keyPath] < values[$1][keyPath: keyPath] }) { indices.insert(index) }
        }
        for anchor in anchors {
            if let index = values.indices.min(by: { abs(values[$0].time - anchor.time) < abs(values[$1].time - anchor.time) }) {
                indices.insert(index)
            }
        }
        let remaining = max(2, budget - indices.count)
        for index in 0..<remaining {
            indices.insert(index * (values.count - 1) / (remaining - 1))
        }
        return indices.sorted().map { values[$0] }
    }

    private static func observedViolation(_ points: [SimplifiedCameraWaypoint], observations: [Observation]) -> Observation? {
        var worst = tolerance
        var result: Observation?
        for pointer in observations {
            let camera = interpolated(points, at: pointer.time)
            let error = max(abs(pointer.x - camera.x), abs(pointer.y - camera.y)) - 0.5 / camera.scale
            if error > worst { worst = error; result = pointer }
        }
        return result
    }

    /// Infeasible projections often put the largest residual at a knot which
    /// already exists. Following that residual frame by frame wastes the budget
    /// on one turn. Prefer the remaining pointer turn or stop with the greatest
    /// time-chord deviation before falling back to a geometric constraint cut.
    private static func motionRefinement(_ points: [SimplifiedCameraWaypoint], observations: [Observation],
                                         spans: [PointerSpan], minimumSpacing: Double) -> Observation? {
        var bestDeviation = 0.025
        var result: Observation?
        for (a, b) in zip(points, points.dropFirst()) {
            guard b.time > a.time,
                  let firstSpan = spans.first(where: { $0.start <= a.time && $0.end >= a.time }),
                  let lastSpan = spans.first(where: { $0.start <= b.time && $0.end >= b.time }) else { continue }
            let first = firstSpan.point(at: a.time), last = lastSpan.point(at: b.time)
            for point in observations where point.time > a.time + minimumSpacing && point.time < b.time - minimumSpacing {
                let amount = (point.time - a.time) / (b.time - a.time)
                let x = first.x + (last.x - first.x) * amount
                let y = first.y + (last.y - first.y) * amount
                let deviation = hypot(point.x - x, point.y - y)
                if deviation > bestDeviation { bestDeviation = deviation; result = point }
            }
        }
        return result
    }

    /// Pointer motion is linear between recorded samples. Each viewport edge is
    /// cubic in time, so endpoints plus its derivative roots cover every instant,
    /// including sub-frame cursor movement rather than only planner sample times.
    private static func continuousViolation(_ points: [SimplifiedCameraWaypoint], spans: [PointerSpan]) -> Observation? {
        var worst = tolerance
        var result: Observation?
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            let duration = b.time - a.time
            guard duration > 0 else { continue }
            let radiusA = 0.5 / a.scale, radiusB = 0.5 / b.scale
            for span in spans {
                let lower = max(a.time, span.start), upper = min(b.time, span.end)
                guard upper >= lower else { continue }
                var candidates = [lower, upper]
                for (edgeA, edgeB, velocity) in [(a.x - radiusA, b.x - radiusB, span.vx),
                    (a.x + radiusA, b.x + radiusB, span.vx), (a.y - radiusA, b.y - radiusB, span.vy),
                    (a.y + radiusA, b.y + radiusB, span.vy)] {
                    let change = edgeB - edgeA
                    guard abs(change) > 0.0000000000001 else { continue }
                    let ratio = velocity * duration / (6 * change)
                    guard ratio >= 0, ratio <= 0.25 else { continue }
                    let root = sqrt(max(0, 1 - 4 * ratio))
                    for fraction in [(1 - root) / 2, (1 + root) / 2] {
                        let time = a.time + duration * fraction
                        if time > lower && time < upper { candidates.append(time) }
                    }
                }
                for time in candidates {
                    let pointer = span.point(at: time), camera = interpolated(points, at: time)
                    let error = max(abs(pointer.x - camera.x), abs(pointer.y - camera.y)) - 0.5 / camera.scale
                    if error > worst { worst = error; result = pointer }
                }
            }
        }
        return result
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
