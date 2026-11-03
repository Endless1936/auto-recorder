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

struct ZoomReturn: Sendable {
    var time: Double
    var end: Double = .infinity
    var pose: ZoomPose
}

/// A precomputed path makes random-access export requests deterministic.
struct AutoZoomPlan: Sendable {
    let fps: Int
    let poses: [ZoomPose]
    let returns: [ZoomReturn]

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
        var returnOrigin: ZoomPose?
        var returnSpans: [ZoomReturn] = []
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
                let deadZone = margin * 0.5
                if click { targetX = pointer.x; targetY = pointer.y }
                else {
                    if abs(pointer.x - targetX) > deadZone { targetX = pointer.x - copysign(deadZone, pointer.x - targetX) }
                    if abs(pointer.y - targetY) > deadZone { targetY = pointer.y - copysign(deadZone, pointer.y - targetY) }
                }
                targetX = min(1 - margin, max(margin, targetX))
                targetY = min(1 - margin, max(margin, targetY))
            }
            if active {
                if returnOrigin != nil, returnSpans.last?.end == Double.infinity { returnSpans[returnSpans.count - 1].end = time - step }
                returnOrigin = nil
            } else if returnOrigin == nil {
                returnOrigin = pose
                if pose.scale > 1.005 {
                    returnSpans.append(ZoomReturn(time: max(0, time - step), pose: pose))
                }
            }
            pose.scale += (scale - pose.scale) * alpha
            if let origin = returnOrigin, origin.scale > 1.000000001 {
                let radius = 0.5 / origin.scale
                let amount = min(1, max(0, (0.5 / pose.scale - radius) / (0.5 - radius)))
                pose.x = origin.x + (0.5 - origin.x) * amount
                pose.y = origin.y + (0.5 - origin.y) * amount
            } else {
                pose.x += (targetX - pose.x) * alpha
                pose.y += (targetY - pose.y) * alpha
            }
            let margin = 0.5 / pose.scale
            pose.x = min(1 - margin, max(margin, pose.x))
            pose.y = min(1 - margin, max(margin, pose.y))
            result.append(pose)
        }
        poses = result
        returns = returnSpans
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
