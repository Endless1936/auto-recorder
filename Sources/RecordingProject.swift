import Foundation
import Combine
import AVFoundation

struct DemoZoomPose: Equatable, Sendable {
    var scale: Double = 1
    var x: Double = 0.5
    var y: Double = 0.5
}

struct ZoomCenterPoint: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

struct CameraKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var scale: Double
    // A retained derivative makes adding an unchanged point an exact cubic
    // subdivision instead of restarting easing on either side of that point.
    var slope: Double? = nil
}

struct FramingState {
    var clipID: UUID
    var zoomID: UUID?
    var localTime: Double
    var pose: DemoZoomPose
    var normalizedRect: CGRect
    var pathSamples: [ZoomCenterPoint]
    var handles: [ZoomCenterPoint]
    var canEdit: Bool
    var canResize: Bool = false
    var canSelectAnchors: Bool = false
    var minimumResizeScale: Double = 1
    var selectedHandleTimes: [Double] = []
}

enum EditorSelectionTarget: Equatable {
    case clip
    case cameraAnchors
}

struct ZoomSegment: Identifiable, Codable, Equatable, Sendable {
    static let minimumTransitionDuration = 0.05
    static let minimumHoldDuration = 0.001
    var id: UUID
    var start: Double
    var riseEnd: Double
    var fallStart: Double
    var end: Double
    var peak: Double
    var focusX: Double
    var focusY: Double
    var centerPath: [ZoomCenterPoint]
    var manualFocus: Bool
    // Manual edits retain the original automatic pointer trace for the project.
    // Optional so documents saved before framing editing decode unchanged.
    var manualCenterPath: [ZoomCenterPoint]?
    var cameraKeyframes: [CameraKeyframe]?
    var centerOffsets: [CameraCenterOffset]?
    var centerPanSpans: [CameraPanSpan]?

    init(id: UUID = UUID(), start: Double = 1, riseEnd: Double = 2,
         fallStart: Double = 8, end: Double = 9, peak: Double = 1.6,
         focusX: Double = 0.56, focusY: Double = 0.48,
         centerPath: [ZoomCenterPoint] = [], manualFocus: Bool = false,
         manualCenterPath: [ZoomCenterPoint]? = nil,
         cameraKeyframes: [CameraKeyframe]? = nil,
         centerOffsets: [CameraCenterOffset]? = nil,
         centerPanSpans: [CameraPanSpan]? = nil) {
        self.id = id; self.start = start; self.riseEnd = riseEnd
        self.fallStart = fallStart; self.end = end; self.peak = peak
        self.focusX = focusX; self.focusY = focusY
        self.centerPath = centerPath; self.manualFocus = manualFocus
        self.manualCenterPath = manualCenterPath
        self.cameraKeyframes = cameraKeyframes
        self.centerOffsets = centerOffsets
        self.centerPanSpans = centerPanSpans
    }

    static func standard(duration: Double, peak: Double = 1.6) -> ZoomSegment {
        let span = max(0.2, duration)
        return ZoomSegment(start: span * 0.12, riseEnd: span * 0.25,
                           fallStart: span * 0.72, end: span * 0.88, peak: peak).normalized()
    }

    static func flat(duration: Double) -> ZoomSegment { standard(duration: duration, peak: 1) }
    var isEnabled: Bool { cameraKeyframes.map { $0.count >= 2 } ?? (peak > 1) }

    var cameraControlPoints: [CameraKeyframe] {
        if let points = cameraKeyframes, points.count >= 2 { return points }
        let originalTimes = [start, riseEnd, fallStart, end]
        var times = originalTimes
        if !manualFocus, centerPath.count > 2, start < riseEnd, riseEnd < fallStart, fallStart < end {
            let pathTimes = centerPath.map(\.time).filter { time in
                !originalTimes.contains(where: { abs($0 - time) < 0.000001 })
            }
            let candidates = sortedMotionTimes(pathTimes + originalTimes).filter { $0 >= start && $0 <= end }
            let samples = candidates.map { time -> CameraMotionSample in
                let value = scale(at: time), margin = 0.5 / value
                let center = interpolatedCenter(in: centerPath, at: time)
                return CameraMotionSample(time: time, x: min(1 - margin, max(margin, center.0)),
                    y: min(1 - margin, max(margin, center.1)), scale: value, scaleSlope: scaleDerivative(at: time))
            }
            times = CameraMotion.automaticAnchorTimes(samples: samples, mandatoryTimes: originalTimes)
        }
        return times.map { time in
            let originalIndex = originalTimes.firstIndex(where: { abs($0 - time) < 0.000001 })
            let sourceIndex = centerPath.firstIndex(where: { abs($0.time - time) < 0.000001 }) ?? 0
            let index = originalIndex ?? (sourceIndex + 4)
            var bytes = id.uuid
            let code = UInt64(index + 1)
            bytes.15 ^= UInt8(truncatingIfNeeded: code)
            bytes.14 ^= UInt8(truncatingIfNeeded: code >> 8)
            bytes.13 ^= UInt8(truncatingIfNeeded: code >> 16)
            bytes.12 ^= UInt8(truncatingIfNeeded: code >> 24)
            return CameraKeyframe(id: UUID(uuid: bytes), time: time, scale: scale(at: time),
                                  slope: originalIndex == nil ? scaleDerivative(at: time) : nil)
        }
    }

    var preferredFramingSampleTimes: [Double] {
        let times = centerPath.map(\.time) + (manualCenterPath ?? []).map(\.time) +
            cameraControlPoints.map(\.time) + (centerOffsets ?? []).map(\.time) +
            (centerPanSpans ?? []).flatMap { [$0.start, $0.end] }
        return Array(Set(times.filter(\.isFinite))).sorted()
    }

    private func sortedMotionTimes(_ times: [Double]) -> [Double] {
        var result: [Double] = []
        for time in times.filter(\.isFinite).sorted() where result.last.map({ time - $0 > 0.000001 }) ?? true {
            result.append(time)
        }
        return result
    }

    mutating func enableCameraKeyframes() {
        guard cameraKeyframes == nil else { return }
        let points = cameraControlPoints
        if (manualFocus || centerPath.isEmpty), manualCenterPath == nil {
            manualCenterPath = [ZoomCenterPoint(time: start, x: 0.5, y: 0.5),
                ZoomCenterPoint(time: riseEnd, x: focusX, y: focusY),
                ZoomCenterPoint(time: fallStart, x: focusX, y: focusY),
                ZoomCenterPoint(time: end, x: 0.5, y: 0.5)]
        }
        cameraKeyframes = points
    }

    @discardableResult
    mutating func addCameraKeyframe(at time: Double, tolerance: Double = 0.000001) -> CameraKeyframe? {
        guard time.isFinite, time >= start, time <= end else { return nil }
        enableCameraKeyframes()
        if let existing = cameraKeyframes?.first(where: { abs($0.time - time) <= tolerance }) {
            splitCenterPans(at: existing.time)
            return existing
        }
        let offset = !manualFocus && !centerPath.isEmpty && !(centerOffsets ?? []).isEmpty ? centerOffset(at: time) : nil
        let point = CameraKeyframe(time: time, scale: scale(at: time), slope: scaleDerivative(at: time))
        cameraKeyframes?.append(point)
        cameraKeyframes?.sort { $0.time < $1.time }
        if let offset { storeCenterOffset(offset) }
        splitCenterPans(at: time)
        return point
    }

    mutating func updateCameraKeyframe(id: UUID, time: Double, scale: Double) {
        guard time.isFinite, scale.isFinite else { return }
        enableCameraKeyframes()
        guard var points = cameraKeyframes, let index = points.firstIndex(where: { $0.id == id }) else { return }
        let oldTime = points[index].time
        let preferredGap = min(0.05, max(0.0000011, (end - start) / Double(max(2, points.count * 4))))
        func gap(in available: Double) -> Double {
            min(available, max(0.0000011, min(preferredGap, available / 2)))
        }
        var lower = index > 0 ? points[index - 1].time + gap(in: oldTime - points[index - 1].time) : -Double.greatestFiniteMagnitude
        var upper = index + 1 < points.count ? points[index + 1].time - gap(in: points[index + 1].time - oldTime) : Double.greatestFiniteMagnitude
        if let spans = centerPanSpans, spans.contains(where: { $0.start <= oldTime && oldTime <= $0.end }) {
            let boundaries = spans.flatMap { [$0.start, $0.end] }
            if let previous = boundaries.filter({ $0 < oldTime - 0.000001 }).max() {
                lower = max(lower, previous + gap(in: oldTime - previous))
            }
            if let next = boundaries.filter({ $0 > oldTime + 0.000001 }).min() {
                upper = min(upper, next - gap(in: next - oldTime))
            }
        }
        let nextTime = min(upper, max(lower, time))
        points[index].time = nextTime
        points[index].scale = index == 0 || index == points.count - 1 ? 1 : min(3, max(1, scale))
        for neighbor in max(0, index - 1)...min(points.count - 1, index + 1) { points[neighbor].slope = nil }
        if abs(nextTime - oldTime) > 0.000000001 {
            moveCenterControl(from: oldTime, to: nextTime)
        }
        cameraKeyframes = points
        start = points[0].time; end = points[points.count - 1].time
        peak = points.map(\.scale).max() ?? 1
    }

    /// The caller bounds one shared time delta before applying the batch. Mapping
    /// all center controls from this snapshot avoids collisions between old and
    /// new timestamps when adjacent selected controls move past each other's old positions.
    mutating func moveCameraKeyframes(ids: Set<UUID>, timeDelta: Double, scaleDelta: Double) {
        enableCameraKeyframes()
        guard var points = cameraKeyframes else { return }
        let original = self
        let moving = points.filter { ids.contains($0.id) }
        if abs(timeDelta) > 0.000000001 {
            func isMovedTime(_ time: Double) -> Bool {
                moving.contains { abs($0.time - time) < 0.000001 || abs($0.time + timeDelta - time) < 0.000001 }
            }
            for point in moving { splitCenterPans(at: point.time) }
            if var spans = centerPanSpans {
                for index in spans.indices {
                    var changed = false
                    if let point = moving.first(where: { abs($0.time - spans[index].start) < 0.000001 }) {
                        let center = original.pose(at: point.time)
                        spans[index].start = point.time + timeDelta
                        spans[index].startX = center.x; spans[index].startY = center.y; changed = true
                    }
                    if let point = moving.first(where: { abs($0.time - spans[index].end) < 0.000001 }) {
                        let center = original.pose(at: point.time)
                        spans[index].end = point.time + timeDelta
                        spans[index].endX = center.x; spans[index].endY = center.y; changed = true
                    }
                    if changed { spans[index].useSmoothstepTiming() }
                }
                centerPanSpans = spans
            }
            if !manualFocus, !centerPath.isEmpty {
                centerOffsets = (original.centerOffsets ?? []).filter { !isMovedTime($0.time) }
                for point in moving {
                    let center = original.pose(at: point.time), offset = original.centerOffset(at: point.time)
                    let base = interpolatedCenter(in: centerPath, at: point.time + timeDelta)
                    storeCenterOffset(CameraCenterOffset(time: point.time + timeDelta, x: center.x - base.0,
                        y: center.y - base.1, slopeX: offset.slopeX, slopeY: offset.slopeY))
                }
            } else {
                var path = (original.manualCenterPath ?? []).filter { !isMovedTime($0.time) }
                for point in moving {
                    let center = original.pose(at: point.time)
                    let stored = original.manualCenterPath?.first { abs($0.time - point.time) < 0.000001 }
                    path.append(ZoomCenterPoint(time: point.time + timeDelta, x: stored?.x ?? center.x, y: stored?.y ?? center.y))
                }
                manualCenterPath = path.sorted { $0.time < $1.time }
            }
        }
        for index in points.indices where ids.contains(points[index].id) {
            points[index].time += timeDelta
            points[index].scale = index == 0 || index == points.count - 1 ? 1 : points[index].scale + scaleDelta
            for neighbor in max(0, index - 1)...min(points.count - 1, index + 1) { points[neighbor].slope = nil }
        }
        cameraKeyframes = points
        start = points[0].time; end = points[points.count - 1].time
        peak = points.map(\.scale).max() ?? 1
    }

    private mutating func moveCenterControl(from oldTime: Double, to newTime: Double) {
        let value = pose(at: oldTime)
        splitCenterPans(at: oldTime)
        moveCenterPanEndpoints(from: oldTime, to: newTime, x: value.x, y: value.y)
        if !manualFocus, !centerPath.isEmpty {
            let offset = centerOffset(at: oldTime)
            let base = interpolatedCenter(in: centerPath, at: newTime)
            centerOffsets?.removeAll { abs($0.time - oldTime) < 0.000001 || abs($0.time - newTime) < 0.000001 }
            storeCenterOffset(CameraCenterOffset(time: newTime, x: value.x - base.0, y: value.y - base.1,
                slopeX: offset.slopeX, slopeY: offset.slopeY))
            return
        }
        var path = manualCenterPath ?? []
        let original = path.first(where: { abs($0.time - oldTime) < 0.000001 })
        let moved = ZoomCenterPoint(time: newTime, x: original?.x ?? value.x, y: original?.y ?? value.y)
        path.removeAll { abs($0.time - oldTime) < 0.000001 || abs($0.time - newTime) < 0.000001 }
        path.append(moved)
        path.sort { $0.time < $1.time }
        manualCenterPath = path
    }

    mutating func removeCameraKeyframes(ids: Set<UUID>) {
        enableCameraKeyframes()
        guard let points = cameraKeyframes, points.count > 2 else { return }
        let removed = points.dropFirst().dropLast().filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        var replacementSpans: [CameraPanSpan] = []
        var index = 1
        while index < points.count - 1 {
            guard removedIDs.contains(points[index].id) else { index += 1; continue }
            let left = index - 1
            while index < points.count - 1, removedIDs.contains(points[index].id) { index += 1 }
            let a = points[left].time, b = points[index].time
            let first = pose(at: a), last = pose(at: b)
            replacementSpans.append(CameraPanSpan(start: a, end: b, startX: first.x, startY: first.y,
                endX: last.x, endY: last.y))
        }
        cameraKeyframes = points.filter { !removedIDs.contains($0.id) }
        centerOffsets?.removeAll { offset in removed.contains(where: { abs($0.time - offset.time) < 0.000001 }) }
        if centerOffsets?.isEmpty == true { centerOffsets = nil }
        for span in replacementSpans { replaceCenterPan(with: span) }
        if let controls = cameraKeyframes {
            start = controls[0].time; end = controls[controls.count - 1].time
            peak = controls.map(\.scale).max() ?? 1
        }
    }

    mutating func removeFramingCenter(at time: Double) {
        guard time.isFinite, time > start + 0.000001, time < end - 0.000001 else { return }
        let times = sortedMotionTimes(framingKeyframes.map(\.time) + (centerOffsets ?? []).map(\.time) + [start, end])
        guard let previous = times.filter({ $0 < time - 0.000001 }).last,
              let next = times.first(where: { $0 > time + 0.000001 }) else { return }
        let first = pose(at: previous), last = pose(at: next)
        centerOffsets?.removeAll { abs($0.time - time) < 0.000001 }
        if centerOffsets?.isEmpty == true { centerOffsets = nil }
        replaceCenterPan(with: CameraPanSpan(start: previous, end: next, startX: first.x, startY: first.y,
            endX: last.x, endY: last.y))
    }

    private mutating func replaceCenterPan(with replacement: CameraPanSpan) {
        guard replacement.end > replacement.start else { return }
        var spans: [CameraPanSpan] = []
        for span in centerPanSpans ?? [] {
            if span.end <= replacement.start || span.start >= replacement.end { spans.append(span); continue }
            if let left = span.trimmed(from: span.start, to: replacement.start) { spans.append(left) }
            if let right = span.trimmed(from: replacement.end, to: span.end) { spans.append(right) }
        }
        spans.append(replacement)
        centerPanSpans = spans.sorted { $0.start < $1.start }
    }

    private mutating func splitCenterPans(at time: Double) {
        guard let current = centerPanSpans else { return }
        var spans: [CameraPanSpan] = []
        for span in current {
            if time > span.start + 0.000000001, time < span.end - 0.000000001,
               let left = span.trimmed(from: span.start, to: time),
               let right = span.trimmed(from: time, to: span.end) {
                spans += [left, right]
            } else { spans.append(span) }
        }
        centerPanSpans = spans
    }

    private mutating func updateCenterPanEndpoints(at time: Double, x: Double, y: Double) {
        guard var spans = centerPanSpans else { return }
        for index in spans.indices {
            var changed = false
            if abs(spans[index].start - time) < 0.000001,
               abs(spans[index].startX - x) > 0.000000001 || abs(spans[index].startY - y) > 0.000000001 {
                spans[index].startX = x; spans[index].startY = y; changed = true
            }
            if abs(spans[index].end - time) < 0.000001,
               abs(spans[index].endX - x) > 0.000000001 || abs(spans[index].endY - y) > 0.000000001 {
                spans[index].endX = x; spans[index].endY = y; changed = true
            }
            if changed { spans[index].useSmoothstepTiming() }
        }
        centerPanSpans = spans
    }

    private mutating func moveCenterPanEndpoints(from oldTime: Double, to newTime: Double, x: Double, y: Double) {
        guard var spans = centerPanSpans else { return }
        for index in spans.indices {
            var changed = false
            if abs(spans[index].start - oldTime) < 0.000001 {
                spans[index].start = newTime; spans[index].startX = x; spans[index].startY = y; changed = true
            }
            if abs(spans[index].end - oldTime) < 0.000001 {
                spans[index].end = newTime; spans[index].endX = x; spans[index].endY = y; changed = true
            }
            if changed { spans[index].useSmoothstepTiming() }
        }
        centerPanSpans = spans
        splitCenterPans(at: newTime)
        updateCenterPanEndpoints(at: newTime, x: x, y: y)
    }

    func hasSameContent(as other: ZoomSegment) -> Bool {
        var value = self
        value.id = other.id
        if var points = value.cameraKeyframes, let otherPoints = other.cameraKeyframes,
           points.count == otherPoints.count {
            for index in points.indices { points[index].id = otherPoints[index].id }
            value.cameraKeyframes = points
        }
        return value == other
    }

    /// Keep the original easing domain when a cut intersects a zoom.
    func shifted(by offset: Double) -> ZoomSegment {
        var result = self
        result.start += offset; result.riseEnd += offset
        result.fallStart += offset; result.end += offset
        result.centerPath = centerPath.map { ZoomCenterPoint(time: $0.time + offset, x: $0.x, y: $0.y) }
        result.manualCenterPath = manualCenterPath?.map { ZoomCenterPoint(time: $0.time + offset, x: $0.x, y: $0.y) }
        result.cameraKeyframes = cameraKeyframes?.map { var point = $0; point.time += offset; return point }
        result.centerOffsets = centerOffsets?.map { var point = $0; point.time += offset; return point }
        result.centerPanSpans = centerPanSpans?.map { var span = $0; span.start += offset; span.end += offset; return span }
        return result
    }

    func scale(at time: Double) -> Double {
        if let points = cameraKeyframes, points.count >= 2 {
            guard time.isFinite, let first = points.first, let last = points.last,
                  time >= first.time, time <= last.time else { return 1 }
            if let exact = points.first(where: { abs($0.time - time) < 0.0000000001 }) { return exact.scale }
            guard let upper = points.firstIndex(where: { $0.time > time }), upper > 0 else { return 1 }
            let a = points[upper - 1], b = points[upper]
            let span = b.time - a.time, t = (time - a.time) / span
            let value = (2*t*t*t - 3*t*t + 1) * a.scale + (t*t*t - 2*t*t + t) * span * (a.slope ?? 0) +
                (-2*t*t*t + 3*t*t) * b.scale + (t*t*t - t*t) * span * (b.slope ?? 0)
            return min(3, max(1, value))
        }
        guard start < riseEnd, riseEnd < fallStart, fallStart < end else { return 1 }
        guard time.isFinite, time > start, time < end, peak > 1 else { return 1 }
        if time < riseEnd {
            return 1 + (peak - 1) * Self.smoothstep((time - start) / (riseEnd - start))
        }
        if time <= fallStart { return peak }
        return peak + (1 - peak) * Self.smoothstep((time - fallStart) / (end - fallStart))
    }

    private func scaleDerivative(at time: Double) -> Double {
        if let points = cameraKeyframes, points.count >= 2 {
            if let exact = points.first(where: { abs($0.time - time) < 0.0000000001 }) { return exact.slope ?? 0 }
            guard let upper = points.firstIndex(where: { $0.time > time }), upper > 0 else { return 0 }
            let a = points[upper - 1], b = points[upper], span = b.time - a.time
            let t = (time - a.time) / span
            return ((6*t*t - 6*t) * a.scale + (-6*t*t + 6*t) * b.scale) / span +
                (3*t*t - 4*t + 1) * (a.slope ?? 0) + (3*t*t - 2*t) * (b.slope ?? 0)
        }
        let a: Double, b: Double, delta: Double
        if time > start && time < riseEnd { a = start; b = riseEnd; delta = peak - 1 }
        else if time > fallStart && time < end { a = fallStart; b = end; delta = 1 - peak }
        else { return 0 }
        let t = (time - a) / (b - a)
        return delta * 6 * t * (1 - t) / (b - a)
    }

    func pose(at time: Double) -> DemoZoomPose {
        let scale = self.scale(at: time)
        var center: (Double, Double)
        if let path = manualCenterPath, !path.isEmpty, manualFocus || centerPath.isEmpty {
            center = interpolatedCenter(in: path, at: time, eased: true)
        } else if manualFocus || centerPath.isEmpty {
            let amount = peak > 1 ? (scale - 1) / (peak - 1) : 0
            center = (0.5 + (focusX - 0.5) * amount, 0.5 + (focusY - 0.5) * amount)
        } else {
            let base = interpolatedCenter(in: centerPath, at: time)
            if let offsets = centerOffsets, !offsets.isEmpty {
                let correction = centerOffset(at: time)
                center = (base.0 + correction.x, base.1 + correction.y)
            } else { center = base }
        }
        if let pan = centerPanSpans?.first(where: { $0.start <= time && time <= $0.end }) {
            let value = pan.sample(at: time)
            center = (value.x, value.y)
        }
        let margin = 0.5 / scale
        return DemoZoomPose(scale: scale,
                            x: min(1 - margin, max(margin, center.0)),
                            y: min(1 - margin, max(margin, center.1)))
    }

    var framingKeyframes: [ZoomCenterPoint] {
        if cameraKeyframes != nil || (!manualFocus && !centerPath.isEmpty) {
            return cameraControlPoints.map { point in
                let value = pose(at: point.time)
                return ZoomCenterPoint(time: point.time, x: value.x, y: value.y)
            }
        }
        if manualFocus || centerPath.isEmpty {
            let points = manualCenterPath ?? [ZoomCenterPoint(time: start, x: 0.5, y: 0.5),
                ZoomCenterPoint(time: riseEnd, x: focusX, y: focusY),
                ZoomCenterPoint(time: fallStart, x: focusX, y: focusY),
                ZoomCenterPoint(time: end, x: 0.5, y: 0.5)]
            return points.filter { point in
                !(centerPanSpans ?? []).contains(where: { point.time > $0.start + 0.000001 && point.time < $0.end - 0.000001 })
            }
        }
        return centerPath
    }

    mutating func setFramingCenter(x: Double, y: Double, at time: Double) {
        guard time.isFinite, x.isFinite, y.isFinite else { return }
        if !manualFocus, !centerPath.isEmpty {
            guard let anchor = addCameraKeyframe(at: time) else { return }
            let margin = 0.5 / scale(at: anchor.time)
            let base = interpolatedCenter(in: centerPath, at: anchor.time)
            let previous = centerOffset(at: anchor.time)
            let centerX = min(1 - margin, max(margin, x)), centerY = min(1 - margin, max(margin, y))
            storeCenterOffset(CameraCenterOffset(time: anchor.time, x: centerX - base.0,
                y: centerY - base.1, slopeX: previous.slopeX, slopeY: previous.slopeY))
            updateCenterPanEndpoints(at: anchor.time, x: centerX, y: centerY)
            return
        }
        if cameraKeyframes != nil { _ = addCameraKeyframe(at: time) }
        splitCenterPans(at: time)
        let margin = 0.5 / scale(at: time)
        let point = ZoomCenterPoint(time: time, x: min(1 - margin, max(margin, x)),
                                    y: min(1 - margin, max(margin, y)))
        var path = manualCenterPath ?? [ZoomCenterPoint(time: start, x: 0.5, y: 0.5),
            ZoomCenterPoint(time: riseEnd, x: focusX, y: focusY),
            ZoomCenterPoint(time: fallStart, x: focusX, y: focusY),
            ZoomCenterPoint(time: end, x: 0.5, y: 0.5)]
        if let index = path.firstIndex(where: { abs($0.time - time) < 0.000001 }) {
            path[index].x = point.x
            path[index].y = point.y
        } else {
            path.append(point)
            path.sort { $0.time < $1.time }
        }
        manualCenterPath = path
        updateCenterPanEndpoints(at: time, x: point.x, y: point.y)
    }

    private mutating func storeCenterOffset(_ point: CameraCenterOffset) {
        var values = centerOffsets ?? []
        values.removeAll { abs($0.time - point.time) < 0.000001 }
        values.append(point)
        values.sort { $0.time < $1.time }
        centerOffsets = values
    }

    private func centerOffset(at time: Double) -> CameraCenterOffset {
        let zero = CameraCenterOffset(time: time, x: 0, y: 0)
        guard let values = centerOffsets, !values.isEmpty else { return zero }
        let times = sortedMotionTimes((cameraKeyframes ?? cameraControlPoints).map(\.time) + values.map(\.time))
        guard let first = times.first, let last = times.last, time >= first, time <= last else { return zero }
        func value(at time: Double) -> CameraCenterOffset {
            values.first(where: { abs($0.time - time) < 0.000001 }) ?? CameraCenterOffset(time: time, x: 0, y: 0)
        }
        if let exact = times.first(where: { abs($0 - time) < 0.0000000001 }) {
            var result = value(at: exact); result.time = time; return result
        }
        guard let upper = times.firstIndex(where: { $0 > time }), upper > 0 else { return zero }
        let a = value(at: times[upper - 1]), b = value(at: times[upper])
        let span = b.time - a.time, t = (time - a.time) / span
        return CameraCenterOffset(time: time,
            x: CameraMotion.hermite(a.x, b.x, a.slopeX ?? 0, b.slopeX ?? 0, span, t),
            y: CameraMotion.hermite(a.y, b.y, a.slopeY ?? 0, b.slopeY ?? 0, span, t),
            slopeX: CameraMotion.hermiteDerivative(a.x, b.x, a.slopeX ?? 0, b.slopeX ?? 0, span, t),
            slopeY: CameraMotion.hermiteDerivative(a.y, b.y, a.slopeY ?? 0, b.slopeY ?? 0, span, t))
    }

    private func interpolatedCenter(in path: [ZoomCenterPoint], at time: Double,
                                    eased: Bool = false) -> (Double, Double) {
        guard let first = path.first, let last = path.last else { return (focusX, focusY) }
        if time <= first.time { return (first.x, first.y) }
        if time >= last.time { return (last.x, last.y) }
        var lower = 0, upper = path.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if path[mid].time <= time { lower = mid } else { upper = mid }
        }
        let a = path[lower], b = path[upper]
        let rawFraction = (time - a.time) / max(0.000001, b.time - a.time)
        let fraction = eased ? Self.smoothstep(rawFraction) : rawFraction
        return (a.x + (b.x - a.x) * fraction, a.y + (b.y - a.y) * fraction)
    }

    func normalized() -> ZoomSegment {
        var result = self
        if !result.start.isFinite { result.start = 0 }
        if !result.riseEnd.isFinite { result.riseEnd = result.start }
        if !result.fallStart.isFinite { result.fallStart = result.riseEnd }
        if !result.end.isFinite { result.end = result.fallStart }
        let ramp = Self.minimumTransitionDuration
        let hold = Self.minimumHoldDuration
        let tolerance = 0.000000001
        if result.end - result.start < ramp + hold + ramp - tolerance {
            result.end = result.start + ramp + hold + ramp
        }
        if result.riseEnd - result.start < ramp - tolerance { result.riseEnd = result.start + ramp }
        if result.end - result.riseEnd < ramp + hold - tolerance { result.riseEnd = result.end - ramp - hold }
        if result.fallStart - result.riseEnd < hold - tolerance { result.fallStart = result.riseEnd + hold }
        if result.end - result.fallStart < ramp - tolerance { result.fallStart = result.end - ramp }
        result.peak = result.peak.isFinite ? min(3, max(1, result.peak)) : 1
        result.focusX = result.focusX.isFinite ? min(1, max(0, result.focusX)) : 0.5
        result.focusY = result.focusY.isFinite ? min(1, max(0, result.focusY)) : 0.5
        result.centerPath = result.centerPath.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
            .map { ZoomCenterPoint(time: $0.time, x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        result.manualCenterPath = result.manualCenterPath?.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
            .map { ZoomCenterPoint(time: $0.time, x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        if let raw = result.cameraKeyframes {
            var seenIDs = Set<UUID>()
            var points: [CameraKeyframe] = []
            for var point in raw.filter({ $0.time.isFinite && $0.scale.isFinite }).sorted(by: { $0.time < $1.time }) {
                guard seenIDs.insert(point.id).inserted, points.last.map({ point.time - $0.time > 0.000001 }) ?? true else { continue }
                point.scale = min(3, max(1, point.scale))
                if point.slope?.isFinite == false { point.slope = nil }
                points.append(point)
            }
            if points.count >= 2 {
                points[0].scale = 1; points[points.count - 1].scale = 1
                result.cameraKeyframes = points
                result.start = points[0].time; result.end = points[points.count - 1].time
                result.peak = points.map(\.scale).max() ?? 1
                result.riseEnd = result.start + (result.end - result.start) / 3
                result.fallStart = result.start + (result.end - result.start) * 2 / 3
            } else { result.cameraKeyframes = nil }
        }
        if let raw = result.centerOffsets {
            var points: [CameraCenterOffset] = []
            for var point in raw.filter({ $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }).sorted(by: { $0.time < $1.time }) {
                guard points.last.map({ point.time - $0.time > 0.000001 }) ?? true else { continue }
                if point.slopeX?.isFinite == false { point.slopeX = nil }
                if point.slopeY?.isFinite == false { point.slopeY = nil }
                points.append(point)
            }
            result.centerOffsets = points.isEmpty ? nil : points
        }
        if let raw = result.centerPanSpans {
            var spans: [CameraPanSpan] = []
            for span in raw.filter({ $0.isFinite && $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
                let lower = max(span.start, spans.last?.end ?? span.start)
                if let part = span.trimmed(from: lower, to: span.end) { spans.append(part) }
            }
            result.centerPanSpans = spans.isEmpty ? nil : spans
        }
        return result
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

struct DemoClip: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sourceStart: Double
    var duration: Double
    var zooms: [ZoomSegment]

    init(id: UUID = UUID(), title: String, sourceStart: Double, duration: Double,
         zoom: ZoomSegment? = nil, zooms: [ZoomSegment]? = nil) {
        self.id = id; self.title = title; self.sourceStart = sourceStart; self.duration = duration
        self.zooms = zooms ?? zoom.map { [$0] } ?? []
    }

    var zoom: ZoomSegment {
        get { zooms.first ?? .flat(duration: duration) }
        set { if zooms.isEmpty { zooms = [newValue] } else { zooms[0] = newValue } }
    }

    func pose(at time: Double) -> DemoZoomPose {
        let poses = zooms.map { $0.pose(at: time) }
        let scale = poses.map(\.scale).max() ?? 1
        let weight = poses.reduce(0) { $0 + max(0, $1.scale - 1) }
        guard weight > 0.000000001 else { return DemoZoomPose() }
        // Each camera fades into the overlap continuously. Selecting the whole
        // pose with the largest scale would jump centers where two scales cross.
        let x = poses.reduce(0) { $0 + $1.x * max(0, $1.scale - 1) } / weight
        let y = poses.reduce(0) { $0 + $1.y * max(0, $1.scale - 1) } / weight
        let margin = 0.5 / scale
        return DemoZoomPose(scale: scale, x: min(1 - margin, max(margin, x)),
                            y: min(1 - margin, max(margin, y)))
    }

    func scale(at time: Double) -> Double { pose(at: time).scale }

    func canonicalZooms() -> [ZoomSegment] {
        var result: [ZoomSegment] = []
        for zoom in zooms.map({ $0.normalized() }) where zoom.isEnabled {
            // Only UUID differs for a duplicate. In particular, preserve the
            // original time domain and center path on either side of a cut.
            if !result.contains(where: { $0.hasSameContent(as: zoom) }) { result.append(zoom) }
        }
        return result
    }

    func retainingZooms(in duration: Double, shiftedBy offset: Double = 0) -> [ZoomSegment] {
        canonicalZooms().map { $0.shifted(by: offset) }.filter { $0.end > 0 && $0.start < duration }
    }
}

struct RecordingProject: Codable {
    var version = 1
    var originalFile: String
    var trace: CursorTrace
    var fps: Int32
    private var qualityValue: Int
    var sourceDuration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var clips: [DemoClip]
    var selectedClipID: UUID?
    var selectedZoomID: UUID?
    var playhead: Double
    var folderURL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey {
        case version, originalFile, trace, fps, qualityValue, sourceDuration
        case pixelWidth, pixelHeight, clips, selectedClipID, selectedZoomID, playhead
    }

    var quality: RecordingQuality {
        get { RecordingQuality(rawValue: qualityValue) ?? .hevc }
        set { qualityValue = newValue.rawValue }
    }
    var sourceURL: URL { folderURL.appendingPathComponent(originalFile) }
    var jsonURL: URL { folderURL.appendingPathComponent("project.json") }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    @discardableResult
    mutating func canonicalizeZooms() -> Bool {
        let oldClips = clips, oldClipID = selectedClipID, oldZoomID = selectedZoomID
        for index in clips.indices { clips[index].zooms = clips[index].canonicalZooms() }
        let selection = clips.first(where: { $0.id == selectedClipID }) ?? clips.first
        selectedClipID = selection?.id
        if selection?.zooms.contains(where: { $0.id == selectedZoomID }) != true {
            selectedZoomID = selection?.zooms.first?.id
        }
        return oldClips != clips || oldClipID != selectedClipID || oldZoomID != selectedZoomID
    }

    init(folderURL: URL, originalFile: String, trace: CursorTrace, fps: Int32,
         quality: RecordingQuality, sourceDuration: Double, pixelSize: CGSize, clips: [DemoClip]) {
        self.folderURL = folderURL; self.originalFile = originalFile; self.trace = trace
        self.fps = fps; self.qualityValue = quality.rawValue; self.sourceDuration = sourceDuration
        self.pixelWidth = Int(pixelSize.width); self.pixelHeight = Int(pixelSize.height)
        self.clips = clips; self.selectedClipID = clips.first?.id
        self.selectedZoomID = clips.first?.zooms.first?.id; self.playhead = 0
    }
}

enum ProjectStore {
    static let zoomCleanupBackupName = "project.before-zoom-cleanup.json"

    static func createFolder(in parent: URL, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "录屏 " + formatter.string(from: date)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for index in 1...10_000 {
            let folder = parent.appendingPathComponent(index == 1 ? name : name + " \(index)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw RecorderError.message("无法创建新的录屏工程文件夹。")
    }

    static func create(directory: URL, rawURL: URL, trace: CursorTrace, fps: Int32,
                       quality: RecordingQuality, duration: Double, pixelSize: CGSize,
                       autoZoomEnabled: Bool = true) throws -> RecordingProject {
        guard duration.isFinite, duration > 0, fps > 0, fps <= 60,
              pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0 else {
            throw RecorderError.message("原片的时长或画面尺寸无效。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(rawURL.lastPathComponent)
        if rawURL.standardizedFileURL != destination.standardizedFileURL {
            try FileManager.default.copyItem(at: rawURL, to: destination)
        }
        let zooms = autoZoomEnabled ? automaticZooms(trace: trace, duration: duration, fps: fps) : []
        let clip = DemoClip(title: "录屏", sourceStart: 0, duration: duration, zooms: zooms)
        let project = RecordingProject(folderURL: directory, originalFile: destination.lastPathComponent,
                                       trace: trace, fps: fps, quality: quality, sourceDuration: duration,
                                       pixelSize: pixelSize, clips: [clip])
        try save(project)
        return project
    }

    static func save(_ project: RecordingProject) throws {
        var project = project
        project.canonicalizeZooms()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(project).write(to: project.jsonURL, options: .atomic)
    }

    static func load(folder: URL) throws -> RecordingProject {
        let directory = folder.lastPathComponent == "project.json" ? folder.deletingLastPathComponent() : folder
        let json = directory.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: json.path) else { return try importLegacy(folder: directory) }
        let originalData = try Data(contentsOf: json)
        var project = try JSONDecoder().decode(RecordingProject.self, from: originalData)
        project.folderURL = directory
        // Repair saved degenerate control timing without regenerating the user's
        // camera plan. Negative/outside times from a partial cut stay outside.
        let repaired = project.canonicalizeZooms()
        try validate(project)
        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            throw RecorderError.message("工程中的原片不在文件夹内：\(project.originalFile)")
        }
        if repaired {
            let backup = directory.appendingPathComponent(zoomCleanupBackupName)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try originalData.write(to: backup, options: .atomic)
            }
            try save(project)
        }
        return project
    }

    static func validate(_ project: RecordingProject) throws {
        guard project.version == 1, project.originalFile == URL(fileURLWithPath: project.originalFile).lastPathComponent,
              !project.originalFile.isEmpty, project.fps > 0, project.fps <= 60,
              project.sourceDuration.isFinite, project.sourceDuration > 0,
              project.pixelWidth > 0, project.pixelHeight > 0,
              !project.clips.isEmpty, project.clips.count <= 10_000,
              Set(project.clips.map(\.id)).count == project.clips.count,
              project.playhead.isFinite else { throw RecorderError.message("工程文件内容无效或版本暂不支持。") }
        for clip in project.clips {
            guard clip.sourceStart.isFinite, clip.duration.isFinite, clip.sourceStart >= 0,
                  clip.duration >= 1 / Double(project.fps) - 0.000001,
                  clip.sourceStart + clip.duration <= project.sourceDuration + 0.05,
                  Set(clip.zooms.map(\.id)).count == clip.zooms.count else {
                throw RecorderError.message("工程中有超出原片范围的片段。")
            }
            for zoom in clip.zooms {
                guard zoom == zoom.normalized(), zoom.start < zoom.riseEnd,
                      zoom.riseEnd < zoom.fallStart, zoom.fallStart < zoom.end else {
                    throw RecorderError.message("工程中的放大曲线无效。")
                }
            }
        }
    }

    private static func importLegacy(folder: URL) throws -> RecordingProject {
        let candidates = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter {
                ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        guard candidates.count == 1, let source = candidates.first else {
            throw RecorderError.message(candidates.isEmpty ? "文件夹中没有可编辑的录屏原片。" :
                "文件夹中有多个视频，无法确定原片。请将要编辑的原片单独放进一个文件夹。")
        }
        let cursorURL = source.deletingPathExtension().appendingPathExtension("cursor.json")
        let trace = FileManager.default.fileExists(atPath: cursorURL.path)
            ? try JSONDecoder().decode(CursorTrace.self, from: Data(contentsOf: cursorURL))
            : CursorTrace(samples: [])
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw RecorderError.message("原片缺少视频轨道。")
        }
        let fps = Int32(min(60, max(1, track.nominalFrameRate.rounded())))
        let codec = track.formatDescriptions.first.map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) }
        let quality: RecordingQuality = codec == kCMVideoCodecType_AppleProRes422 ? .proRes : .hevc
        return try create(directory: folder, rawURL: source, trace: trace, fps: fps, quality: quality,
                          duration: asset.duration.seconds, pixelSize: track.naturalSize)
    }

    static func automaticZooms(trace: CursorTrace, duration: Double, fps: Int32) -> [ZoomSegment] {
        guard trace.hasClicks else { return [] }
        let plan = AutoZoomPlan(trace: trace, duration: duration, fps: min(30, Int(fps)))
        let step = 1 / Double(plan.fps)
        let count = min(plan.poses.count, Int(floor(duration * Double(plan.fps))) + 1)
        var groups: [(Int, Int)] = []
        var beginning: Int?
        for index in 0..<count {
            if plan.poses[index].scale > 1.005 {
                if beginning == nil { beginning = index }
            } else if let start = beginning {
                groups.append((start, index - 1)); beginning = nil
            }
        }
        if let start = beginning { groups.append((start, count - 1)) }
        return groups.compactMap { first, last in
            let peak = plan.poses[first...last].map(\.scale).max() ?? 1
            guard peak > 1.02 else { return nil }
            let threshold = 1 + (peak - 1) * 0.97
            let high = (first...last).filter { plan.poses[$0].scale >= threshold }
            let rise = high.first ?? first
            let fall = high.last ?? last
            let start = max(0, Double(first - 1) * step)
            let end = last == count - 1 && plan.poses[last].scale > 1.02
                ? duration + 0.5 : min(duration, Double(last + 1) * step)
            let fallTime = last == count - 1 && plan.poses[last].scale > 1.02
                ? max(Double(fall) * step, duration) : Double(fall) * step
            let path = (max(0, first - 1)...min(plan.poses.count - 1, last + 1)).map {
                ZoomCenterPoint(time: Double($0) * step, x: plan.poses[$0].x, y: plan.poses[$0].y)
            }
            return ZoomSegment(start: start, riseEnd: Double(rise) * step, fallStart: fallTime,
                end: end, peak: peak, focusX: plan.poses[rise].x, focusY: plan.poses[rise].y,
                centerPath: path).normalized()
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var clips: [DemoClip]
    @Published var selectedClipID: UUID?
    @Published var selectedZoomID: UUID?
    @Published var editingSelectionTarget: EditorSelectionTarget = .clip
    @Published var selectedCameraAnchorIDs: Set<UUID> = []
    @Published var selectedMotionPointTime: Double?
    @Published var playhead: Double
    @Published var isPlaying = false {
        didSet { if isPlaying && previewReplacementGeneration == nil { player.play() } else { player.pause() } }
    }
    @Published var focusEditing = false
    @Published private(set) var showsFramingOverlay = false
    @Published private(set) var isFramingPreviewReady = false
    @Published private(set) var previewCameraEffectsEnabled = true
    @Published var message = "打开一个录屏工程开始编辑"
    @Published private(set) var sourceURL: URL?
    @Published private(set) var projectURL: URL?
    @Published var fps: Int32 = 60
    @Published var quality = RecordingQuality.hevc
    @Published var exportProgress = 0.0
    @Published var isExporting = false
    @Published private(set) var sourcePixelSize = CGSize(width: 1920, height: 1080)
    let player = AVPlayer()
    var onError: ((Error) -> Void)?
    private var project: RecordingProject?
    private var periodicObserver: Any?
    private var previewTask: Task<Void, Never>?
    private var previewPending = false
    private var previewScheduleID = UUID()
    private var previewGeneration = UUID()
    private var previewReplacementGeneration: UUID?
    private var loadGeneration = UUID()
    // Allows the regression test to suspend an older request before its commit.
    var beforeProjectLoadCommit: ((URL) async -> Void)?
    var beforePreviewCommit: ((Bool) async -> Void)?
    private var exporter: ProjectExporter?
    private var isLoading = false

    private struct Snapshot: Equatable {
        var clips: [DemoClip]
        var selectedClipID: UUID?
        var selectedZoomID: UUID?
        var playhead: Double
        var editingSelectionTarget: EditorSelectionTarget
        var selectedCameraAnchorIDs: Set<UUID>
        var selectedMotionPointTime: Double?
    }

    private var history: [Snapshot] = []
    private var editingSnapshot: Snapshot?

    init() {
        clips = []; selectedClipID = nil; selectedZoomID = nil; playhead = 0
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                          queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, self.previewReplacementGeneration == nil else { return }
                let value = time.seconds
                if value.isFinite { self.playhead = min(self.totalDuration, max(0, value)) }
                if self.playhead >= self.totalDuration - 0.02 { self.isPlaying = false }
            }
        }
    }

    deinit {
        previewTask?.cancel()
        if let observer = periodicObserver { player.removeTimeObserver(observer) }
    }

    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    var duration: Double { totalDuration }
    var canUndo: Bool { !history.isEmpty || editingSnapshot != nil }
    var selectedClip: DemoClip? { clips.first { $0.id == selectedClipID } }
    var activeClip: DemoClip? { position(at: playhead).map { clips[$0.index] } }
    var activeLocalTime: Double { position(at: playhead)?.localTime ?? 0 }
    var activePose: DemoZoomPose { activeClip?.pose(at: activeLocalTime) ?? DemoZoomPose() }
    var selectedZoom: ZoomSegment? {
        guard let clip = selectedClip else { return nil }
        return clip.zooms.first(where: { $0.id == selectedZoomID && $0.isEnabled }) ??
            clip.zooms.first(where: \.isEnabled)
    }
    var projectTitle: String { projectURL?.lastPathComponent ?? "录屏工程" }
    var hasProject: Bool { project != nil }

    private struct CameraNavigationLocation {
        let time: Double
        let clipID: UUID
        let zoomID: UUID?
        let anchorID: UUID?
    }

    private struct CameraNavigationTarget {
        let time: Double
        var locations: [CameraNavigationLocation]
    }

    private static let cameraNavigationTolerance = 0.000001

    private var cameraNavigationTargets: [CameraNavigationTarget] {
        guard totalDuration.isFinite, totalDuration >= 0 else { return [] }
        var locations: [CameraNavigationLocation] = []
        var offset = 0.0
        for clip in clips {
            guard clip.duration.isFinite, clip.duration >= 0 else { return [] }
            locations.append(CameraNavigationLocation(time: offset, clipID: clip.id, zoomID: nil, anchorID: nil))
            for zoom in clip.zooms {
                for point in zoom.cameraControlPoints where point.time.isFinite && point.time >= 0 && point.time <= clip.duration {
                    locations.append(CameraNavigationLocation(time: offset + point.time,
                        clipID: clip.id, zoomID: zoom.id, anchorID: point.id))
                }
            }
            offset += clip.duration
            locations.append(CameraNavigationLocation(time: offset, clipID: clip.id, zoomID: nil, anchorID: nil))
        }
        let ordered = locations.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        var targets: [CameraNavigationTarget] = []
        for location in ordered {
            if let last = targets.indices.last,
               location.time - targets[last].time <= Self.cameraNavigationTolerance {
                targets[last].locations.append(location)
            } else {
                targets.append(CameraNavigationTarget(time: location.time, locations: [location]))
            }
        }
        return targets.map { target in
            let time = target.locations.first(where: { $0.anchorID == nil })?.time ?? target.time
            return CameraNavigationTarget(time: time, locations: target.locations)
        }
    }

    var cameraNavigationTimes: [Double] { cameraNavigationTargets.map(\.time) }

    /// The preview and curve share one chronological list, including full-view
    /// controls and clip boundaries. Navigation never edits camera data/history.
    @discardableResult
    func navigateCameraTarget(forward: Bool) -> Bool {
        guard !isExporting, !isLoading, editingSnapshot == nil, playhead.isFinite else { return false }
        isPlaying = false
        let targets = cameraNavigationTargets
        let target = forward
            ? targets.first(where: { $0.time > playhead + Self.cameraNavigationTolerance })
            : targets.last(where: { $0.time < playhead - Self.cameraNavigationTolerance })
        guard let target else { return false }
        let ownerID = position(at: target.time).map { clips[$0.index].id }
        let visibleLocations = target.locations.filter { $0.clipID == ownerID }
        let locations = visibleLocations.isEmpty ? target.locations : visibleLocations
        let nodes = locations.filter { $0.anchorID != nil }
        let location = nodes.first(where: { $0.clipID == selectedClipID && $0.zoomID == selectedZoomID }) ??
            nodes.first(where: { $0.clipID == selectedClipID }) ?? nodes.first ?? locations.first!
        selectedClipID = location.clipID
        selectedZoomID = location.zoomID
        selectedMotionPointTime = nil
        if let id = location.anchorID {
            editingSelectionTarget = .cameraAnchors
            selectedCameraAnchorIDs = [id]
        } else {
            enterClipSelection()
        }
        seek(target.time)
        return true
    }

    var canDeleteSelection: Bool {
        guard !isExporting else { return false }
        if editingSelectionTarget == .clip { return clips.count > 1 && selectedClip != nil }
        guard let clip = selectedClip,
              let zoom = clip.zooms.first(where: { $0.id == selectedZoomID }) else { return false }
        if !deletableCameraIDs(in: zoom, clip: clip).isEmpty { return true }
        return deletableMotionTime(in: zoom, clip: clip) != nil
    }

    func selectCameraAnchors(_ ids: Set<UUID>, in clipID: UUID, zoomID: UUID) {
        canonicalizeZooms()
        guard let clip = clips.first(where: { $0.id == clipID }),
              let zoom = clip.zooms.first(where: { $0.id == zoomID }) else { return }
        editingSelectionTarget = .cameraAnchors
        selectedClipID = clipID; selectedZoomID = zoomID
        let visible = Set(zoom.cameraControlPoints.filter { $0.time >= 0 && $0.time <= clip.duration }.map(\.id))
        selectedCameraAnchorIDs = ids.intersection(visible)
        selectedMotionPointTime = nil
    }

    func clearCameraAnchorSelection() {
        editingSelectionTarget = .cameraAnchors
        selectedCameraAnchorIDs.removeAll()
        selectedMotionPointTime = nil
    }

    func beginFramingEditing() {
        editingSelectionTarget = .cameraAnchors
        beginEditing()
    }

    private func enterClipSelection() {
        editingSelectionTarget = .clip
        selectedCameraAnchorIDs.removeAll()
        selectedMotionPointTime = nil
    }

    private func markMotionPoint(at time: Double, in clipID: UUID, zoomID: UUID) {
        guard let clip = clips.first(where: { $0.id == clipID }),
              let zoom = clip.zooms.first(where: { $0.id == zoomID }) else { return }
        if let point = zoom.cameraControlPoints.first(where: { abs($0.time - time) < 0.000001 }) {
            selectCameraAnchors([point.id], in: clipID, zoomID: zoomID)
        } else {
            editingSelectionTarget = .cameraAnchors
            selectedClipID = clipID; selectedZoomID = zoomID
            selectedCameraAnchorIDs.removeAll()
            selectedMotionPointTime = time
        }
    }

    private func storedCenterControls(in zoom: ZoomSegment) -> [ZoomCenterPoint] {
        if zoom.manualFocus || zoom.centerPath.isEmpty { return zoom.manualCenterPath ?? [] }
        return (zoom.centerOffsets ?? []).map { ZoomCenterPoint(time: $0.time, x: $0.x, y: $0.y) }
    }

    private func deletableCameraIDs(in zoom: ZoomSegment, clip: DemoClip) -> Set<UUID> {
        let controls = zoom.cameraControlPoints
        guard controls.count > 2 else { return [] }
        return Set(controls.dropFirst().dropLast().filter {
            selectedCameraAnchorIDs.contains($0.id) && $0.time >= 0 && $0.time <= clip.duration
        }.map(\.id))
    }

    private func deletableMotionTime(in zoom: ZoomSegment, clip: DemoClip) -> Double? {
        guard let time = selectedMotionPointTime, time.isFinite, time >= 0, time <= clip.duration,
              time > zoom.start + 0.000001, time < zoom.end - 0.000001,
              storedCenterControls(in: zoom).contains(where: { abs($0.time - time) < 0.000001 }) else { return nil }
        return time
    }

    var framingState: FramingState? {
        guard showsFramingOverlay, isFramingPreviewReady, let clip = activeClip else { return nil }
        let localTime = activeLocalTime
        let pose = activePose
        let width = 1 / pose.scale
        let rect = CGRect(x: pose.x - width / 2, y: pose.y - width / 2, width: width, height: width)
        let contributors = clip.zooms.filter { $0.isEnabled && $0.scale(at: localTime) > 1.000001 }
        // The visible frame must stay editable after scrubbing away from an old
        // selection. Preserve an explicitly selected overlapping contributor,
        // otherwise edit the dominant zoom at the current playhead.
        let selectedContributor = !isPlaying && clip.id == selectedClipID
            ? contributors.first(where: { $0.id == selectedZoomID }) : nil
        let covering = clip.zooms.filter { $0.isEnabled && $0.start <= localTime && localTime <= $0.end }
        let zoom = selectedContributor ?? contributors.max(by: { $0.scale(at: localTime) < $1.scale(at: localTime) }) ??
            covering.first(where: { $0.id == selectedZoomID && clip.id == selectedClipID }) ?? covering.first
        guard let zoom else {
            return FramingState(clipID: clip.id, zoomID: nil, localTime: localTime, pose: pose,
                normalizedRect: rect, pathSamples: [], handles: [], canEdit: false)
        }
        let lower = max(0, zoom.start), upper = min(clip.duration, zoom.end)
        guard upper > lower else { return nil }
        var sampleTimes = (0..<80).map { lower + (upper - lower) * Double($0) / 79 }
        sampleTimes += clip.zooms.flatMap(\.preferredFramingSampleTimes).filter { lower <= $0 && $0 <= upper }
        sampleTimes = Array(Set(sampleTimes)).sorted()
        let samples = sampleTimes.map { time -> ZoomCenterPoint in
            let value = clip.pose(at: time)
            return ZoomCenterPoint(time: time, x: value.x, y: value.y)
        }
        var points = zoom.framingKeyframes.filter { lower <= $0.time && $0.time <= upper }
        // A sliced segment can have all of its original controls outside the
        // visible clip. Expose its boundary centers without trimming the path.
        for time in [lower, upper] where zoom.scale(at: time) > 1.000001 {
            if !points.contains(where: { abs($0.time - time) < 0.000001 }) {
                let value = clip.pose(at: time)
                points.append(ZoomCenterPoint(time: time, x: value.x, y: value.y))
            }
        }
        points.sort { $0.time < $1.time }
        let handles = points.map { point -> ZoomCenterPoint in
            let value = clip.pose(at: point.time)
            return ZoomCenterPoint(time: point.time, x: value.x, y: value.y)
        }
        return FramingState(clipID: clip.id, zoomID: zoom.id, localTime: localTime, pose: pose,
            normalizedRect: rect, pathSamples: samples, handles: handles,
            canEdit: !isPlaying && zoom.scale(at: localTime) > 1.000001,
            canResize: !isPlaying && localTime > zoom.start + 0.000001 && localTime < zoom.end - 0.000001,
            canSelectAnchors: !isPlaying,
            minimumResizeScale: clip.zooms.filter { $0.id != zoom.id }.map { $0.scale(at: localTime) }.max() ?? 1,
            selectedHandleTimes: editingSelectionTarget == .cameraAnchors && clip.id == selectedClipID && zoom.id == selectedZoomID
                ? Array(Set(zoom.cameraControlPoints.filter { selectedCameraAnchorIDs.contains($0.id) }.map(\.time) +
                    (selectedMotionPointTime.map { [$0] } ?? []))).sorted() : [])
    }

    func setShowsFramingOverlay(_ value: Bool) {
        guard showsFramingOverlay != value else { return }
        if value { clearCameraAnchorSelection() }
        showsFramingOverlay = value
        isFramingPreviewReady = false
        schedulePreview()
    }

    func toggleFramingOverlay() { setShowsFramingOverlay(!showsFramingOverlay) }

    var canAddFramingAnchor: Bool { showsFramingOverlay && !isPlaying && framingState?.zoomID != nil }

    func addFramingAnchor() {
        guard canAddFramingAnchor, let state = framingState,
              let clip = clips.first(where: { $0.id == state.clipID }),
              var zoom = clip.zooms.first(where: { $0.id == state.zoomID }) else { return }
        let tolerance = 0.5 / Double(max(1, fps))
        guard let point = zoom.addCameraKeyframe(at: state.localTime, tolerance: tolerance) else { return }
        setZoom(zoom, for: clip.id)
        selectCameraAnchors([point.id], in: clip.id, zoomID: zoom.id)
        seek(startTime(of: clip.id) + point.time)
        message = "已添加取景锚点"
    }

    func selectFramingAnchor(at time: Double) {
        guard let state = framingState, let id = state.zoomID else { return }
        selectFramingAnchor(clipID: state.clipID, zoomID: id, at: time)
    }

    func selectFramingAnchor(clipID: UUID, zoomID: UUID, at time: Double) {
        guard let target = framingTarget(clipID: clipID, zoomID: zoomID, time: time) else { return }
        isPlaying = false
        selectZoom(zoomID)
        markMotionPoint(at: time, in: target.clip.id, zoomID: zoomID)
        seek(startTime(of: target.clip.id) + time)
    }

    private func framingTarget(clipID: UUID, zoomID: UUID, time: Double) -> (clip: DemoClip, zoom: ZoomSegment)? {
        guard showsFramingOverlay, isFramingPreviewReady, !isPlaying, !isExporting,
              time.isFinite, let clip = clips.first(where: { $0.id == clipID }),
              let zoom = clip.zooms.first(where: { $0.id == zoomID }),
              zoom.isEnabled, time >= max(0, zoom.start), time <= min(clip.duration, zoom.end) else { return nil }
        return (clip, zoom)
    }

    func updateFramingScale(_ scale: Double) {
        guard let state = framingState, let id = state.zoomID else { return }
        updateFramingScale(clipID: state.clipID, zoomID: id, time: state.localTime, scale: scale)
    }

    func updateFramingScale(clipID: UUID, zoomID: UUID, time: Double, scale: Double) {
        guard scale.isFinite, let target = framingTarget(clipID: clipID, zoomID: zoomID, time: time),
              time > target.zoom.start + 0.000001, time < target.zoom.end - 0.000001 else { return }
        let clip = target.clip
        var zoom = target.zoom
        let pose = clip.pose(at: time)
        let others = clip.zooms.filter { $0.id != zoom.id }.map { $0.pose(at: time) }
        let otherMaximum = others.map(\.scale).max() ?? 1
        let requested = min(3, max(1, scale))
        if zoom.scale(at: time) <= otherMaximum + 0.000001 && requested <= otherMaximum + 0.000001 {
            if otherMaximum > 1.000001 { message = "其他重叠放大段限制当前倍率" }
            return
        }
        let targetScale = max(requested, otherMaximum)
        let selectedWeight = targetScale - 1
        let otherWeight = others.reduce(0) { $0 + max(0, $1.scale - 1) }
        let totalWeight = selectedWeight + otherWeight
        let centerX = selectedWeight > 0 ?
            (pose.x * totalWeight - others.reduce(0) { $0 + $1.x * max(0, $1.scale - 1) }) / selectedWeight : 0.5
        let centerY = selectedWeight > 0 ?
            (pose.y * totalWeight - others.reduce(0) { $0 + $1.y * max(0, $1.scale - 1) }) / selectedWeight : 0.5
        guard let point = zoom.addCameraKeyframe(at: time) else { return }
        zoom.updateCameraKeyframe(id: point.id, time: point.time, scale: targetScale)
        zoom.setFramingCenter(x: centerX, y: centerY, at: time)
        setZoom(zoom, for: clip.id)
        markMotionPoint(at: point.time, in: clip.id, zoomID: zoom.id)
        if requested < otherMaximum - 0.000001 { message = "其他重叠放大段限制当前倍率" }
    }

    func updateCameraAnchor(id: UUID, time: Double, scale: Double) {
        guard time.isFinite, scale.isFinite, let clip = selectedClip, var zoom = selectedZoom else { return }
        var boundedTime = min(clip.duration, max(0, time))
        let controls = zoom.cameraControlPoints
        let others = clip.canonicalZooms().filter { $0.id != zoom.id }
        if controls.first?.id == id {
            let left = others.filter { $0.start <= zoom.start }.map(\.end).max() ?? -.infinity
            boundedTime = max(boundedTime, min(zoom.start, left))
        }
        if controls.last?.id == id {
            let right = others.filter { $0.end >= zoom.end }.map(\.start).min() ?? .infinity
            boundedTime = min(boundedTime, max(zoom.end, right))
        }
        zoom.updateCameraKeyframe(id: id, time: boundedTime, scale: scale)
        setZoom(zoom, for: clip.id)
        selectCameraAnchors([id], in: clip.id, zoomID: zoom.id)
        if let point = zoom.cameraControlPoints.first(where: { $0.id == id }) {
            seek(startTime(of: clip.id) + point.time)
        }
    }

    /// All values are derived from the gesture's immutable starting segment.
    /// Multiple controls share bounded time/scale deltas so their spacing and
    /// relative amplitudes survive neighboring controls and the 1×/3× limits.
    @discardableResult
    func dragCameraAnchors(from base: ZoomSegment, ids: Set<UUID>, timeDelta: Double,
                           scaleDelta: Double, snapTolerance: Double) -> Double? {
        guard timeDelta.isFinite, scaleDelta.isFinite, snapTolerance.isFinite,
              let clip = selectedClip, let current = selectedZoom, current.id == base.id else { return nil }
        let controls = base.cameraControlPoints
        let selected = controls.enumerated().filter { ids.contains($0.element.id) }
        guard !selected.isEmpty else { return nil }
        selectCameraAnchors(Set(selected.map { $0.element.id }), in: clip.id, zoomID: base.id)
        let amplitudeControls = selected.filter { $0.offset > 0 && $0.offset < controls.count - 1 }
        let selectedIDs = Set(selected.map { $0.element.id })
        let isGroup = selected.count > 1
        var delta = 0.0
        var snappedScale: Double?
        if !amplitudeControls.isEmpty {
            let minimumDelta = 1 - amplitudeControls.map { $0.element.scale }.min()!
            let maximumDelta = 3 - amplitudeControls.map { $0.element.scale }.max()!
            delta = min(maximumDelta, max(minimumDelta, scaleDelta))
            if snapTolerance > 0 && abs(scaleDelta) > 0.000000001 {
                let requestedDelta = delta
                var levels: Set<Double> = [1, 3]
                for candidateClip in clips {
                    for zoom in candidateClip.zooms {
                        for point in zoom.cameraControlPoints where !selectedIDs.contains(point.id) &&
                            point.time >= 0 && point.time <= candidateClip.duration {
                            levels.insert(point.scale)
                        }
                    }
                }
                var bestDistance = Double.infinity
                for control in amplitudeControls {
                    for level in levels.sorted() {
                        let candidate = level - control.element.scale
                        let distance = abs(candidate - requestedDelta)
                        guard candidate >= minimumDelta - 0.000000001,
                              candidate <= maximumDelta + 0.000000001,
                              distance <= snapTolerance, distance < bestDistance else { continue }
                        bestDistance = distance
                        delta = min(maximumDelta, max(minimumDelta, candidate))
                        snappedScale = level
                    }
                }
            }
        }
        var next = base
        if isGroup {
            var minimumTimeDelta = -selected.map { $0.element.time }.min()!
            var maximumTimeDelta = clip.duration - selected.map { $0.element.time }.max()!
            let preferredGap = min(0.05, max(0.0000011, (base.end - base.start) / Double(max(2, controls.count * 4))))
            func gap(_ available: Double) -> Double {
                min(available, max(0.0000011, min(preferredGap, available / 2)))
            }
            for control in selected {
                let index = control.offset, time = control.element.time
                if index > 0, !selectedIDs.contains(controls[index - 1].id) {
                    let previous = controls[index - 1].time
                    minimumTimeDelta = max(minimumTimeDelta, previous + gap(time - previous) - time)
                }
                if index + 1 < controls.count, !selectedIDs.contains(controls[index + 1].id) {
                    let following = controls[index + 1].time
                    maximumTimeDelta = min(maximumTimeDelta, following - gap(following - time) - time)
                }
                if let spans = base.centerPanSpans, spans.contains(where: { $0.start <= time && time <= $0.end }) {
                    let fixedBoundaries = spans.flatMap { [$0.start, $0.end] }.filter { boundary in
                        !selected.contains { abs($0.element.time - boundary) < 0.000001 }
                    }
                    if let previous = fixedBoundaries.filter({ $0 < time - 0.000001 }).max() {
                        minimumTimeDelta = max(minimumTimeDelta, previous + gap(time - previous) - time)
                    }
                    if let following = fixedBoundaries.filter({ $0 > time + 0.000001 }).min() {
                        maximumTimeDelta = min(maximumTimeDelta, following - gap(following - time) - time)
                    }
                }
            }
            let others = clip.canonicalZooms().filter { $0.id != base.id }
            if let first = controls.first, selectedIDs.contains(first.id) {
                let left = others.filter { $0.start <= base.start }.map(\.end).max() ?? -.infinity
                minimumTimeDelta = max(minimumTimeDelta, min(base.start, left) - first.time)
            }
            if let last = controls.last, selectedIDs.contains(last.id) {
                let right = others.filter { $0.end >= base.end }.map(\.start).min() ?? .infinity
                maximumTimeDelta = min(maximumTimeDelta, max(base.end, right) - last.time)
            }
            let shift = min(maximumTimeDelta, max(minimumTimeDelta, timeDelta))
            if abs(delta) > 0.000000001 || abs(shift) > 0.000000001 {
                next.moveCameraKeyframes(ids: selectedIDs, timeDelta: shift, scaleDelta: delta)
            }
        } else if let control = selected.first {
            let point = control.element
            var time = min(clip.duration, max(0, point.time + timeDelta))
            let others = clip.canonicalZooms().filter { $0.id != base.id }
            if control.offset == 0 {
                let left = others.filter { $0.start <= base.start }.map(\.end).max() ?? -.infinity
                time = max(time, min(base.start, left))
            }
            if control.offset == controls.count - 1 {
                let right = others.filter { $0.end >= base.end }.map(\.start).min() ?? .infinity
                time = min(time, max(base.end, right))
            }
            next.updateCameraKeyframe(id: point.id, time: time,
                                      scale: control.offset == 0 || control.offset == controls.count - 1 ? 1 : point.scale + delta)
            let result = next.cameraControlPoints.first(where: { $0.id == point.id })!
            if abs(result.time - point.time) <= 0.000000001 && abs(result.scale - point.scale) <= 0.000000001 {
                next = base
            }
        }
        next = next.normalized()
        guard next != current else { return snappedScale }
        setZoom(next, for: clip.id)
        if !isGroup, let id = selected.first?.element.id,
           let point = next.cameraControlPoints.first(where: { $0.id == id }) {
            seek(startTime(of: clip.id) + point.time)
        }
        return snappedScale
    }

    func updateFramingCenter(x: Double, y: Double) {
        guard let state = framingState, let id = state.zoomID else { return }
        updateFramingCenter(clipID: state.clipID, zoomID: id, time: state.localTime, x: x, y: y)
    }

    func updateFramingCenter(clipID: UUID, zoomID: UUID, time: Double, x: Double, y: Double) {
        updateFramingKeyframe(clipID: clipID, zoomID: zoomID, time: time, x: x, y: y)
    }

    func updateFramingKeyframe(time: Double, x: Double, y: Double) {
        guard let state = framingState, let id = state.zoomID else { return }
        updateFramingKeyframe(clipID: state.clipID, zoomID: id, time: time, x: x, y: y)
    }

    func updateFramingKeyframe(clipID: UUID, zoomID: UUID, time: Double, x: Double, y: Double) {
        guard x.isFinite, y.isFinite, let target = framingTarget(clipID: clipID, zoomID: zoomID, time: time),
              target.zoom.scale(at: time) > 1.000001 else { return }
        let clip = target.clip
        var zoom = target.zoom
        let previous = clip.pose(at: time)
        let margin = 0.5 / previous.scale
        let nextX = min(1 - margin, max(margin, x)), nextY = min(1 - margin, max(margin, y))
        guard abs(previous.x - nextX) > 0.000000001 || abs(previous.y - nextY) > 0.000000001 else { return }
        let selectedWeight = zoom.scale(at: time) - 1
        let others = clip.zooms.filter { $0.id != zoom.id }.map { $0.pose(at: time) }
        let totalWeight = selectedWeight + others.reduce(0) { $0 + max(0, $1.scale - 1) }
        let centerX = (nextX * totalWeight - others.reduce(0) { $0 + $1.x * max(0, $1.scale - 1) }) / selectedWeight
        let centerY = (nextY * totalWeight - others.reduce(0) { $0 + $1.y * max(0, $1.scale - 1) }) / selectedWeight
        zoom.setFramingCenter(x: centerX, y: centerY, at: time)
        setZoom(zoom, for: clip.id)
        markMotionPoint(at: time, in: clip.id, zoomID: zoom.id)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(value) / 60
        return String(format: "%02d:%04.1f", minutes, value - Double(minutes * 60))
    }

    func startTime(of id: UUID) -> Double {
        var time = 0.0
        for clip in clips {
            if clip.id == id { return time }
            time += clip.duration
        }
        return 0
    }

    func select(_ id: UUID) {
        canonicalizeZooms()
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        enterClipSelection()
        selectedClipID = id
        selectedZoomID = clip.zooms.first?.id
        let start = startTime(of: id)
        if playhead < start || playhead >= start + clip.duration {
            seek(start)
        }
    }

    func seek(_ time: Double) {
        guard time.isFinite else { return }
        playhead = min(totalDuration, max(0, time))
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginEditing() {
        if editingSnapshot == nil { editingSnapshot = snapshot() }
    }

    func endEditing() {
        guard let before = editingSnapshot else { return }
        editingSnapshot = nil
        if before.clips != clips {
            remember(before)
            commitEdits(rebuildPreview: !showsFramingOverlay || !onlyZoomsChanged(from: before.clips))
        }
    }

    func setZoom(_ zoom: ZoomSegment, for id: UUID, recordUndo: Bool = true) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        editingSelectionTarget = .cameraAnchors
        let before = snapshot()
        let changesContext = selectedClipID != id || selectedZoomID != zoom.id
        let next = zoom.normalized()
        if !next.isEnabled {
            clips[index].zooms.removeAll { $0.id == next.id }
        } else if let zoomIndex = clips[index].zooms.firstIndex(where: { $0.id == next.id }) {
            clips[index].zooms[zoomIndex] = next
        } else { clips[index].zooms.append(next) }
        if next.isEnabled {
            // Keep the node being dragged alive when its values meet another
            // segment; its end gesture must still close the undo transaction.
            clips[index].zooms.removeAll { $0.id != next.id && $0.hasSameContent(as: next) }
        }
        selectedClipID = id
        selectedZoomID = next.id
        if changesContext {
            selectedCameraAnchorIDs.removeAll()
            selectedMotionPointTime = nil
        }
        canonicalizeZooms()
        if next.isEnabled, let survivor = clips[index].zooms.first(where: { $0.hasSameContent(as: next) }) {
            selectedZoomID = survivor.id
        }
        guard before.clips != clips else { return }
        if recordUndo && editingSnapshot == nil { remember(before) }
        message = "放大方案已更新"
        if editingSnapshot == nil { commitEdits(rebuildPreview: !showsFramingOverlay) }
        else if !showsFramingOverlay { schedulePreview() }
    }

    func updateZoom(_ zoom: ZoomSegment, for id: UUID, registerUndo: Bool = true) {
        setZoom(zoom, for: id, recordUndo: registerUndo)
    }

    func resetZoom() {
        guard let clip = selectedClip, var zoom = selectedZoom else { return }
        zoom.cameraKeyframes = nil
        zoom.peak = 1
        setZoom(zoom, for: clip.id)
        message = "已移除此放大段"
    }

    func addZoom() {
        canonicalizeZooms()
        guard let clip = activeClip ?? selectedClip else { return }
        isPlaying = false
        let local = min(clip.duration, max(0, playhead - startTime(of: clip.id)))
        let occupied = clip.zooms.filter(\.isEnabled)
        let covering = occupied.filter { $0.start <= local && local <= $0.end }
        if let existing = covering.first(where: { $0.id == selectedZoomID }) ??
            covering.max(by: { $0.scale(at: local) < $1.scale(at: local) }) {
            selectZoom(existing.id)
            let lastFrame = max(0, clip.duration - 1 / Double(max(1, fps)))
            seek(startTime(of: clip.id) + min(lastFrame, max(0, existing.riseEnd)))
            message = "已选中此处的放大段"
            return
        }
        let lower = max(0, occupied.filter { $0.end < local }.map(\.end).max() ?? 0)
        let upper = min(clip.duration, occupied.filter { $0.start > local }.map(\.start).min() ?? clip.duration)
        let minimumSpan = ZoomSegment.minimumTransitionDuration * 2 + ZoomSegment.minimumHoldDuration
        let available = upper - lower
        guard available >= minimumSpan - 0.000000001 else {
            message = "此处没有足够空间添加放大"
            return
        }
        let span = min(4, available)
        let start = min(max(lower, local - span * 0.2), upper - span)
        let ramp = max(ZoomSegment.minimumTransitionDuration, span * 0.2)
        let zoom = ZoomSegment(start: start, riseEnd: start + ramp,
                               fallStart: start + span - ramp, end: start + span,
                               manualFocus: true).normalized()
        setZoom(zoom, for: clip.id)
        selectedZoomID = zoom.id
        seek(startTime(of: clip.id) + zoom.riseEnd)
        message = "已添加一次放大"
    }

    func selectZoom(_ id: UUID) {
        canonicalizeZooms()
        guard let clip = clips.first(where: { $0.zooms.contains(where: { $0.id == id && $0.isEnabled }) }) else { return }
        editingSelectionTarget = .cameraAnchors
        if selectedClipID != clip.id || selectedZoomID != id {
            selectedCameraAnchorIDs.removeAll()
            selectedMotionPointTime = nil
        }
        selectedClipID = clip.id; selectedZoomID = id
    }

    @discardableResult
    func split() -> Bool {
        guard let position = position(at: playhead) else { return false }
        let index = position.index
        let clip = clips[index]
        let cut = position.localTime
        guard cut >= 0.2, clip.duration - cut >= 0.2 else {
            message = "将播放头移到片段中间再分割"
            return false
        }
        let before = snapshot()
        enterClipSelection()
        var left = clip
        left.duration = cut
        left.zooms = clip.retainingZooms(in: cut)
        var right = DemoClip(title: clip.title, sourceStart: clip.sourceStart + cut,
                             duration: clip.duration - cut,
                             zooms: clip.retainingZooms(in: clip.duration - cut, shiftedBy: -cut))
        right.zooms = right.zooms.map { var zoom = $0; zoom.id = UUID(); return zoom }
        clips.replaceSubrange(index...index, with: [left, right])
        selectedClipID = right.id
        selectedZoomID = right.zooms.first?.id
        recordChange(before)
        message = "已在播放头处分割"
        return true
    }

    @discardableResult
    func deleteSelected() -> Bool {
        guard !isExporting else { return false }
        if editingSelectionTarget == .cameraAnchors { return deleteCameraSelection() }
        guard clips.count > 1,
              let index = clips.firstIndex(where: { $0.id == selectedClipID }) else {
            message = "至少保留一个片段"
            return false
        }
        let before = snapshot()
        let anchorID = activeClip?.id
        let anchorTime = activeLocalTime
        clips.remove(at: index)
        selectedClipID = clips[min(index, clips.count - 1)].id
        selectedZoomID = selectedClip?.zooms.first?.id
        restorePlayhead(clipID: anchorID, localTime: anchorTime,
                        fallback: startTime(of: selectedClipID!))
        recordChange(before)
        message = "已删除片段，后面的内容自动接上"
        return true
    }

    @discardableResult
    private func deleteCameraSelection() -> Bool {
        guard let clip = selectedClip,
              var zoom = clip.zooms.first(where: { $0.id == selectedZoomID }) else { return false }
        let ids = deletableCameraIDs(in: zoom, clip: clip)
        let motionTime = deletableMotionTime(in: zoom, clip: clip)
        guard !ids.isEmpty || motionTime != nil else {
            message = selectedCameraAnchorIDs.isEmpty && selectedMotionPointTime == nil
                ? "先选择要删除的取景锚点" : "首尾全景锚点不能删除"
            return false
        }
        if !ids.isEmpty {
            zoom.removeCameraKeyframes(ids: ids)
        }
        if let motionTime { zoom.removeFramingCenter(at: motionTime) }
        setZoom(zoom, for: clip.id)
        clearCameraAnchorSelection()
        message = "已删除取景锚点"
        return true
    }

    func moveClip(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = clips.firstIndex(where: { $0.id == id }),
              clips.contains(where: { $0.id == targetID }) else { return }
        let before = snapshot()
        enterClipSelection()
        let anchorID = activeClip?.id
        let anchorTime = activeLocalTime
        let item = clips.remove(at: from)
        guard let target = clips.firstIndex(where: { $0.id == targetID }) else { return }
        clips.insert(item, at: target)
        selectedClipID = id
        selectedZoomID = item.zooms.first?.id
        restorePlayhead(clipID: anchorID, localTime: anchorTime)
        if before.clips != clips {
            recordChange(before)
            message = "片段顺序已更新"
        }
    }

    func moveClipToEnd(id: UUID) {
        guard let from = clips.firstIndex(where: { $0.id == id }), from != clips.count - 1 else { return }
        let before = snapshot()
        enterClipSelection()
        let anchorID = activeClip?.id
        let anchorTime = activeLocalTime
        let item = clips.remove(at: from)
        clips.append(item)
        selectedClipID = id
        selectedZoomID = item.zooms.first?.id
        restorePlayhead(clipID: anchorID, localTime: anchorTime)
        recordChange(before)
        message = "片段已移到最后"
    }

    @discardableResult
    func trimSelected(start: Double, end: Double) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == selectedClipID }),
              start.isFinite, end.isFinite else { return false }
        let clip = clips[index]
        let lower = min(clip.duration, max(0, start))
        let upper = min(clip.duration, max(0, end))
        guard upper - lower >= 0.2 else {
            message = "片段至少保留 0.2 秒"
            return false
        }
        guard lower > 0.000_001 || upper < clip.duration - 0.000_001 else { return false }
        let before = snapshot()
        enterClipSelection()
        let anchorID = activeClip?.id
        var anchorTime = activeLocalTime
        if anchorID == clip.id { anchorTime -= lower }
        clips[index].sourceStart += lower
        clips[index].duration = upper - lower
        clips[index].zooms = clip.retainingZooms(in: upper - lower, shiftedBy: -lower)
        selectedZoomID = clips[index].zooms.first?.id
        restorePlayhead(clipID: anchorID, localTime: anchorTime)
        recordChange(before)
        message = "片段范围已更新"
        return true
    }

    func undo() {
        let previousClips = clips
        if let pending = editingSnapshot {
            editingSnapshot = nil
            if pending.clips != clips {
                restore(pending)
                message = "已撤销"
                commitEdits(rebuildPreview: !showsFramingOverlay || !onlyZoomsChanged(from: previousClips))
                return
            }
        }
        guard let previous = history.popLast() else { return }
        restore(previous)
        message = "已撤销"
        commitEdits(rebuildPreview: !showsFramingOverlay || !onlyZoomsChanged(from: previousClips))
    }

    private func position(at time: Double) -> (index: Int, localTime: Double)? {
        guard !clips.isEmpty else { return nil }
        let time = min(totalDuration, max(0, time))
        var offset = 0.0
        for (index, clip) in clips.enumerated() {
            if time < offset + clip.duration || index == clips.count - 1 {
                return (index, min(clip.duration, max(0, time - offset)))
            }
            offset += clip.duration
        }
        return nil
    }

    private func restorePlayhead(clipID: UUID?, localTime: Double, fallback: Double? = nil) {
        if let id = clipID, let clip = clips.first(where: { $0.id == id }) {
            playhead = startTime(of: id) + min(clip.duration, max(0, localTime))
        } else {
            playhead = min(totalDuration, max(0, fallback ?? playhead))
        }
    }

    private func canonicalizeZooms() {
        for index in clips.indices {
            let canonical = clips[index].canonicalZooms()
            if clips[index].zooms != canonical { clips[index].zooms = canonical }
        }
        let selection = selectedClip ?? clips.first
        if selectedClipID != selection?.id { selectedClipID = selection?.id }
        if selection?.zooms.contains(where: { $0.id == selectedZoomID }) != true {
            selectedZoomID = selection?.zooms.first?.id
        }
        pruneCameraAnchorSelection()
    }

    private func pruneCameraAnchorSelection() {
        guard editingSelectionTarget == .cameraAnchors,
              let clip = selectedClip, let zoom = clip.zooms.first(where: { $0.id == selectedZoomID }) else {
            selectedCameraAnchorIDs.removeAll()
            selectedMotionPointTime = nil
            return
        }
        let visible = Set(zoom.cameraControlPoints.filter { $0.time >= 0 && $0.time <= clip.duration }.map(\.id))
        selectedCameraAnchorIDs.formIntersection(visible)
        if let time = selectedMotionPointTime,
           !time.isFinite || time < 0 || time > clip.duration ||
            !storedCenterControls(in: zoom).contains(where: { abs($0.time - time) < 0.000001 }) {
            selectedMotionPointTime = nil
        }
    }

    private func snapshot() -> Snapshot {
        canonicalizeZooms()
        return Snapshot(clips: clips, selectedClipID: selectedClipID, selectedZoomID: selectedZoomID, playhead: playhead,
                        editingSelectionTarget: editingSelectionTarget, selectedCameraAnchorIDs: selectedCameraAnchorIDs,
                        selectedMotionPointTime: selectedMotionPointTime)
    }

    private func remember(_ snapshot: Snapshot) {
        history.append(snapshot)
        if history.count > 80 { history.removeFirst(history.count - 80) }
        objectWillChange.send()
    }

    private func recordChange(_ snapshot: Snapshot) {
        if editingSnapshot == nil { remember(snapshot); commitEdits() }
    }

    private func restore(_ snapshot: Snapshot) {
        clips = snapshot.clips
        selectedClipID = snapshot.selectedClipID
        selectedZoomID = snapshot.selectedZoomID
        editingSelectionTarget = snapshot.editingSelectionTarget
        selectedCameraAnchorIDs = snapshot.selectedCameraAnchorIDs
        selectedMotionPointTime = snapshot.selectedMotionPointTime
        canonicalizeZooms()
        isPlaying = false
        seek(snapshot.playhead)
    }

    func loadProject(folder: URL) async throws {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                if previewPending { schedulePreview() }
            }
        }
        previewGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
        previewPending = false
        previewScheduleID = UUID()
        previewReplacementGeneration = nil
        isFramingPreviewReady = false
        isPlaying = false
        do {
            let loaded = try ProjectStore.load(folder: folder)
            let asset = AVURLAsset(url: loaded.sourceURL)
            let actualDuration = try await asset.load(.duration).seconds
            try checkLoadGeneration(generation)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            try checkLoadGeneration(generation)
            guard let track = tracks.first, actualDuration.isFinite, actualDuration > 0,
                  loaded.clips.allSatisfy({ $0.sourceStart + $0.duration <= actualDuration + 0.05 }) else {
                throw RecorderError.message("原片不能读取，或工程片段超出了原片时长。")
            }
            let size = try await track.load(.naturalSize)
            try checkLoadGeneration(generation)
            var cameraEffectsEnabled = !showsFramingOverlay
            var timeline = try await ProjectExporter.buildTimeline(project: loaded,
                cameraEffectsEnabled: cameraEffectsEnabled)
            try checkLoadGeneration(generation)
            if let barrier = beforeProjectLoadCommit { await barrier(loaded.folderURL) }
            try checkLoadGeneration(generation)
            while cameraEffectsEnabled != !showsFramingOverlay {
                cameraEffectsEnabled = !showsFramingOverlay
                timeline = try await ProjectExporter.buildTimeline(project: loaded,
                    cameraEffectsEnabled: cameraEffectsEnabled)
                try checkLoadGeneration(generation)
            }

            let selection = loaded.clips.first(where: { $0.id == loaded.selectedClipID }) ?? loaded.clips.first
            let zoomID = selection?.zooms.contains(where: { $0.id == loaded.selectedZoomID }) == true
                ? loaded.selectedZoomID : selection?.zooms.first?.id
            let duration = loaded.clips.reduce(0) { $0 + $1.duration }
            let time = min(duration, max(0, loaded.playhead))
            let item = AVPlayerItem(asset: timeline.asset)
            item.videoComposition = timeline.videoComposition
            item.audioTimePitchAlgorithm = .spectral

            // Commit all document fields and its prepared player item together,
            // after the final async boundary has accepted this generation.
            previewGeneration = UUID()
            project = loaded
            sourceURL = loaded.sourceURL; projectURL = loaded.folderURL
            fps = loaded.fps; quality = loaded.quality; sourcePixelSize = size
            clips = loaded.clips; selectedClipID = selection?.id; selectedZoomID = zoomID
            enterClipSelection()
            playhead = time; history.removeAll(); editingSnapshot = nil
            let replacement = UUID()
            previewReplacementGeneration = replacement
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: time, preferredTimescale: 60_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            try checkLoadGeneration(generation)
            guard player.currentItem === item else { throw CancellationError() }
            if previewReplacementGeneration == replacement {
                previewReplacementGeneration = nil
                if isPlaying { player.play() }
            }
            previewCameraEffectsEnabled = cameraEffectsEnabled
            isFramingPreviewReady = showsFramingOverlay && !cameraEffectsEnabled
            // A toggle during the final seek belongs to this newly loaded
            // document, rather than to the preview of the previous project.
            if cameraEffectsEnabled != !showsFramingOverlay { schedulePreview() }
            message = "工程已打开 · 修改自动保存"
        } catch {
            if generation != loadGeneration || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func checkLoadGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        if generation != loadGeneration { throw CancellationError() }
    }

    func autosave() throws {
        canonicalizeZooms()
        guard var project else { return }
        // A saved document may have been moved after returning to the recorder.
        // Starting another recording must not rewrite that unchanged document.
        guard project.clips != clips || project.selectedClipID != selectedClipID ||
              project.selectedZoomID != selectedZoomID || project.playhead != playhead ||
              project.fps != fps || project.quality != quality else { return }
        project.clips = clips; project.selectedClipID = selectedClipID
        project.selectedZoomID = selectedZoomID; project.playhead = playhead
        project.fps = fps; project.quality = quality
        try ProjectStore.validate(project)
        try ProjectStore.save(project)
        self.project = project
    }

    func export(to destination: URL) async throws {
        guard !isExporting, var document = project else {
            throw RecorderError.message(isExporting ? "正在导出，请稍候。" : "请先打开录屏工程。")
        }
        endEditing()
        try autosave()
        document.clips = clips; document.fps = fps; document.quality = quality
        isExporting = true; exportProgress = 0; isPlaying = false
        let exporter = ProjectExporter()
        self.exporter = exporter
        defer { isExporting = false; self.exporter = nil }
        do {
            try await exporter.export(project: document, destination: destination) { [weak self] value in
                self?.exportProgress = value
            }
            message = "视频已导出"
        } catch {
            message = error is CancellationError ? "已取消导出，工程和原片均保留" : "导出失败，工程和原片均保留"
            throw error
        }
    }

    func cancelExport() { exporter?.cancel() }
    func togglePlayback() {
        if !isPlaying, playhead >= totalDuration - 0.02 { seek(0) }
        isPlaying.toggle()
    }
    func skip(by seconds: Double) { seek(playhead + seconds) }

    func selectClip(_ id: UUID) { select(id) }
    func setFocus(x: Double, y: Double) {
        guard let clip = selectedClip, var zoom = selectedZoom else { return }
        zoom.focusX = x; zoom.focusY = y; zoom.manualFocus = true
        zoom.manualCenterPath = nil
        zoom.centerOffsets = nil
        zoom.centerPanSpans = nil
        setZoom(zoom, for: clip.id)
    }

    private func onlyZoomsChanged(from before: [DemoClip]) -> Bool {
        guard before.count == clips.count else { return false }
        return zip(before, clips).allSatisfy { old, current in
            var comparison = old
            comparison.zooms = current.zooms
            return comparison == current
        }
    }

    private func commitEdits(rebuildPreview: Bool = true) {
        guard !isLoading else { return }
        do { try autosave() }
        catch { message = "自动保存失败：\(error.localizedDescription)"; onError?(error) }
        // Camera edits only change the native overlay while showing the raw
        // timeline. Replacing the player item on every move blanks the image.
        if rebuildPreview { schedulePreview() }
    }

    private func schedulePreview() {
        previewPending = true
        previewGeneration = UUID()
        guard !isLoading else { return }
        guard previewTask == nil else { return }
        let owner = loadGeneration
        let scheduleID = UUID()
        previewScheduleID = scheduleID
        previewTask = Task { [weak self] in
            defer {
                if self?.previewScheduleID == scheduleID { self?.previewTask = nil }
            }
            while let self, self.loadGeneration == owner, !Task.isCancelled {
                self.previewPending = false
                do {
                    try await self.rebuildPreview()
                    try await Task.sleep(nanoseconds: 80_000_000)
                } catch is CancellationError {
                    if Task.isCancelled || self.loadGeneration != owner { return }
                    if !self.previewPending { return }
                    continue
                }
                catch {
                    guard self.loadGeneration == owner else { return }
                    self.message = "预览更新失败：\(error.localizedDescription)"
                    self.onError?(error)
                    return
                }
                if !self.previewPending { break }
            }
        }
    }

    func rebuildPreview() async throws {
        guard var project else { return }
        let owner = loadGeneration
        let generation = UUID(); previewGeneration = generation
        let cameraEffectsEnabled = !showsFramingOverlay
        project.clips = clips; project.fps = fps
        let result = try await ProjectExporter.buildTimeline(project: project,
            cameraEffectsEnabled: cameraEffectsEnabled)
        if let barrier = beforePreviewCommit { await barrier(cameraEffectsEnabled) }
        try Task.checkCancellation()
        guard generation == previewGeneration, owner == loadGeneration,
              cameraEffectsEnabled == !showsFramingOverlay else { throw CancellationError() }
        let item = AVPlayerItem(asset: result.asset)
        item.videoComposition = result.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        let target = CMTime(seconds: min(totalDuration, max(0, playhead)), preferredTimescale: 60_000)
        previewReplacementGeneration = generation
        defer {
            if previewReplacementGeneration == generation {
                previewReplacementGeneration = nil
                if isPlaying { player.play() }
            }
        }
        player.replaceCurrentItem(with: item)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard generation == previewGeneration, owner == loadGeneration,
              player.currentItem === item else { throw CancellationError() }
        previewCameraEffectsEnabled = cameraEffectsEnabled
        isFramingPreviewReady = showsFramingOverlay && !cameraEffectsEnabled
    }

}

