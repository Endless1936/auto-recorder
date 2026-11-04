import AVFoundation
import CoreMedia
import CoreVideo

@MainActor
enum AutoZoomSelfTest {
    static let trace = CursorTrace(samples: [
        CursorSample(time: 0, x: 0.5, y: 0.5, inside: true, clicked: false),
        CursorSample(time: 0.5, x: 0.25, y: 0.25, inside: true, clicked: true),
        CursorSample(time: 1.5, x: 0.95, y: 0.9, inside: true, clicked: false),
        CursorSample(time: 2, x: 0.98, y: 0.95, inside: true, clicked: true)
    ])

    static func checkPlan() throws {
        let normalized = CursorTrace.normalized(CGPoint(x: -1720, y: -150),
            in: CGRect(x: -1920, y: -300, width: 800, height: 600))
        try check(abs(normalized.x - 0.25) < 0.0001 && abs(normalized.y - 0.25) < 0.0001,
                  "有偏移的屏幕/选区坐标错误")
        let aligned = CursorTrace.aligned([
            CursorSample(time: 999.9, x: 0, y: 0, inside: true, clicked: true),
            CursorSample(time: 1000.75, x: 0.2, y: 0.3, inside: true, clicked: true)
        ], origin: 1000.5)
        try check(aligned.samples.count == 1 && abs(aligned.samples[0].time - 0.25) < 0.000001,
                  "鼠标时间未对齐原片 startSession")
        let plan = AutoZoomPlan(trace: trace, duration: 7, fps: 30)
        try check(plan.pose(at: 0.2).scale == 1 && plan.pose(at: 1.2).scale > 1.58 && plan.pose(at: 6.8).scale < 1.001,
                  "点击放大或空闲恢复错误")
        for pose in plan.poses {
            let viewport = pose.viewport
            try check(viewport.minX >= -0.00001 && viewport.minY >= -0.00001 &&
                      viewport.maxX <= 1.00001 && viewport.maxY <= 1.00001, "镜头超出图像产生黑边")
        }
        let outside = AutoZoomPlan(trace: CursorTrace(samples: trace.samples + [
            CursorSample(time: 2.2, x: 2, y: 0.5, inside: false, clicked: true)
        ]), duration: 7, fps: 60)
        try check(outside.pose(at: 3.2).scale < 1.002, "离开区域后未恢复全景")
        let idle = AutoZoomPlan(trace: CursorTrace(samples: [
            CursorSample(time: 1, x: 0.8, y: 0.8, inside: true, clicked: false)
        ]), duration: 4, fps: 30)
        try check(idle.poses.allSatisfy { $0.scale == 1 }, "无点击时意外放大")
        // Every step is below the activity threshold, but the pointer keeps moving.
        let slowSamples = (0...300).map { (i: Int) -> CursorSample in
            CursorSample(time: Double(i) / 60, x: 0.2 + Double(i) * 0.001,
                         y: 0.5, inside: true, clicked: i == 15)
        }
        let jitterSamples = (0...300).map { (i: Int) -> CursorSample in
            let offset: Double = i % 2 == 0 ? 0.0004 : -0.0004
            return CursorSample(time: Double(i) / 60, x: 0.5 + offset,
                                y: 0.5, inside: true, clicked: i == 15)
        }
        for fps in [30, 60] {
            let pause = AutoZoomPlan(trace: CursorTrace(samples: [
                CursorSample(time: 0.5, x: 0.3, y: 0.5, inside: true, clicked: true)
            ]), duration: 3.5, fps: fps)
            try check(pause.pose(at: 2).scale > 1.59 && pause.pose(at: 2.25).scale < 1.15 &&
                      pause.pose(at: 3).scale < 1.001, "应在停顿 1.5 秒后开始平滑恢复全景")
            guard let onset = pause.returns.first else { throw RecorderError.message("静止后没有回全景过渡") }
            try check(abs(onset.time - 2) <= 1 / Double(fps) + 0.000001,
                      "回全景起点不是最后一次有效活动后 1.5 秒")
            let slow = AutoZoomPlan(trace: CursorTrace(samples: slowSamples), duration: 8.5, fps: fps)
            try check(slow.pose(at: 4).scale > 1.59, "慢速持续移动被误判为空闲")
            try check(slow.pose(at: 8.2).scale < 1.001, "慢速移动停止后未恢复全景")
            let jitter = AutoZoomPlan(trace: CursorTrace(samples: jitterSamples), duration: 5, fps: fps)
            try check(jitter.pose(at: 3).scale < 1.001, "微小往返抖动意外延长放大")
            let reentry = AutoZoomPlan(trace: CursorTrace(samples: [
                CursorSample(time: 0, x: 0.3, y: 0.5, inside: true, clicked: true),
                CursorSample(time: 1, x: 1.1, y: 0.5, inside: false, clicked: false),
                CursorSample(time: 1.5, x: 0.5, y: 0.5, inside: true, clicked: false),
                CursorSample(time: 2, x: 0.7, y: 0.5, inside: true, clicked: false),
                CursorSample(time: 3.5, x: 0.7, y: 0.5, inside: true, clicked: true)
            ]), duration: 5, fps: fps)
            try check(reentry.pose(at: 3).scale < 1.001 && reentry.pose(at: 4.5).scale > 1.59,
                      "离区重返需点击才能再次放大")
            try checkSafeZone(fps: fps)
        }
        try checkRecordedMotion()
        try checkDirectReturn()
        let saved = try JSONEncoder().encode(trace)
        try check(try JSONDecoder().decode(CursorTrace.self, from: saved).samples.count == trace.samples.count,
                  "轨迹保存错误")
        print("PASS zoom plan: offset coordinates, host time alignment, clicks, exact 1.5-second idle delay, immediate outside restore, bounded crop, no-click, slow movement, jitter, reentry, 30/60fps, JSON")
        print("PASS 50% safe zone: interior and exact-edge hold, smooth threshold crossing, both axes/directions, in-zone clicks, bounded crop and unchanged idle timing at 30/60fps")
    }

    private static func checkRecordedMotion() throws {
        struct Scenario {
            let name: String
            let trace: CursorTrace
            let duration: Double
        }
        // Independent frozen scalar baseline from the working 3d33f33 version.
        // Do not call the current ZoomSegment.scale or a new planner here: both
        // sides must not silently agree if production zoom interpolation changes.
        struct BaselineEnvelope {
            var start: Double
            var rise: Double
            var fall: Double
            var end: Double
            let peak: Double

            func scale(at time: Double) -> Double {
                guard time > start, time < end else { return 1 }
                func smooth(_ value: Double) -> Double { value * value * (3 - 2 * value) }
                if time < rise { return 1 + (peak - 1) * smooth((time - start) / (rise - start)) }
                if time <= fall { return peak }
                return peak + (1 - peak) * smooth((time - fall) / (end - fall))
            }
        }
        func baselineEnvelopes(trace: CursorTrace, duration: Double, fps: Int) -> [BaselineEnvelope] {
            guard trace.hasClicks else { return [] }
            let plan = AutoZoomPlan(trace: trace, duration: duration, fps: min(30, fps))
            let step = 1 / Double(plan.fps)
            let count = min(plan.poses.count, Int(floor(duration * Double(plan.fps))) + 1)
            var groups: [(Int, Int)] = [], beginning: Int?
            for index in 0..<count {
                if plan.poses[index].scale > 1.005 {
                    if beginning == nil { beginning = index }
                } else if let first = beginning { groups.append((first, index - 1)); beginning = nil }
            }
            if let first = beginning { groups.append((first, count - 1)) }
            return groups.compactMap { first, last in
                let peak = plan.poses[first...last].map(\.scale).max() ?? 1
                guard peak > 1.02 else { return nil }
                let high = (first...last).filter { plan.poses[$0].scale >= 1 + (peak - 1) * 0.97 }
                let rise = high.first ?? first, fall = high.last ?? last
                let extends = last == count - 1 && plan.poses[last].scale > 1.02
                var value = BaselineEnvelope(start: max(0, Double(first - 1) * step), rise: Double(rise) * step,
                    fall: extends ? max(Double(fall) * step, duration) : Double(fall) * step,
                    end: extends ? duration + 0.5 : min(duration, Double(last + 1) * step), peak: peak)
                let ramp = 0.05, hold = 0.001, tolerance = 0.000000001
                if extends, let transition = plan.returns.last(where: { $0.time >= value.start && $0.time <= Double(last) * step && $0.end >= Double(last) * step }) {
                    value.fall = min(value.fall, max(value.rise + hold, transition.time))
                }
                if value.end - value.start < ramp + hold + ramp - tolerance { value.end = value.start + ramp + hold + ramp }
                if value.rise - value.start < ramp - tolerance { value.rise = value.start + ramp }
                if value.end - value.rise < ramp + hold - tolerance { value.rise = value.end - ramp - hold }
                if value.fall - value.rise < hold - tolerance { value.fall = value.rise + hold }
                if value.end - value.fall < ramp - tolerance { value.fall = value.end - ramp }
                return value
            }
        }
        func sampled(_ position: (Double) -> (Double, Double)) -> CursorTrace {
            CursorTrace(samples: (0...240).map { index in
                let time = Double(index) / 60, point = position(time)
                return CursorSample(time: time, x: point.0, y: point.1,
                    inside: true, clicked: index == 15)
            })
        }
        let circle = sampled { time in
            let angle = time * .pi * 1.5
            return (0.5 + 0.12 * cos(angle), 0.5 + 0.12 * sin(angle))
        }
        let irregular = sampled { time in
            (0.5 + 0.1 * sin(time * 4.1) + 0.025 * sin(time * 17),
             0.5 + 0.1 * cos(time * 3.3) + 0.02 * sin(time * 13))
        }
        let jitter = sampled { time in (0.5 + 0.0004 * sin(time * 107), 0.5 + 0.0002 * cos(time * 83)) }
        let crossing = sampled { time in (0.1 + time * 0.2, 0.43) }
        let zigzag = sampled { time in
            let phase = time.truncatingRemainder(dividingBy: 2)
            return (0.1 + 0.8 * (1 - abs(phase - 1)), 0.5)
        }
        let wideCircle = sampled { time in
            let angle = time * .pi
            return (0.5 + 0.36 * cos(angle), 0.5 + 0.36 * sin(angle))
        }
        let jumps = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.03, y: 0.03, inside: true, clicked: true),
            CursorSample(time: 0.37, x: 0.97, y: 0.97, inside: true, clicked: false),
            CursorSample(time: 0.73, x: 0.03, y: 0.97, inside: true, clicked: false),
            CursorSample(time: 1.07, x: 0.97, y: 0.03, inside: true, clicked: false),
            CursorSample(time: 1.43, x: 0.03, y: 0.03, inside: true, clicked: false),
            CursorSample(time: 1.81, x: 0.97, y: 0.97, inside: true, clicked: true),
            CursorSample(time: 2.19, x: 0.02, y: 0.98, inside: true, clicked: false),
            CursorSample(time: 2.51, x: 0.98, y: 0.02, inside: true, clicked: false)
        ])
        let subframe = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.5, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 0.251, x: 0.02, y: 0.02, inside: true, clicked: true),
            CursorSample(time: 0.263, x: 0.98, y: 0.98, inside: true, clicked: false),
            CursorSample(time: 0.271, x: 0.02, y: 0.98, inside: true, clicked: false),
            CursorSample(time: 0.303, x: 0.98, y: 0.02, inside: true, clicked: false)
        ])
        let exiting = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.9, y: 0.5, inside: true, clicked: true),
            CursorSample(time: 0.4, x: 0.9, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 0.7, x: 0.88, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 1.05, x: -0.25, y: 0.5, inside: false, clicked: false),
            CursorSample(time: 1.3, x: 0.05, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 1.6, x: 0.15, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 2.2, x: 0.8, y: 0.5, inside: true, clicked: true)
        ])
        let outsideCrossing = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.9, y: 0.6, inside: true, clicked: true),
            CursorSample(time: 0.55, x: 0.87, y: 0.6, inside: true, clicked: false),
            CursorSample(time: 0.8, x: -0.2, y: 0.6, inside: false, clicked: false),
            CursorSample(time: 0.96, x: 1.2, y: 0.6, inside: false, clicked: false),
            CursorSample(time: 1.13, x: 0.98, y: 0.6, inside: true, clicked: false),
            CursorSample(time: 1.4, x: 0.85, y: 0.6, inside: true, clicked: false)
        ])
        let longCrossing = CursorTrace(samples: (0...7_200).map { index in
            let time = Double(index) / 60
            return CursorSample(time: time, x: 0.5 + 0.42 * sin(time * .pi / 15),
                y: 0.5 + 0.2 * cos(time * .pi / 21), inside: true, clicked: index == 15)
        })
        let wideActivity = CursorTrace(samples: (0...720).map { index in
            let time = Double(index) / 60
            let phase = time.truncatingRemainder(dividingBy: 6)
            let x = phase <= 3 ? phase / 3 : (6 - phase) / 3
            let clicks: Set<Int> = [48, 123, 317, 369, 399, 502, 510, 608, 651, 706]
            return CursorSample(time: time, x: x, y: 0.3 + 0.18 * sin(time * 0.8),
                inside: true, clicked: clicks.contains(index))
        })
        var scenarios = [
            Scenario(name: "local-circle", trace: circle, duration: 6),
            Scenario(name: "local-irregular", trace: irregular, duration: 6),
            Scenario(name: "stationary-jitter", trace: jitter, duration: 6),
            Scenario(name: "cross-region", trace: crossing, duration: 6),
            Scenario(name: "moderate-zigzag", trace: zigzag, duration: 6),
            Scenario(name: "wide-circle", trace: wideCircle, duration: 6),
            Scenario(name: "rapid-corners", trace: jumps, duration: 5),
            Scenario(name: "subframe-jumps", trace: subframe, duration: 3),
            Scenario(name: "exit-across-screen", trace: exiting, duration: 4.5),
            Scenario(name: "outside-cross-reentry", trace: outsideCrossing, duration: 3.5),
            Scenario(name: "wide-activity-with-clicks", trace: wideActivity, duration: 12.2),
            Scenario(name: "long-cross-region", trace: longCrossing, duration: 120)
        ]
        for (index, corner) in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)].enumerated() {
            scenarios.append(Scenario(name: "stationary-corner-\(index)", trace: CursorTrace(samples: [
                CursorSample(time: 0, x: corner.0, y: corner.1, inside: true, clicked: false),
                CursorSample(time: 0.2, x: corner.0, y: corner.1, inside: true, clicked: true)
            ]), duration: 3.5))
        }
        if let argument = CommandLine.arguments.firstIndex(of: "--trace-project-regression") {
            guard CommandLine.arguments.indices.contains(argument + 1) else {
                throw RecorderError.message("真实轨迹回归缺少临时工程参数文件")
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
            let project = try JSONDecoder().decode(RecordingProject.self, from: Data(contentsOf: url))
            scenarios.append(Scenario(name: "private-recording-replay", trace: project.trace,
                duration: project.sourceDuration))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for fps in [30, 60] {
            for scenario in scenarios {
                let label = "\(scenario.name) \(fps)fps"
                let rawData = try encoder.encode(scenario.trace)
                let reference = AutoZoomPlan(trace: scenario.trace, duration: scenario.duration, fps: min(30, fps))
                let baseline = baselineEnvelopes(trace: scenario.trace, duration: scenario.duration, fps: fps)
                let began = Date()
                let zooms = ProjectStore.automaticZooms(trace: scenario.trace,
                    duration: scenario.duration, fps: Int32(fps))
                let seconds = Date().timeIntervalSince(began)
                try check(!baseline.isEmpty && zooms.count == baseline.count,
                          "\(label)：原版放大段被删除")
                var largestScaleError = 0.0, largestPositionError = 0.0
                for (zoom, envelope) in zip(zooms, baseline) {
                    try check(zoom.simpleMotion != true && zoom.positionMotion != true &&
                              !zoom.manualFocus && zoom.manualCenterPath == nil &&
                              zoom.cameraKeyframes == nil && zoom.centerOffsets == nil && zoom.centerPanSpans == nil,
                              "\(label)：新录制仍经过轨迹拟合或被转换为手动路线")
                    try check(abs(zoom.start - envelope.start) < 1e-9 &&
                              abs(zoom.riseEnd - envelope.rise) < 1e-9 &&
                              abs(zoom.fallStart - envelope.fall) < 1e-9 &&
                              abs(zoom.end - envelope.end) < 1e-9 && abs(zoom.peak - envelope.peak) < 1e-9,
                              "\(label)：原版放大节奏或幅度改变")
                    guard let first = zoom.centerPath.first, let last = zoom.centerPath.last else {
                        throw RecorderError.message("\(label)：没有保存逐帧镜头路线")
                    }
                    let expectedCount = Int(round((last.time - first.time) * Double(reference.fps))) + 1
                    try check(zoom.centerPath.count == expectedCount,
                              "\(label)：逐帧运镜路线被减点")
                    for point in zoom.centerPath {
                        let expected = reference.pose(at: point.time)
                        try check(abs(point.x - expected.x) < 1e-9 && abs(point.y - expected.y) < 1e-9,
                                  "\(label)：已保存的原始运镜点被替换")
                    }
                    var edited = zoom
                    _ = edited.addCameraKeyframe(at: zoom.start + (zoom.end - zoom.start) * 0.37)
                    edited = edited.normalized()
                    let reopened = try JSONDecoder().decode(ZoomSegment.self, from: encoder.encode(edited))
                    try check(reopened == edited && reopened.centerPath == zoom.centerPath,
                              "\(label)：加点或保存重开改变了逐帧路线")
                    let count = max(1, Int(ceil((zoom.end - zoom.start) * 240)))
                    for index in 0...count {
                        let time = zoom.start + (zoom.end - zoom.start) * Double(index) / Double(count)
                        let scale = envelope.scale(at: time), margin = 0.5 / scale
                        let sample = reference.pose(at: min(last.time, max(first.time, time)))
                        var x = min(1 - margin, max(margin, sample.x))
                        var y = min(1 - margin, max(margin, sample.y))
                        if let origin = zoom.returnOrigin, time >= origin.time {
                            let width = 1 / envelope.scale(at: envelope.fall)
                            let progress = time > envelope.fall ? min(1, max(0, (1 / scale - width) / (1 - width))) : 0
                            x = origin.x * (1 - progress) + 0.5 * progress
                            y = origin.y * (1 - progress) + 0.5 * progress
                        }
                        for value in [zoom, reopened] {
                            let actual = value.pose(at: time)
                            largestScaleError = max(largestScaleError, abs(actual.scale - scale))
                            largestPositionError = max(largestPositionError, hypot(actual.x - x, actual.y - y))
                            try check(abs(actual.scale - scale) < 1e-8 &&
                                      abs(actual.x - x) < 1e-8 && abs(actual.y - y) < 1e-8,
                                      "\(label)：播放或无修改加点没有忠实保留原版的逐帧运镜")
                        }
                    }
                }
                try check(try encoder.encode(scenario.trace) == rawData,
                          "\(label)：鼠标原始记录被修改")
                print(String(format: "METRIC faithful %@: zooms=%d, peak=%.6f, storedPositions=%d, scaleError=%.12f, positionError=%.12f, planningSeconds=%.4f",
                    label, zooms.count, zooms.map(\.peak).max() ?? 1,
                    zooms.reduce(0) { $0 + $1.centerPath.count }, largestScaleError, largestPositionError, seconds))
            }
        }
        print("PASS faithful motion: complete original frame-by-frame centers, no trajectory fitting, historical zoom phases/scales, nondestructive anchor insertion, JSON identity, circles/irregular/wide/edge paths and 30/60fps")
    }

    private static func checkDirectReturn() throws {
        for fps in [30, 60] {
            for location in [(0.05, 0.05), (0.95, 0.05), (0.05, 0.95), (0.95, 0.95)] {
                let trace = CursorTrace(samples: [CursorSample(time: 0.5, x: location.0, y: location.1, inside: true, clicked: true)])
                let plan = AutoZoomPlan(trace: trace, duration: 4, fps: fps)
                guard let transition = plan.returns.first else { throw RecorderError.message("停顿后缺少回全景起点") }
                let initial = transition.pose.viewport
                for index in plan.poses.indices where Double(index) / Double(fps) >= transition.time {
                    let pose = plan.poses[index], rect = pose.viewport
                    let amount = (rect.width - initial.width) / (1 - initial.width)
                    try check(abs(rect.minX - initial.minX * (1 - amount)) < 1e-8 &&
                              abs(rect.minY - initial.minY * (1 - amount)) < 1e-8 &&
                              abs(rect.maxX - (initial.maxX + (1 - initial.maxX) * amount)) < 1e-8 &&
                              abs(rect.maxY - (initial.maxY + (1 - initial.maxY) * amount)) < 1e-8,
                              "基础运镜先平移居中，未从当前取景框直接展开")
                }
                let zoom = ProjectStore.automaticZooms(trace: trace, duration: 4, fps: Int32(fps))[0]
                let stopped = ProjectStore.automaticZooms(trace: trace, duration: 2.15, fps: Int32(fps))[0]
                try check(stopped.fallStart < 2.05 && stopped.scale(at: 2.1) < stopped.peak - 0.01,
                          "片尾截在回全景过程中时，缩放被错误推迟到录制结束后")
                let start = zoom.pose(at: transition.time)
                let initialLeft = start.x - 0.5 / start.scale, initialTop = start.y - 0.5 / start.scale
                var inserted = zoom
                _ = inserted.addCameraKeyframe(at: zoom.fallStart + (zoom.end - zoom.fallStart) * 0.4)
                inserted = inserted.normalized()
                let reopened = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(inserted))
                let cut = reopened.shifted(by: -1.2).normalized()
                for i in 0...720 {
                    let time = transition.time + (zoom.end - transition.time) * Double(i) / 720
                    let pose = zoom.pose(at: time), amount = (1 / pose.scale - 1 / start.scale) / (1 - 1 / start.scale)
                    try check(abs(pose.x - 0.5 / pose.scale - initialLeft * (1 - amount)) < 1e-8 &&
                              abs(pose.y - 0.5 / pose.scale - initialTop * (1 - amount)) < 1e-8,
                              "编辑器的回全景位置和缩放不同步")
                    for (value, offset) in [(reopened, 0.0), (cut, -1.2)] {
                        let actual = value.pose(at: time + offset)
                        try check(abs(actual.x - pose.x) < 1e-8 && abs(actual.y - pose.y) < 1e-8 && abs(actual.scale - pose.scale) < 1e-8,
                                  "无修改加点、保存或剪切破坏了直接回全景")
                    }
                }
            }
        }
        print("PASS direct full-view return: four off-center crops expand directly, synchronized position/size at 30/60fps, editor parity, exact insertion, JSON and shifted cuts")
    }

    private static func checkSafeZone(fps: Int) throws {
        // Keep the release follower and use the approved centered 50% safe region.
        let halfSafeZone = 0.15625
        let insideOffset = 0.125
        let outsideOffset = 0.1875
        let panDistance = outsideOffset - halfSafeZone
        let alpha = 1 - exp(-1 / Double(fps) / 0.14)
        for horizontal in [true, false] {
            for direction in [-1.0, 1.0] {
                let label = "\(fps)fps \(horizontal ? "X" : "Y") \(direction)"
                func sample(_ time: Double, _ coordinate: Double, clicked: Bool = false) -> CursorSample {
                    CursorSample(time: time, x: horizontal ? coordinate : 0.5,
                        y: horizontal ? 0.5 : coordinate, inside: true, clicked: clicked)
                }
                let firstTarget = 0.5 + direction * panDistance
                let samples = [
                    sample(0, 0.5, clicked: true),
                    sample(0.5, 0.5 + direction * insideOffset),
                    sample(0.75, 0.5 + direction * halfSafeZone),
                    sample(1, 0.5 + direction * outsideOffset),
                    sample(1.5, firstTarget - direction * insideOffset),
                    sample(1.75, firstTarget - direction * halfSafeZone),
                    sample(2, firstTarget - direction * outsideOffset)
                ]
                let plan = AutoZoomPlan(trace: CursorTrace(samples: samples), duration: 4.5, fps: fps)
                let held = plan.pose(at: 0.95)
                try check(abs(held.x - 0.5) < 0.000000001 && abs(held.y - 0.5) < 0.000000001,
                          "\(label)：50%安全区内或边界意外平移")
                var expected = 0.5
                for index in plan.poses.indices {
                    let target = index >= fps && index < 2 * fps ? firstTarget : 0.5
                    expected += (target - expected) * alpha
                    let pose = plan.poses[index]
                    let actual = horizontal ? pose.x : pose.y
                    let otherAxis = horizontal ? pose.y : pose.x
                    try check(index > fps * 3 || (abs(actual - expected) < 0.000000001 && abs(otherAxis - 0.5) < 0.000000001),
                              "\(label)：越过50%安全区后的平移、反向安全区或原有平滑速度不正确")
                }
                let firstPan = plan.poses[fps]
                let firstCoordinate = horizontal ? firstPan.x : firstPan.y
                let firstDistance = (firstCoordinate - 0.5) * direction
                try check(firstDistance > 0 && firstDistance < panDistance,
                          "\(label)：越界后应平滑移动，不能立即跳到新中心")
                try check(plan.pose(at: 3.4).scale > 1.59 && plan.pose(at: 3.85).scale < 1.08 &&
                          plan.pose(at: 4.45).scale < 1.001,
                          "\(label)：最后一次活动后等待1.5秒，再平滑回全景")
                try checkBounded(plan, label: label)

                let clicked = AutoZoomPlan(trace: CursorTrace(samples: [
                    sample(0, 0.5, clicked: true),
                    sample(0.5, 0.5 + direction * 0.125, clicked: true)
                ]), duration: 3, fps: fps)
                let clickedPose = clicked.poses[fps / 2]
                let clickedCoordinate = horizontal ? clickedPose.x : clickedPose.y
                let clickExpected = 0.5 + direction * 0.125 * alpha
                try check(abs(clickedCoordinate - clickExpected) < 0.000000001,
                          "\(label)：安全区内点击也应立即重新聚焦，并保留平滑过渡")
                let focused = clicked.pose(at: 1.2)
                let focusedCoordinate = horizontal ? focused.x : focused.y
                try check(abs(focusedCoordinate - (0.5 + direction * 0.125)) < 0.001,
                          "\(label)：安全区内点击被错误当作无需跟随")
                try checkBounded(clicked, label: label + " click")
            }
        }
        let corners = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.5, y: 0.5, inside: true, clicked: true),
            CursorSample(time: 0.5, x: 0.999, y: 0.999, inside: true, clicked: false),
            CursorSample(time: 1, x: 0.001, y: 0.001, inside: true, clicked: false),
            CursorSample(time: 1.5, x: 0.999, y: 0.999, inside: true, clicked: true),
            CursorSample(time: 2, x: 1.2, y: -0.2, inside: false, clicked: false)
        ])
        let boundary = AutoZoomPlan(trace: corners, duration: 4, fps: fps)
        try checkBounded(boundary, label: "\(fps)fps corners")
        try check(boundary.pose(at: 1.9).x > 0.65 && boundary.pose(at: 1.9).y > 0.65 &&
                  boundary.pose(at: 3.5).scale < 1.001,
                  "\(fps)fps：边缘点击应受录制边界限制，离区后仍需恢复全景")
    }

    private static func checkBounded(_ plan: AutoZoomPlan, label: String) throws {
        for pose in plan.poses {
            let viewport = pose.viewport
            let insideX = viewport.minX >= -0.000000001 && viewport.maxX <= 1.000000001
            let insideY = viewport.minY >= -0.000000001 && viewport.maxY <= 1.000000001
            try check(insideX && insideY && pose.scale >= 1 && pose.scale <= 1.600000001,
                      "\(label)：50%安全区跟随越出录制范围或改变了放大倍率")
        }
    }

    static func run(directory: URL) async throws {
        try checkPlan()
        let size = CGSize(width: 1920, height: 1080)
        let low = AutoZoomExporter.targetBitrate(size: size, fps: 60, sourceRate: 20_000)
        let high = AutoZoomExporter.targetBitrate(size: size, fps: 60, sourceRate: 200_000_000)
        try check(low >= 4_900_000 && high <= 10_000_000 && low < high,
                  "效果码率应兼顾静态原片清晰度下限与高码率上限")
        try check(AutoZoomExporter.targetBitrate(size: size, fps: 60, sourceRate: .nan) == low,
                  "缺失原片码率时未使用合理下限")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for quality in RecordingQuality.allCases {
            let label = quality == .hevc ? "hevc" : "prores"
            let raw = directory.appendingPathComponent(label + "-original.mov")
            try await fixture(to: raw, quality: quality)
            let originalData = try Data(contentsOf: raw)
            let output = directory.appendingPathComponent(label + "-zoom.mov")
            let exporter = AutoZoomExporter()
            try await exporter.export(source: raw, destination: output, trace: trace,
                                      fps: 30, quality: quality) { _ in }
            try await validate(original: raw, output: output)
            try check(try Data(contentsOf: raw) == originalData, "导出修改了原片")
            let noClick = directory.appendingPathComponent(label + "-no-click.mov")
            try await exporter.export(source: raw, destination: noClick, trace: CursorTrace(samples: []),
                                      fps: 30, quality: quality) { _ in }
            try check(try Data(contentsOf: noClick) == originalData, "无点击视频被重复编码")
            print("PASS \(label) zoom: static source -> 30fps animated export, audio/duration, native size, original intact, no-click copy")
        }
        let source = directory.appendingPathComponent("hevc-original.mov")
        let silent = directory.appendingPathComponent("silent-original.mov")
        let silentEffect = directory.appendingPathComponent("silent-zoom.mov")
        try await fixture(to: silent, quality: .hevc, withAudio: false)
        try await AutoZoomExporter().export(source: silent, destination: silentEffect, trace: trace,
                                          fps: 30, quality: .hevc) { _ in }
        let silentTracks = try await AVURLAsset(url: silentEffect).loadTracks(withMediaType: .audio)
        try check(silentTracks.isEmpty, "关闭声音后效果视频出现音轨")
        print("PASS zoom without audio: video-only capture remains video-only")
        let delayedAudio = directory.appendingPathComponent("delayed-audio-original.mov")
        let delayedEffect = directory.appendingPathComponent("delayed-audio-zoom.mov")
        try await fixture(to: delayedAudio, quality: .hevc, withAudioGap: true)
        try await AutoZoomExporter().export(source: delayedAudio, destination: delayedEffect,
            trace: trace, fps: 30, quality: .hevc) { _ in }
        let delayedSource = try await encodedAudio(AVURLAsset(url: delayedAudio))
        let delayedOutput = try await encodedAudio(AVURLAsset(url: delayedEffect))
        try check(delayedSource.data == delayedOutput.data &&
                  abs(delayedSource.firstPTS - delayedOutput.firstPTS) < 0.001 &&
                  abs(delayedSource.endPTS - delayedOutput.endPTS) < 0.001,
                  "延迟音频与中间静音的原始音频包或时间戳发生变化")
        print("PASS delayed audio and silence gap: packet bytes and first/end timestamps preserved")
        let duringExport = AutoZoomExporter()
        var reachedEncoding = false
        var cancelledDuringEncoding = false
        do {
            try await duringExport.export(source: source,
                destination: directory.appendingPathComponent("cancelled-during-encoding.mov"),
                trace: trace, fps: 30, quality: .hevc) { value in
                    if value >= 0.1 { reachedEncoding = true; duringExport.cancel() }
                }
        } catch is CancellationError { cancelledDuringEncoding = true }
        try check(reachedEncoding && cancelledDuringEncoding && FileManager.default.fileExists(atPath: source.path),
                  "编码期间取消未生效或原片丢失")
        print("PASS HEVC encoding cancellation after progress; source preserved")
        let cancelled = directory.appendingPathComponent("cancelled.mov")
        let exporter = AutoZoomExporter()
        let task = Task { try await exporter.export(source: source, destination: cancelled, trace: trace,
                                                   fps: 30, quality: .hevc) { _ in } }
        await Task.yield()
        exporter.cancel()
        var didCancel = false
        do { try await task.value }
        catch { didCancel = true }
        try check(didCancel && exporter.cancelled, "取消后仍完成导出")
        try check(FileManager.default.fileExists(atPath: source.path), "取消处理丢失原片")
        print("PASS zoom cancellation: original preserved")
        let failing = AutoZoomExporter()
        var didFail = false
        do {
            try await failing.export(source: source, destination: directory.appendingPathComponent("missing/output.mov"),
                                     trace: trace, fps: 30, quality: .hevc) { _ in }
        } catch { didFail = true }
        try check(didFail && FileManager.default.fileExists(atPath: source.path), "失败导出丢失原片")
        print("PASS zoom export failure: original preserved")
    }

    private static func fixture(to url: URL, quality: RecordingQuality, withAudio: Bool = true,
                                withAudioGap: Bool = false) async throws {
        let width = 640, height = 360
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
                  "测试图像分配失败")
        guard let pixel else { throw RecorderError.message("测试像素为空") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height { for x in 0..<width {
            let i = y * row + x * 4
            bytes[i] = UInt8(40 + y * 160 / height)
            bytes[i + 1] = 120
            bytes[i + 2] = UInt8(40 + x * 160 / width)
            bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                    formatDescriptionOut: &description)
        guard let description else { throw RecorderError.message("测试视频格式失败") }
        func sample(at time: Double) throws -> CMSampleBuffer {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(seconds: 1000.5 + time, preferredTimescale: 60_000), decodeTimeStamp: .invalid)
            var result: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result)
            guard status == noErr, let result else { throw RecorderError.message("测试视频样本失败") }
            return result
        }
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 30, quality: quality,
                                         audioOptions: .init(systemAudio: withAudio, microphone: false))
        let first = try sample(at: 0)
        writer.queue.sync { writer.appendVideo(first) }
        // Only two static source video frames; the effect must animate between them.
        for tick in 0..<(withAudio ? 350 : 0) {
            // The real capture writer must retain one second of initial silence
            // and the two-second gap, even when capture delivers no audio there.
            if withAudioGap && (tick < 50 || (100..<200).contains(tick)) { continue }
            let values = (0..<960).flatMap { index -> [Float] in
                let value = Float(sin(2 * Double.pi * 440 * Double(tick * 960 + index) / 48_000) * 0.1)
                return [value, value]
            }
            let audio = try AudioMixer.sample(values, pts: CMTime(seconds: 1000.5 + Double(tick) * 0.02, preferredTimescale: 48_000))
            writer.queue.sync { writer.appendAudio(audio) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if !withAudio { try await Task.sleep(nanoseconds: 100_000_000) }
        let last = try sample(at: 7)
        writer.queue.sync { writer.appendVideo(last) }
        let stats = try await writer.finish(extendToNow: false)
        try check(stats.videoFrames == 2, "静态测试视频并非两帧")
    }

    private static func validate(original: URL, output: URL) async throws {
        let source = AVURLAsset(url: original), asset = AVURLAsset(url: output)
        let sourceDuration = try await source.load(.duration)
        let duration = try await asset.load(.duration)
        try check(abs(sourceDuration.seconds - duration.seconds) < 0.05, "效果视频时长改变")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try check(audio.count == 1, "效果视频音轨丢失")
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("效果视频缺少画面")
        }
        try check(try await video.load(.naturalSize) == CGSize(width: 640, height: 360), "导出缩小了分辨率")
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        try check(reader.startReading(), "效果视频无法解码")
        var count = 0, first: [Int] = [], zoom: [Int] = [], restored: [Int] = []
        while let sample = frames.copyNextSampleBuffer() {
            count += 1
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let pixel = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(pixel)
                let i = CVPixelBufferGetHeight(pixel) / 2 * row + CVPixelBufferGetWidth(pixel) / 2 * 4
                let color = [Int(bytes[i]), Int(bytes[i + 2])]
                if time > 0.1 && time < 0.2 { first = color }
                if time > 1.1 && time < 1.3 { zoom = color }
                if time > 6.7 { restored = color }
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            }
        }
        try check(reader.status == .completed && count >= 209, "静止原片未持续生成动画帧")
        try check(first.count == 2 && zoom.count == 2 && restored.count == 2, "效果取样帧丢失")
        try check(abs(first[0] - zoom[0]) + abs(first[1] - zoom[1]) > 35, "静止画面上的镜头未放大移动")
        try check(abs(first[0] - restored[0]) + abs(first[1] - restored[1]) < 12, "空闲后未恢复全景")
        if try await video.load(.formatDescriptions).first.map({ CMFormatDescriptionGetMediaSubType($0) }) == kCMVideoCodecType_HEVC {
            let a = try await encodedAudio(source), b = try await encodedAudio(asset)
            try check(a.data == b.data && abs(a.firstPTS - b.firstPTS) < 0.001,
                      "HEVC效果导出不应重编码音轨或改变音频起点")
        }
    }

    private static func encodedAudio(_ asset: AVAsset) async throws -> (data: Data, firstPTS: Double, endPTS: Double) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw RecorderError.message("测试音轨为空") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try check(reader.startReading(), "无法读取测试音频包")
        var data = Data(), firstPTS: Double?, endPTS = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let count = CMBlockBufferGetDataLength(block)
                guard count > 0 else { continue }
                // Empty edit/gap markers are timeline metadata, not audio packets.
                if firstPTS == nil { firstPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
                // Reader buffers can group a different number of AAC packets.
                // Compare the end of the last group, not its starting timestamp.
                endPTS = (CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)).seconds
                var bytes = [UInt8](repeating: 0, count: count)
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes)
                try check(status == noErr, "无法复制测试音频包")
                data.append(contentsOf: bytes)
            }
        }
        try check(reader.status == .completed && firstPTS != nil, "测试音轨未完整读取")
        return (data, firstPTS ?? 0, endPTS)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message(message) }
    }
}
