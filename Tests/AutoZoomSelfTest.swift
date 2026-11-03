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
            ]), duration: 3, fps: fps)
            try check(pause.pose(at: 1.4).scale > 1.59 && pause.pose(at: 1.75).scale < 1.15 &&
                      pause.pose(at: 2.5).scale < 1.001, "应在停顿 1 秒后开始平滑恢复全景")
            let slow = AutoZoomPlan(trace: CursorTrace(samples: slowSamples), duration: 8.5, fps: fps)
            try check(slow.pose(at: 4).scale > 1.59, "慢速持续移动被误判为空闲")
            try check(slow.pose(at: 8.2).scale < 1.001, "慢速移动停止后未恢复全景")
            let jitter = AutoZoomPlan(trace: CursorTrace(samples: jitterSamples), duration: 5, fps: fps)
            try check(jitter.pose(at: 2.5).scale < 1.001, "微小往返抖动意外延长放大")
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
        try checkSimplifiedMotion()
        let saved = try JSONEncoder().encode(trace)
        try check(try JSONDecoder().decode(CursorTrace.self, from: saved).samples.count == trace.samples.count,
                  "轨迹保存错误")
        print("PASS zoom plan: offset coordinates, host time alignment, clicks, 1-second idle/outside restore, bounded crop, no-click, slow movement, jitter, reentry, 30/60fps, JSON")
        print("PASS 70% safe zone: old-band and exact-edge hold, smooth threshold crossing, both axes/directions, in-zone clicks, bounded crop and unchanged idle timing at 30/60fps")
    }

    private static func checkSimplifiedMotion() throws {
        struct Scenario {
            let name: String
            let trace: CursorTrace
            let duration: Double
            let common: Bool
            let local: Bool
            let needsPan: Bool
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
        var scenarios = [
            Scenario(name: "local-circle", trace: circle, duration: 6, common: true, local: true, needsPan: false),
            Scenario(name: "local-irregular", trace: irregular, duration: 6, common: true, local: true, needsPan: false),
            Scenario(name: "stationary-jitter", trace: jitter, duration: 6, common: true, local: true, needsPan: false),
            Scenario(name: "cross-region", trace: crossing, duration: 6, common: true, local: false, needsPan: true),
            Scenario(name: "moderate-zigzag", trace: zigzag, duration: 6, common: true, local: false, needsPan: true),
            Scenario(name: "wide-circle", trace: wideCircle, duration: 6, common: false, local: false, needsPan: false),
            Scenario(name: "rapid-corners", trace: jumps, duration: 5, common: false, local: false, needsPan: false),
            Scenario(name: "subframe-jumps", trace: subframe, duration: 3, common: false, local: false, needsPan: false),
            Scenario(name: "exit-across-screen", trace: exiting, duration: 4.5, common: false, local: false, needsPan: false),
            Scenario(name: "outside-cross-reentry", trace: outsideCrossing, duration: 3.5, common: false, local: false, needsPan: false),
            Scenario(name: "long-cross-region", trace: longCrossing, duration: 120, common: false, local: false, needsPan: false)
        ]
        for (index, corner) in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)].enumerated() {
            scenarios.append(Scenario(name: "stationary-corner-\(index)", trace: CursorTrace(samples: [
                CursorSample(time: 0, x: corner.0, y: corner.1, inside: true, clicked: false),
                CursorSample(time: 0.2, x: corner.0, y: corner.1, inside: true, clicked: true)
            ]), duration: 3.5, common: true, local: false, needsPan: false))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for fps in [30, 60] {
            for scenario in scenarios {
                let label = "\(scenario.name) \(fps)fps"
                let originalTrace = try encoder.encode(scenario.trace)
                let planningBegan = Date()
                let zooms = ProjectStore.automaticZooms(trace: scenario.trace,
                    duration: scenario.duration, fps: Int32(fps))
                let planningDuration = Date().timeIntervalSince(planningBegan)
                let clip = DemoClip(title: label, sourceStart: 0, duration: scenario.duration, zooms: zooms)
                let restored = try JSONDecoder().decode([ZoomSegment].self, from: encoder.encode(zooms))
                let reopened = DemoClip(title: label, sourceStart: 0, duration: scenario.duration, zooms: restored)
                let largestCount = zooms.map { $0.cameraControlPoints.count }.max() ?? 0
                if scenario.common {
                    try check(!zooms.isEmpty && zooms.allSatisfy { (4...8).contains($0.cameraControlPoints.count) },
                              "\(label)：普通自动镜头应保留四基础点并控制在八点以内")
                    try check((zooms.map(\.peak).max() ?? 1) > 1.5,
                              "\(label)：普通操作不应靠退回全景来逃避取景规划")
                }
                if scenario.local {
                    try check(largestCount <= 6, "\(label)：一个取景框容得下的局部活动仍生成了太多编辑点")
                }
                if scenario.name == "moderate-zigzag" {
                    try check(zooms.contains { (5...8).contains($0.cameraControlPoints.count) && $0.peak > 1.5 },
                              "\(label)：正常跨区反向应补少量关键点并保留放大，不能一律只留四点再降低倍率")
                }
                if scenario.name == "long-cross-region" {
                    try check(planningDuration <= 10 && largestCount <= 8,
                              "\(label)：120秒轨迹规划超过十秒或仍产生八个以上的编辑点")
                }
                var largestViolation = 0.0
                var totalTravel = 0.0, plateauTravel = 0.0
                var smallestCenterX = 1.0, largestCenterX = 0.0
                func inspect(_ time: Double, x: Double? = nil, y: Double? = nil) throws {
                    let pose = clip.pose(at: time), savedPose = reopened.pose(at: time)
                    try check([pose.x, pose.y, pose.scale].allSatisfy(\.isFinite) && pose.scale >= 1 && pose.scale <= 1.600000001,
                              "\(label)：最终镜头倍率或取景位置无效")
                    let half = 0.5 / pose.scale
                    try check(pose.x - half >= -0.000001 && pose.y - half >= -0.000001 &&
                              pose.x + half <= 1.000001 && pose.y + half <= 1.000001,
                              "\(label)：最终预览取景超出原片产生黑边")
                    try check(abs(pose.x - savedPose.x) < 0.000000001 && abs(pose.y - savedPose.y) < 0.000000001 &&
                              abs(pose.scale - savedPose.scale) < 0.000000001,
                              "\(label)：保存重开后实际镜头路线发生变化")
                    if let x, let y {
                        let violation = max(0, max(max(pose.x - half - x, x - pose.x - half),
                                                  max(pose.y - half - y, y - pose.y - half)))
                        largestViolation = max(largestViolation, violation)
                        try check(violation <= 0.000001,
                                  "\(label)：鼠标在 \(time)s 越出最终取景框 \(violation)，不能以少节点为由裁掉操作")
                    }
                }
                let samples = scenario.trace.samples
                for sample in samples where sample.time.isFinite && sample.time >= 0 && sample.time <= scenario.duration &&
                    sample.x.isFinite && sample.y.isFinite && (0...1).contains(sample.x) && (0...1).contains(sample.y) {
                    try inspect(sample.time, x: sample.x, y: sample.y)
                }
                // Check between capture samples too: frame-only checks miss
                // clipping during zoom ramps and source-boundary crossings.
                for (a, b) in zip(samples, samples.dropFirst()) where
                    a.time.isFinite && b.time.isFinite && b.time > a.time &&
                    a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite {
                    let count = max(1, Int(ceil((b.time - a.time) * 240)))
                    for index in 0...count {
                        let amount = Double(index) / Double(count)
                        let time = a.time + (b.time - a.time) * amount
                        let x = a.x + (b.x - a.x) * amount, y = a.y + (b.y - a.y) * amount
                        if time >= 0, time <= scenario.duration, (0...1).contains(x), (0...1).contains(y) {
                            try inspect(time, x: x, y: y)
                        }
                    }
                }
                var previous = clip.pose(at: 0)
                let frameCount = Int(ceil(scenario.duration * 240))
                for index in 0...frameCount {
                    let time = min(scenario.duration, Double(index) / 240), pose = clip.pose(at: time)
                    try inspect(time)
                    if let last = samples.last, last.inside, time >= last.time {
                        try inspect(time, x: last.x, y: last.y)
                    }
                    let distance = hypot(pose.x - previous.x, pose.y - previous.y)
                    totalTravel += distance
                    if time >= 1 && time <= 3.8 && pose.scale > 1.5 && previous.scale > 1.5 {
                        plateauTravel += distance
                        smallestCenterX = min(smallestCenterX, pose.x)
                        largestCenterX = max(largestCenterX, pose.x)
                    }
                    previous = pose
                }
                if scenario.local {
                    try check(plateauTravel <= 0.2, "\(label)：局部绕圈或不规则活动仍让镜头频繁追着鼠标移动")
                }
                if scenario.needsPan {
                    try check(largestCenterX - smallestCenterX > 0.08,
                              "\(label)：跨区域操作应表现为镜头平移，不能一直固定全景")
                }
                for zoom in zooms {
                    let controls = zoom.cameraControlPoints
                    try check(controls.first?.scale == 1 && controls.last?.scale == 1 &&
                              zip(controls, controls.dropFirst()).allSatisfy { $0.time < $1.time },
                              "\(label)：基础端点或关键点时间顺序不正确")
                    for (a, b) in zip(controls, controls.dropFirst()) {
                        let start = zoom.pose(at: a.time), end = zoom.pose(at: b.time)
                        let dx = end.x - start.x, dy = end.y - start.y, lengthSquared = dx * dx + dy * dy
                        var priorProgress = 0.0
                        for index in 0...16 {
                            let time = a.time + (b.time - a.time) * Double(index) / 16
                            let pose = zoom.pose(at: time)
                            if lengthSquared < 0.000000000001 {
                                try check(hypot(pose.x - start.x, pose.y - start.y) <= 0.000001,
                                          "\(label)：同位置关键点之间仍藏着往返运动")
                            } else {
                                let cross = (pose.x - start.x) * dy - (pose.y - start.y) * dx
                                let progress = ((pose.x - start.x) * dx + (pose.y - start.y) * dy) / lengthSquared
                                try check(abs(cross) / sqrt(lengthSquared) <= 0.000001 &&
                                          progress >= priorProgress - 0.000001 && progress >= -0.000001 && progress <= 1.000001,
                                          "\(label)：相邻关键点之间不是单调直线运动，或存在未显示的绕行")
                                priorProgress = progress
                            }
                        }
                    }
                    try check(!zoom.centerPath.isEmpty && zoom.manualCenterPath != nil,
                              "\(label)：简化取景时丢掉了原始自动中心记录或稀疏编辑路线")
                }
                try check(try encoder.encode(scenario.trace) == originalTrace && restored == zooms,
                          "\(label)：简化或保存重开改变了原始鼠标记录或关键点数据")
                print(String(format: "METRIC simplified %@: maxNodes=%d, travel=%.5f, plateauTravel=%.5f, cursorViolation=%.9f, planningSeconds=%.4f",
                             label, largestCount, totalTravel, plateauTravel, largestViolation, planningDuration))
            }
        }
        print("PASS simplified motion: sparse straight paths, local stability, real pans, corner/subframe/source-boundary containment, inverse-zoom edges, 120-second planning, 30/60fps and JSON identity")
    }

    private static func checkSafeZone(fps: Int) throws {
        // At 1.6x, the viewport is 0.625 wide/high. Its centered 70% region
        // extends 0.21875 from the target; the former 50% region used 0.15625.
        let halfSafeZone = 0.21875
        let insideOffset = 0.1875
        let outsideOffset = 0.25
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
                          "\(label)：旧50%外、新70%内或安全区边界意外平移")
                var expected = 0.5
                for index in plan.poses.indices {
                    let target = index >= fps && index < 2 * fps ? firstTarget : 0.5
                    expected += (target - expected) * alpha
                    let pose = plan.poses[index]
                    let actual = horizontal ? pose.x : pose.y
                    let otherAxis = horizontal ? pose.y : pose.x
                    try check(abs(actual - expected) < 0.000000001 && abs(otherAxis - 0.5) < 0.000000001,
                              "\(label)：越过70%后的平移、反向安全区或原有平滑速度不正确")
                }
                let firstPan = plan.poses[fps]
                let firstCoordinate = horizontal ? firstPan.x : firstPan.y
                let firstDistance = (firstCoordinate - 0.5) * direction
                try check(firstDistance > 0 && firstDistance < panDistance,
                          "\(label)：越界后应平滑移动，不能立即跳到新中心")
                try check(plan.pose(at: 2.9).scale > 1.59 && plan.pose(at: 3.35).scale < 1.08 &&
                          plan.pose(at: 4.2).scale < 1.001,
                          "\(label)：放大持续时间应仍为最后一次活动后1秒，再平滑回全景")
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
                      "\(label)：70%安全区跟随越出录制范围或改变了放大倍率")
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
