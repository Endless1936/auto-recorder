import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics

@MainActor
enum ProjectSelfTest {
    static func run(directory: URL) async throws {
        try runLogic()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureURL = directory.appendingPathComponent("fixture.mov")
        try await fixture(to: fixtureURL)
        let sourceDuration = try await AVURLAsset(url: fixtureURL).load(.duration).seconds
        let trace = CursorTrace(samples: [
            CursorSample(time: 0, x: 0.5, y: 0.5, inside: true, clicked: false),
            CursorSample(time: 0.4, x: 0.3, y: 0.35, inside: true, clicked: true),
            CursorSample(time: 0.8, x: 0.7, y: 0.6, inside: true, clicked: false),
            CursorSample(time: 4, x: 0.65, y: 0.45, inside: true, clicked: true)
        ])
        let folder = try ProjectStore.createFolder(in: directory)
        let project = try ProjectStore.create(directory: folder, rawURL: fixtureURL, trace: trace,
            fps: 30, quality: .hevc, duration: sourceDuration, pixelSize: CGSize(width: 640, height: 360))
        try check(project.clips.count == 1 && project.clips[0].zooms.count >= 2,
                  "鼠标点击应生成多个可编辑放大段")
        try check(project.clips[0].zooms.contains { $0.centerPath.count > 5 }, "自动中心移动未保存")
        let jsonText = try String(contentsOf: project.jsonURL, encoding: .utf8)
        try check(!jsonText.contains(folder.path) && !project.originalFile.hasPrefix("/"),
                  "工程中的原片路径必须相对文件夹")
        let original = try Data(contentsOf: project.sourceURL)
        print("PASS project creation: dated folder, relative original, multiple editable zooms and saved camera centers")
        try await checkUnchangedAutosave(source: fixtureURL, duration: sourceDuration, directory: directory)
        try await checkOverlappingLoads(olderFolder: folder, source: fixtureURL,
                                        duration: sourceDuration, directory: directory)
        try await checkFramingPreview(source: fixtureURL, duration: sourceDuration, directory: directory)
        try await checkAutomaticMotionEditing(source: fixtureURL, duration: sourceDuration, directory: directory)
        try await checkCameraAnchorEditing(source: fixtureURL, duration: sourceDuration, directory: directory)
        try await checkCameraAnchorBatchEditing(source: fixtureURL, duration: sourceDuration, directory: directory)
        try await checkCameraAnchorDeletion(source: fixtureURL, duration: sourceDuration, directory: directory)

        let model = EditorModel()
        try await model.loadProject(folder: folder)
        try check(model.player.currentItem != nil && model.sourceURL == project.sourceURL, "未建立真实预览")
        model.seek(2)
        let beforeCutPose = model.activePose
        try check(model.split(), "首次分割失败")
        try check(abs(model.activePose.scale - beforeCutPose.scale) < 0.000001,
                  "切在放大中间改变了边界倍率")
        model.seek(4)
        try check(model.split(), "第二次分割失败")
        let middleID = model.clips[1].id
        model.select(middleID)
        try check(model.deleteSelected(), "删除中间片段失败")
        let lastID = model.clips.last!.id
        model.moveClip(id: lastID, before: model.clips.first!.id)
        try check(model.clips.first?.sourceStart == 4, "片段未重排")
        try check(abs(model.duration - (sourceDuration - 2)) < 0.000001, "剪切重排时长错误")
        if let clip = model.clips.first, var zoom = clip.zooms.first {
            model.selectZoom(zoom.id)
            model.beginEditing()
            zoom.peak = 2
            zoom.focusX = 0.68; zoom.focusY = 0.42; zoom.manualFocus = true
            model.setZoom(zoom, for: clip.id, recordUndo: false)
            model.endEditing()
            try check(model.canUndo, "拖动操作未记录撤销")
        }
        try model.autosave()
        let editedClips = model.clips
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == editedClips, "重新打开覆盖了编辑方案")
        model.undo()
        try check(model.clips != editedClips, "撤销未恢复修改前参数")
        print("PASS project editing: real preview, split/delete/reorder, camera continuity, undo and automatic JSON persistence")

        let renamed = directory.appendingPathComponent("移动后整体改名", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let moved = EditorModel()
        try await moved.loadProject(folder: renamed)
        // The explicit undo above saved its result, so check the disk document.
        let movedProject = try ProjectStore.load(folder: renamed)
        try check(moved.sourceURL == renamed.appendingPathComponent(project.originalFile) &&
                  moved.clips == movedProject.clips, "移动或改名后不能恢复工程")
        try check(try Data(contentsOf: movedProject.sourceURL) == original, "编辑或移动修改了原片")
        print("PASS portable project: folder move/rename and raw media intact")

        let hevc = directory.appendingPathComponent("edited-hevc.mov")
        try await moved.export(to: hevc)
        try await validate(output: hevc, duration: moved.duration, codec: kCMVideoCodecType_HEVC, reordered: true)
        moved.quality = .proRes
        let prores = directory.appendingPathComponent("edited-prores.mov")
        try await moved.export(to: prores)
        try await validate(output: prores, duration: moved.duration, codec: kCMVideoCodecType_AppleProRes422, reordered: true)
        print("PASS real export: reordered HEVC/ProRes, original dimensions, edited duration, audible decoded audio/video")

        var flat = try ProjectStore.load(folder: renamed)
        flat.quality = .hevc
        flat.clips = [DemoClip(title: "原片", sourceStart: 0, duration: sourceDuration, zooms: [])]
        let copy = directory.appendingPathComponent("full-view-copy.mov")
        try await ProjectExporter().export(project: flat, destination: copy) { _ in }
        try check(try Data(contentsOf: copy) == original, "全景未剪工程应直接复制原片")
        print("PASS unedited full view: byte-identical source copy")

        let preservedTarget = directory.appendingPathComponent("preserved-target.mov")
        let sentinel = Data("existing target must survive cancellation".utf8)
        try sentinel.write(to: preservedTarget)
        let beforeJSON = try Data(contentsOf: movedProject.jsonURL)
        let cancelExporter = ProjectExporter()
        var cancelledDuringProgress = false
        do {
            var cancelProject = try ProjectStore.load(folder: renamed)
            cancelProject.quality = .hevc
            try await cancelExporter.export(project: cancelProject, destination: preservedTarget) { value in
                if value > 0.04 { cancelledDuringProgress = true; cancelExporter.cancel() }
            }
            throw RecorderError.message("取消导出应返回取消错误。")
        } catch is CancellationError {}
        try check(cancelledDuringProgress, "未覆盖编码过程中的取消")
        try check(try Data(contentsOf: preservedTarget) == sentinel, "取消覆盖了原有目标")
        try check(try Data(contentsOf: movedProject.sourceURL) == original, "取消修改了原片")
        try check(try Data(contentsOf: movedProject.jsonURL) == beforeJSON, "取消修改了工程参数")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(!leftovers.contains { $0.hasPrefix(".导出中-") }, "取消后留下临时导出文件")
        print("PASS cancellation: existing output, project and original preserved; temporary output removed")

        let legacy = directory.appendingPathComponent("旧版原片", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacySource = legacy.appendingPathComponent("原片.mov")
        try FileManager.default.copyItem(at: fixtureURL, to: legacySource)
        try JSONEncoder().encode(trace).write(to: legacy.appendingPathComponent("原片.cursor.json"))
        let imported = try ProjectStore.load(folder: legacy)
        try check(!imported.clips[0].zooms.isEmpty && FileManager.default.fileExists(atPath: imported.jsonURL.path),
                  "旧版原片与鼠标轨迹未导入工程")
        print("PASS legacy import: original and cursor trace become a persisted editable project")
    }

    static func runLogic() throws {
        try checkTimeViewport()
        try checkLocalFramingCorrection()
        try checkSimpleCameraInterpolation()
        try checkPositionOnlyCameraInterpolation()
        try checkCameraKeyframes()
        try checkAutomaticMotionLogic()
        try checkDeletedMotionSpans()
        try checkCameraTargetNavigation()
        try checkCameraAnchorDragging()
        try checkCameraSelectionDeletion()
        try checkFramingPaths()
        try checkZoomMath()
        try checkAddZoomPlacement()
        try checkZoomCleanup()
        let zoom = ZoomSegment(start: 1, riseEnd: 3, fallStart: 7, end: 9, peak: 2,
                               focusX: 0.3, focusY: 0.7, manualFocus: true)
        try check(zoom.scale(at: 1) == 1 && zoom.scale(at: 3) == 2 &&
                  zoom.scale(at: 7) == 2 && zoom.scale(at: 9) == 1, "四个曲线控制点不精确")
        try check(abs(zoom.scale(at: 2) - 1.5) < 0.000001 &&
                  abs(zoom.scale(at: 8) - 1.5) < 0.000001, "倍率曲线平滑插值错误")
        let model = EditorModel()
        let first = DemoClip(title: "A", sourceStart: 0, duration: 12, zooms: [zoom])
        let second = DemoClip(title: "B", sourceStart: 12, duration: 6, zooms: [])
        model.clips = [first, second]
        model.selectedClipID = first.id
        model.selectedZoomID = zoom.id
        model.seek(2)
        try check(model.split(), "曲线上分割失败")
        let right = model.clips[1]
        try check(right.zooms.first?.id != zoom.id, "分割后的两个放大段不能共享选中标识")
        if let rightZoom = right.zooms.first {
            model.selectZoom(rightZoom.id)
            try check(model.selectedClipID == right.id, "点击右片放大段选中了左片")
        }
        for time in stride(from: 0.0, through: right.duration, by: 0.05) {
            let a = first.pose(at: time + 2), b = right.pose(at: time)
            try check(abs(a.scale - b.scale) < 0.000001 && abs(a.x - b.x) < 0.000001 &&
                      abs(a.y - b.y) < 0.000001, "剪切后的倍率或中心轨迹改变")
        }
        model.undo()
        try check(model.clips == [first, second], "分割撤销错误")
        model.select(first.id)
        try check(model.trimSelected(start: 2, end: 10), "首尾裁剪失败")
        try check(model.clips[0].sourceStart == 2 && model.clips[0].duration == 8, "原片裁剪范围错误")
        model.undo()
        model.moveClip(id: second.id, before: first.id)
        try check(model.clips.map(\.id) == [second.id, first.id] && model.totalDuration == 18, "片段重排错误")
        model.undo()
        print("PASS project logic: exact four-point curve, split/trim camera preservation, reorder and undo")

        let left = ZoomSegment(start: 0, riseEnd: 1, fallStart: 3, end: 5, peak: 2,
                               focusX: 0.25, focusY: 0.35, manualFocus: true)
        let rightZoom = ZoomSegment(start: 1, riseEnd: 3, fallStart: 5, end: 6, peak: 2,
                                    focusX: 0.75, focusY: 0.65, manualFocus: true)
        let overlap = DemoClip(title: "重叠", sourceStart: 0, duration: 6, zooms: [left, rightZoom])
        let reverse = DemoClip(title: "反向", sourceStart: 0, duration: 6, zooms: [rightZoom, left])
        let before = overlap.pose(at: 3 - 0.000001), after = overlap.pose(at: 3 + 0.000001)
        try check(abs(before.x - after.x) < 0.00001 && abs(before.y - after.y) < 0.00001,
                  "重叠放大段在倍率交叉处出现中心跳变")
        for time in stride(from: 0.0, through: 6.0, by: 0.01) {
            let a = overlap.pose(at: time), b = reverse.pose(at: time)
            let expected = max(left.scale(at: time), rightZoom.scale(at: time))
            let margin = 0.5 / a.scale
            try check(abs(a.scale - expected) < 0.000001 && abs(a.x - b.x) < 0.000001 &&
                      abs(a.y - b.y) < 0.000001, "重叠合成依赖段顺序或改变倍率")
            try check(a.x >= margin - 0.000001 && a.x <= 1 - margin + 0.000001 &&
                      a.y >= margin - 0.000001 && a.y <= 1 - margin + 0.000001,
                      "重叠镜头超出原片边界")
        }
        try check(ProjectStore.automaticZooms(trace: CursorTrace(samples: []), duration: 6, fps: 30).isEmpty,
                  "关闭自动放大后空轨迹仍生成了镜头")
        print("PASS overlapping zooms: continuous weighted center, max scale, order independence and bounded crop; empty trace stays flat")

        let disabledFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-recorder-disabled-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: disabledFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: disabledFolder) }
        let raw = disabledFolder.appendingPathComponent("原片.mov")
        // This store-only regression supplies metadata directly; no codec is needed.
        try Data([0]).write(to: raw)
        let retainedTrace = CursorTrace(samples: [
            CursorSample(time: 0.5, x: 0.3, y: 0.4, inside: true, clicked: true),
            CursorSample(time: 1, x: 0.7, y: 0.6, inside: true, clicked: false)
        ])
        let disabled = try ProjectStore.create(directory: disabledFolder, rawURL: raw,
            trace: retainedTrace, fps: 30, quality: .hevc, duration: 6,
            pixelSize: CGSize(width: 16, height: 16), autoZoomEnabled: false)
        let disabledReloaded = try ProjectStore.load(folder: disabledFolder)
        try check(disabled.trace.samples.count == retainedTrace.samples.count &&
                  disabledReloaded.trace.samples.count == retainedTrace.samples.count &&
                  disabledReloaded.trace.samples.first?.clicked == true &&
                  disabledReloaded.trace.samples.last?.x == 0.7 &&
                  disabled.clips.allSatisfy { $0.zooms.isEmpty } &&
                  disabledReloaded.clips.allSatisfy { $0.zooms.isEmpty },
                  "关闭自动放大应保留完整轨迹，但不生成默认放大段")
        print("PASS disabled auto zoom: nonempty cursor trace persisted and reopened without initial zoom segments")

        var oldTiming = disabledReloaded
        let degenerate = ZoomSegment(start: 2, riseEnd: 2, fallStart: 2, end: 2, peak: 1.6)
        oldTiming.clips[0].zooms = [degenerate]
        // Write the old representation directly so load exercises migration.
        try JSONEncoder().encode(oldTiming).write(to: oldTiming.jsonURL, options: .atomic)
        let repaired = try ProjectStore.load(folder: disabledFolder)
        guard let repairedZoom = repaired.clips[0].zooms.first else {
            throw RecorderError.message("保存的镜头丢失。")
        }
        try check(repaired.clips[0].zooms.count == 1 && repairedZoom.id == degenerate.id &&
                  repairedZoom.peak == 1.6 && repairedZoom.start < repairedZoom.riseEnd &&
                  repairedZoom.riseEnd < repairedZoom.fallStart && repairedZoom.fallStart < repairedZoom.end,
                  "重开时没有修复退化时序，或错误重新生成了用户镜头")
        print("PASS saved control repair: degenerate timing repaired without replacing camera identity, amplitude or pointer trace")
    }

    private static func checkTimeViewport() throws {
        var viewport = EditorTimeViewport()
        viewport.zoom(by: 4, anchor: 0.4)
        try check(viewport.scale == 4 && abs(viewport.start - 0.3) < 1e-12,
                  "时间轴缩放没有保持鼠标锚定的时间")
        for width in [932.0, 1132, 1800] {
            let axis = EditorTimeAxisGeometry(containerWidth: width, viewport: viewport)
            try check(abs(axis.time(at: axis.minX, total: 120) - 36) < 1e-8 &&
                      abs(axis.time(at: axis.maxX, total: 120) - 66) < 1e-8,
                      "缩放后的可见时间范围不正确")
            for time in stride(from: 36.0, through: 66.0, by: 0.125) {
                try check(abs(axis.time(at: axis.x(at: time, total: 120), total: 120) - time) < 1e-8,
                          "时间与横坐标转换不一致")
            }
            try check(abs(axis.timeDelta(for: axis.width / 2, total: 120) - 15) < 1e-8,
                      "放大后拖动节点仍使用未缩放的时间比例")
        }
        for _ in 0..<100 {
            viewport.zoom(by: 1.25, anchor: 0.9)
            viewport.pan(by: 100)
            try check(viewport.scale >= 1 && viewport.scale <= EditorTimeViewport.maximumScale &&
                      viewport.start >= 0 && viewport.start + 1 / viewport.scale <= 1 + 1e-12,
                      "放大或滚动使时间范围越过素材尾部，露出空白")
        }
        for _ in 0..<100 { viewport.zoom(by: 0.8, anchor: 0.2); viewport.pan(by: -100) }
        try check(viewport.scale == 1 && viewport.start == 0, "时间轴能缩到100%以下或无法恢复完整范围")
        let model = EditorModel()
        model.clips = [DemoClip(title: "视图缩放", sourceStart: 0, duration: 120, zooms: [.standard(duration: 120)])]
        model.seek(30)
        let clips = model.clips, time = model.playhead
        model.zoomTimeAxis(by: 4, anchor: 0.25)
        model.panTimeAxis(by: 0.1)
        try check(model.clips == clips && model.playhead == time && !model.canUndo,
                  "时间轴缩放/滚动修改了工程、播放时间或撤销历史")
        let before = model.timeViewport
        model.beginEditing()
        model.zoomTimeAxis(by: 2, anchor: 0.5)
        model.panTimeAxis(by: 0.2)
        model.endEditing()
        try check(model.timeViewport == before, "节点编辑中缩放视图改变了正在拖动的坐标系")
        print("PASS shared timeline viewport: 100%-6400% bounds, cursor anchoring, shared time/pixel mapping, scaled drag deltas, bounded panning, exact full-fit reset and no content/playhead/Undo mutations")
    }

    private static func checkLocalFramingCorrection() throws {
        let path = (0...240).map { index in
            let t = Double(index) / 30
            return ZoomCenterPoint(time: t, x: 0.5 + 0.035 * sin(t * 4), y: 0.5 + 0.03 * cos(t * 3))
        }
        let original = ZoomSegment(start: 0, riseEnd: 1, fallStart: 7, end: 8, peak: 1.8, centerPath: path)
        var edited = original
        let time = 4.2, before = original.pose(at: time)
        edited.setLocalFramingCenter(x: before.x + 0.06, y: before.y - 0.04, at: time, visibleStart: 0, visibleEnd: 8)
        try check(edited.centerPath == path && edited.cameraKeyframes == nil && edited.localCenterEdits?.count == 1,
                  "局部拖框修改了原始轨迹、创建多余曲线点或没有保存局部修正")
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(edited))
        let shifted = decoded.shifted(by: -2.3).normalized()
        try check(decoded == edited, "局部取景修正未完整保存")
        for i in 0...1920 {
            let t = Double(i) / 240
            let base = original.pose(at: t), actual = decoded.pose(at: t), cut = shifted.pose(at: t - 2.3)
            let distance = abs(t - time)
            let d = min(1, distance)
            let weight = distance < 1 ? 1 - d * d * (3 - 2 * d) : 0
            try check(abs(actual.x - base.x - 0.06 * weight) < 1e-8 &&
                      abs(actual.y - base.y + 0.04 * weight) < 1e-8 && actual.scale == base.scale &&
                      abs(cut.x - actual.x) < 1e-8 && abs(cut.y - actual.y) < 1e-8,
                      "局部修正没有保留原始运动，或影响区间外/保存/剪切后的画面")
        }
        for t in [time - 1, time + 1] {
            let epsilon = 1e-5
            let a = decoded.pose(at: t - epsilon), b = decoded.pose(at: t + epsilon)
            let x = original.pose(at: t - epsilon), y = original.pose(at: t + epsilon)
            try check(abs((b.x - a.x) - (y.x - x.x)) / (2 * epsilon) < 0.0001,
                      "局部修正接回原轨迹时速度发生突变")
        }
        for _ in 0..<100 {
            edited.setLocalFramingCenter(x: 0.57, y: 0.46, at: time, visibleStart: 0, visibleEnd: 8)
        }
        try check(edited.localCenterEdits?.count == 1 && abs(edited.pose(at: time).x - 0.57) < 1e-8,
                  "重复鼠标事件累积了位移或多余记录")
        edited.setLocalFramingCenter(x: 1, y: 0, at: 4.4, visibleStart: 0, visibleEnd: 8)
        edited.setLocalFramingCenter(x: 0.48, y: 0.51, at: time, visibleStart: 0, visibleEnd: 8)
        try check(abs(edited.pose(at: time).x - 0.48) < 1e-8 && abs(edited.pose(at: time).y - 0.51) < 1e-8,
                  "重叠修正触及边缘后无法重新精确定位")
        var bounded = original
        bounded.cameraKeyframes = [CameraKeyframe(time: 0, scale: 1), CameraKeyframe(time: 1, scale: 1.8),
            CameraKeyframe(time: 3, scale: 1), CameraKeyframe(time: 4, scale: 1.8), CameraKeyframe(time: 8, scale: 1)]
        bounded.setLocalFramingCenter(x: 0.52, y: 0.48, at: 2.5, visibleStart: 2, visibleEnd: 6)
        try check(bounded.localCenterEdits?.first?.start == 2 && bounded.localCenterEdits?.first?.end == 3,
                  "局部修正越过剪切边界或中间全景节点")
        for automatic in [false, true] {
            let base = ZoomSegment(start: 0, riseEnd: 1, fallStart: 7, end: 8, peak: 2,
                centerPath: automatic ? (0...240).map { ZoomCenterPoint(time: Double($0) / 30, x: 0.5, y: 0.5) } : [],
                manualFocus: !automatic)
            var corrected = base
            _ = corrected.addCameraKeyframe(at: 2)
            _ = corrected.addCameraKeyframe(at: 4)
            corrected.setLocalFramingCenter(x: 0.58, y: 0.46, at: 2.5, visibleStart: 0, visibleEnd: 8)
            corrected.setLocalFramingCenter(x: 0.47, y: 0.53, at: 4, visibleStart: 0, visibleEnd: 8)
            let ids = Set(corrected.cameraControlPoints.filter { $0.time == 2 || $0.time == 4 }.map(\.id))
            var moved = corrected
            moved.moveCameraKeyframes(ids: ids, timeDelta: 0.2, scaleDelta: 0)
            try check(moved.localCenterEdits == corrected.localCenterEdits && moved.centerPath == corrected.centerPath,
                      "移动倍率节点改写了局部取景修正或原始运动")
            for i in 0...1920 {
                let t = Double(i) / 240, a = corrected.pose(at: t), b = moved.pose(at: t)
                try check(abs(a.x - b.x) < 1e-8 && abs(a.y - b.y) < 1e-8 && abs(a.scale - b.scale) < 1e-8,
                          "批量移动等倍率节点重复叠加了局部取景位移")
            }
        }
        print("PASS local framing: exact center, smooth one-second falloff, unchanged outside/scale/original, repeat and overlapping drags, edge clamps, full-view/cut boundaries, JSON and shifted cuts")
    }

    private static func checkPositionOnlyCameraInterpolation() throws {
        let original = ZoomSegment(start: 1, riseEnd: 3, fallStart: 7, end: 9, peak: 1.6)
        let times = [1.0, 1.6, 3, 5, 7, 8.2, 9]
        let centers = times.map { time -> ZoomCenterPoint in
            let half = 0.5 / original.scale(at: time)
            return ZoomCenterPoint(time: time, x: half, y: 1 - half,
                timing: time < 3 || time >= 7 ? .viewport : .smooth)
        }
        let zoom = ZoomSegment(start: 1, riseEnd: 3, fallStart: 7, end: 9, peak: 1.6,
            centerPath: centers, manualFocus: true, manualCenterPath: centers, positionMotion: true).normalized()
        try check(zoom.cameraKeyframes == nil && zoom.cameraControlPoints.count == times.count,
                  "位置简化没有暴露全部实际节点，或提前替换了原倍率曲线")
        var inserted = zoom
        for time in [1.9, 4.1, 8.6] { _ = inserted.addCameraKeyframe(at: time) }
        inserted = inserted.normalized()
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(inserted))
        let shifted = decoded.shifted(by: -1.4).normalized()
        try check(decoded == inserted && decoded.manualCenterPath == centers &&
                  shifted.manualCenterPath?.map(\.timing) == centers.map(\.timing),
                  "保存、加点或剪切丢失了位置节点的插值方式")
        for index in 0...1920 {
            let time = 1 + Double(index) / 240, expected = original.scale(at: time)
            for (value, offset) in [(zoom, 0.0), (decoded, 0.0), (shifted, -1.4)] {
                let pose = value.pose(at: time + offset), half = 0.5 / pose.scale
                try check(abs(pose.scale - expected) < 0.00000001 &&
                          abs(pose.x - half) < 0.00000001 && abs(pose.y - (1 - half)) < 0.00000001,
                          "位置插值、无修改加点或剪切改变了原有倍率，或在边角产生裁切")
            }
        }
        let moving = decoded.cameraControlPoints.first { abs($0.time - 5) < 0.000001 }!
        var moved = decoded
        moved.moveCameraKeyframes(ids: [moving.id], timeDelta: 0.2, scaleDelta: 0)
        try check(moved.manualCenterPath?.contains(where: { abs($0.time - 5.2) < 0.000001 && $0.timing == .smooth }) == true,
                  "移动锚点时间丢失了位置插值方式")
        print("PASS position-only camera: unchanged historical scale, visible route, viewport timing, exact insertion, JSON, cuts and horizontal movement")
    }

    private static func checkSimpleCameraInterpolation() throws {
        let points = [CameraKeyframe(time: 1, scale: 1), CameraKeyframe(time: 3, scale: 2),
                      CameraKeyframe(time: 7, scale: 2), CameraKeyframe(time: 9, scale: 1)]
        let centers = [ZoomCenterPoint(time: 1, x: 0.5, y: 0.5),
                       ZoomCenterPoint(time: 3, x: 0.25, y: 0.75),
                       ZoomCenterPoint(time: 7, x: 0.25, y: 0.75),
                       ZoomCenterPoint(time: 9, x: 0.5, y: 0.5)]
        let zoom = ZoomSegment(start: 1, riseEnd: 3, fallStart: 7, end: 9, peak: 2,
            manualFocus: true, manualCenterPath: centers, cameraKeyframes: points, simpleMotion: true).normalized()
        for index in 0...1920 {
            let time = 1 + Double(index) / 240
            let pose = zoom.pose(at: time), half = 0.5 / pose.scale
            try check(abs(pose.x - half) < 0.000000001 && abs(pose.y - (1 - half)) < 0.000000001,
                      "简化镜头的取景位置与画幅未同步，边角鼠标会在缩放途中被裁掉")
        }
        var inserted = zoom
        guard inserted.addCameraKeyframe(at: 2.2) != nil else {
            throw RecorderError.message("无法给简化镜头添加中间锚点")
        }
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(inserted))
        let shifted = decoded.shifted(by: -1.5)
        for index in 0...1920 {
            let time = 1 + Double(index) / 240
            let expected = zoom.pose(at: time), actual = decoded.pose(at: time), cut = shifted.pose(at: time - 1.5)
            try check(abs(actual.scale - expected.scale) < 0.000000001 &&
                      abs(actual.x - expected.x) < 0.000000001 && abs(actual.y - expected.y) < 0.000000001 &&
                      abs(cut.scale - expected.scale) < 0.000000001 && abs(cut.x - expected.x) < 0.000000001 &&
                      abs(cut.y - expected.y) < 0.000000001,
                      "无修改加点、序列化或剪切改变了简化镜头的真实路径")
        }
        print("PASS simple camera interpolation: edge/corner containment through inverse-scale easing, straight spatial motion, exact insertion, JSON and shifted cuts")
    }

    private static func checkCameraKeyframes() throws {
        for automatic in [false, true] {
            let path = automatic ? (0...240).map { index in
                ZoomCenterPoint(time: Double(index) / 40, x: 0.5 + 0.15 * sin(Double(index) / 40), y: 0.48)
            } : []
            let legacy = ZoomSegment(start: 0, riseEnd: 1.4, fallStart: 4.6, end: 6, peak: 1.8,
                focusX: 0.64, focusY: 0.4, centerPath: path, manualFocus: !automatic).normalized()
            var converted = legacy
            for time in [0.37, 0.88, 2.1, 5.2, 5.64] { _ = converted.addCameraKeyframe(at: time) }
            converted = converted.normalized()
            for time in stride(from: 0.0, through: 6.0, by: 0.007) {
                let a = legacy.pose(at: time), b = converted.pose(at: time)
                try check(abs(a.scale - b.scale) < 0.0000001 && abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001,
                          "添加未修改的锚点改变了原有镜头轨迹或缩放曲线")
            }
            let count = converted.cameraControlPoints.count
            _ = converted.addCameraKeyframe(at: 2.1)
            try check(converted.cameraControlPoints.count == count, "重复添加锚点生成了重叠记录")
            let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(converted))
            try check(decoded == converted, "多段镜头锚点未完整保存")
            if automatic {
                converted.setFramingCenter(x: 0.58, y: 0.43, at: 2.112)
                try check(path.allSatisfy { converted.centerPath.contains($0) }, "锚点位置编辑覆盖了原始自动移动路径")
            }
            var shifted = converted.shifted(by: -2.3)
            shifted = shifted.normalized()
            for time in stride(from: 0.0, through: 3.5, by: 0.017) {
                let a = converted.pose(at: time + 2.3), b = shifted.pose(at: time)
                try check(abs(a.scale - b.scale) < 0.0000001 && abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001,
                          "剪切偏移改变了多段锚点的镜头曲线")
            }
        }
        var multiple = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6, manualFocus: true)
        for (time, scale) in [(2.0, 1.3), (3.0, 2.0), (3.5, 1.0)] {
            guard let point = multiple.addCameraKeyframe(at: time) else { throw RecorderError.message("未创建多段锚点。") }
            multiple.updateCameraKeyframe(id: point.id, time: time, scale: scale)
        }
        multiple = multiple.normalized()
        try check(multiple.cameraControlPoints.count == 7 && multiple.scale(at: 1) == 1.6 &&
                  multiple.scale(at: 2) == 1.3 && multiple.scale(at: 3) == 2 && multiple.scale(at: 3.5) == 1 &&
                  multiple.scale(at: 4) == 1.6, "多段锚点没有独立的放大和回落幅度")
        for pair in zip(multiple.cameraControlPoints, multiple.cameraControlPoints.dropFirst()) {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
                let scale = multiple.scale(at: pair.0.time + (pair.1.time - pair.0.time) * fraction)
                try check(scale >= min(pair.0.scale, pair.1.scale) - 0.0000001 &&
                          scale <= max(pair.0.scale, pair.1.scale) + 0.0000001, "多段曲线在锚点之间越界或过冲")
            }
        }
        let moving = multiple.cameraControlPoints.first { abs($0.time - 2) < 0.000001 }!
        multiple.setFramingCenter(x: 0.57, y: 0.46, at: 2)
        let unmovedCenters = multiple.manualCenterPath!.filter { abs($0.time - 2) > 0.000001 }
        multiple.updateCameraKeyframe(id: moving.id, time: 2.4, scale: 1.4)
        try check(multiple.manualCenterPath?.contains(where: { abs($0.time - 2.4) < 0.000001 && abs($0.x - 0.57) < 0.000001 }) == true &&
                  unmovedCenters.allSatisfy { multiple.manualCenterPath!.contains($0) }, "移动时间轴锚点没有同步它的位置控制，或移动了其他控制点")
        var duplicate = multiple
        duplicate.id = UUID()
        duplicate.cameraKeyframes = duplicate.cameraKeyframes?.map { var point = $0; point.id = UUID(); return point }
        try check(DemoClip(title: "重复锚点", sourceStart: 0, duration: 5, zooms: [multiple, duplicate]).canonicalZooms().count == 1,
                  "多段镜头去重错误依赖锚点UUID")
        var close = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6, manualFocus: true)
        _ = close.addCameraKeyframe(at: 1.02)
        _ = close.addCameraKeyframe(at: 1.04)
        let closeIDs = close.cameraControlPoints.map(\.id)
        let middle = close.cameraControlPoints.first { abs($0.time - 1.02) < 0.000001 }!
        close.updateCameraKeyframe(id: middle.id, time: middle.time, scale: 1.3)
        close = close.normalized()
        try check(close.cameraControlPoints.map(\.id) == closeIDs &&
                  close.cameraControlPoints.first(where: { $0.id == middle.id })?.time == middle.time,
                  "相邻锚点不足0.05秒时，纵向改倍率挤乱了时间或顺序")
        let dense = (0...50).map { ZoomCenterPoint(time: Double($0) / 10, x: 0.4 + Double($0) / 250, y: 0.5) }
        var collision = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6, centerPath: dense)
        let control = collision.addCameraKeyframe(at: 2)!
        let originalCenter = collision.pose(at: 2)
        collision.updateCameraKeyframe(id: control.id, time: 2.5, scale: 1.6)
        try check(collision.centerPath == dense &&
                  abs(collision.pose(at: 2.5).x - originalCenter.x) < 0.0000001 &&
                  abs(collision.pose(at: 2.5).y - originalCenter.y) < 0.0000001,
                  "移动锚点时间修改了原始自动路径，或未保留该锚点的取景位置")
        print("PASS camera anchors: exact nondestructive insertion, arbitrary independent scales, smooth bounded spans, original motion retention, stable persistence, timing linkage and cut-domain preservation")
    }

    private static func checkAutomaticMotionLogic() throws {
        func matches(_ a: DemoZoomPose, _ b: DemoZoomPose) -> Bool {
            abs(a.scale - b.scale) < 0.0000001 && abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001
        }
        for circular in [true, false] {
            let path = (0...180).map { index -> ZoomCenterPoint in
                let time = Double(index) / 30
                let phase = (time - 1) * .pi / 2
                let x = circular ? 0.5 + 0.12 * cos(phase) : 0.5 + 0.1 * sin(5.3 * time) + 0.025 * sin(19 * time)
                let y = circular ? 0.5 + 0.1 * sin(phase) : 0.5 + 0.08 * cos(3.7 * time) + 0.03 * sin(13 * time)
                return ZoomCenterPoint(time: time, x: x, y: y)
            }
            let original = ZoomSegment(start: 0, riseEnd: 1, fallStart: 5, end: 6, peak: 1.8, centerPath: path).normalized()
            let controls = original.cameraControlPoints
            try check(controls.count > 4 && controls.count < path.count &&
                      controls.map(\.id) == original.cameraControlPoints.map(\.id) &&
                      zip(controls, controls.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time },
                      "复杂自动路线没有生成稳定、按时间排序的稀疏编辑锚点")
            if circular {
                let a = original.framingKeyframes.first { abs($0.time - 1) < 0.000001 }
                let b = original.framingKeyframes.first { abs($0.time - 5) < 0.000001 }
                try check(a != nil && b != nil && abs(a!.x - b!.x) < 0.0000001 && abs(a!.y - b!.y) < 0.0000001,
                          "打圈路线中同位置、不同时间的节点被错误合并")
            }
            var edited = original
            edited.enableCameraKeyframes()
            for time in [1.73, 2.137, 4.321] { _ = edited.addCameraKeyframe(at: time) }
            for time in stride(from: 0.0, through: 6.0, by: 0.013) {
                try check(matches(original.pose(at: time), edited.pose(at: time)),
                          "启用编辑节点或添加未修改节点改变了打圈/不规则自动运动")
            }
            try check(edited.centerPath == path && edited.framingKeyframes.count == edited.cameraControlPoints.count,
                      "自动路线基底被替换，或预览节点与时间轴节点不统一")
        }

        let path = (0...180).map { ZoomCenterPoint(time: Double($0) / 30, x: 0.5, y: 0.5) }
        let original = ZoomSegment(start: 0, riseEnd: 1, fallStart: 5, end: 6, peak: 1.8, centerPath: path).normalized()
        var edited = original
        let moved = edited.addCameraKeyframe(at: 2)!
        edited.setFramingCenter(x: 0.62, y: 0.46, at: 2)
        try check(edited.centerPath == path && abs(edited.pose(at: 2).x - 0.62) < 0.0000001 &&
                  abs(edited.pose(at: 2).y - 0.46) < 0.0000001,
                  "自动轨迹节点拖动覆盖了原始路线，或没有达到目标取景位置")
        try check(edited.pose(at: 1.5).x > 0.54 && edited.pose(at: 3.5).x > 0.54 &&
                  edited.pose(at: 2 - 1.0 / 30).x > 0.61 && edited.pose(at: 2 + 1.0 / 30).x > 0.61,
                  "拖动自动节点仍然只影响单帧，未平滑影响相邻节点之间的运动")
        for time in [0.0, 0.5, 1.0, 5.0, 5.5, 6.0] {
            try check(matches(edited.pose(at: time), original.pose(at: time)), "局部轨迹修正改变了相邻锚点区间外的画面")
        }
        let beforeInsertion = edited
        _ = edited.addCameraKeyframe(at: 2.71)
        for time in stride(from: 0.0, through: 6.0, by: 0.011) {
            try check(matches(edited.pose(at: time), beforeInsertion.pose(at: time)),
                      "在已编辑路线中添加节点改变了已有运动")
        }
        let oldPose = edited.pose(at: 2)
        edited.updateCameraKeyframe(id: moved.id, time: 2.4, scale: 1.8)
        try check(edited.centerPath == path && matches(edited.pose(at: 2.4), oldPose) &&
                  edited.centerOffsets?.contains(where: { abs($0.time - 2.4) < 0.000001 }) == true &&
                  edited.centerOffsets?.contains(where: { abs($0.time - 2) < 0.000001 }) == false,
                  "自动轨迹节点的时间、位置和局部修正没有同步移动")
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(edited))
        let shifted = decoded.shifted(by: -1.3).normalized()
        try check(decoded == edited, "自动轨迹局部修正未完整持久化")
        for time in stride(from: 0.0, through: 4.5, by: 0.017) {
            try check(matches(shifted.pose(at: time), edited.pose(at: time + 1.3)),
                      "剪切偏移改变了自动轨迹的局部修正")
        }
        var deleted = beforeInsertion
        deleted.removeCameraKeyframes(ids: [moved.id])
        try check(deleted.centerPath == path && !deleted.cameraControlPoints.contains(where: { $0.id == moved.id }) &&
                  deleted.centerOffsets?.contains(where: { abs($0.time - 2) < 0.000001 }) != true,
                  "删除自动运动节点残留局部修正或修改了原始路线")
        for time in stride(from: 0.0, through: 6.0, by: 0.019) {
            try check(matches(deleted.pose(at: time), original.pose(at: time)), "删除唯一位置修正节点没有恢复原始自动路线")
        }
        print("PASS automatic motion: circular/irregular paths, stable chronological controls, exact no-op insertion before/after edits, smooth local correction, immutable base, linked time move/delete, persistence and shifted cuts")
    }

    private static func checkDeletedMotionSpans() throws {
        let path = (0...240).map { index -> ZoomCenterPoint in
            let time = Double(index) / 30
            let angle = (time - 1) * .pi / 3
            return ZoomCenterPoint(time: time, x: 0.5 + 0.15 * cos(angle), y: 0.5 + 0.11 * sin(angle))
        }
        let controls = (0...8).map { CameraKeyframe(time: Double($0), scale: $0 == 0 || $0 == 8 ? 1 : 2) }
        let original = ZoomSegment(start: 0, riseEnd: 1, fallStart: 7, end: 8, peak: 2,
            centerPath: path, cameraKeyframes: controls).normalized()
        func matches(_ a: DemoZoomPose, _ b: DemoZoomPose) -> Bool {
            abs(a.scale - b.scale) < 0.0000001 && abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001
        }
        for indices in [[3], [2, 3, 4], [2, 5], [1], [7]] {
            let ids = Set(indices.map { controls[$0].id })
            var spans: [(Double, Double)] = []
            var first = indices[0], last = indices[0]
            for index in indices.dropFirst() {
                if index == last + 1 { last = index }
                else { spans.append((controls[first - 1].time, controls[last + 1].time)); first = index; last = index }
            }
            spans.append((controls[first - 1].time, controls[last + 1].time))
            var deleted = original
            deleted.removeCameraKeyframes(ids: ids)
            try check(deleted.centerPath == path && deleted.cameraControlPoints.map(\.id) == controls.filter { !ids.contains($0.id) }.map(\.id),
                      "删除运动锚点修改了原始路径或无关控制点")
            for (lower, upper) in spans {
                let a = original.pose(at: lower), b = original.pose(at: upper)
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                var previousProgress = -0.0000001
                for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
                    let pose = deleted.pose(at: lower + (upper - lower) * fraction)
                    let x = pose.x - a.x, y = pose.y - a.y
                    let progress = length > 0.000000001 ? (x * dx + y * dy) / length : 0
                    try check(abs(x * dy - y * dx) < 0.0000001 && progress >= previousProgress - 0.0000001 &&
                              progress >= -0.0000001 && progress <= 1.0000001,
                              "删除锚点后幸存节点之间仍沿弯曲/打圈路线，或直线平移发生回头/过冲")
                    previousProgress = progress
                }
            }
            for time in stride(from: 0.0, through: 8.0, by: 0.013) where !spans.contains(where: { $0.0 < time && time < $0.1 }) {
                try check(matches(deleted.pose(at: time), original.pose(at: time)), "删除节点的直线衔接改变了区间外运动")
            }
            let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(deleted))
            let shifted = decoded.shifted(by: -1.37).normalized()
            try check(decoded == deleted, "删除后的直线平移区间未完整保存")
            for time in stride(from: 0.0, through: 6.5, by: 0.017) {
                try check(matches(shifted.pose(at: time), deleted.pose(at: time + 1.37)), "剪切偏移改变了删除后的直线区间")
            }
            let lower = spans[0].0, upper = spans[0].1, insertionTime = lower + (upper - lower) * 0.37
            var inserted = deleted
            _ = inserted.addCameraKeyframe(at: insertionTime)
            for time in stride(from: 0.0, through: 8.0, by: 0.011) {
                try check(matches(inserted.pose(at: time), deleted.pose(at: time)), "删除后在直线区间加点改变了原有运动")
            }
            let oldCenter = inserted.pose(at: insertionTime)
            inserted.setFramingCenter(x: oldCenter.x + 0.02, y: oldCenter.y - 0.015, at: insertionTime)
            try check(abs(inserted.pose(at: insertionTime).x - oldCenter.x - 0.02) < 0.0000001 &&
                      abs(inserted.pose(at: insertionTime).y - oldCenter.y + 0.015) < 0.0000001 && inserted.centerPath == path,
                      "删除后新增的取景节点不能继续拖动，或拖动覆盖了原始路径")
            for time in stride(from: 0.0, through: 8.0, by: 0.023) where time < lower || time > upper {
                try check(matches(inserted.pose(at: time), deleted.pose(at: time)), "拖动直线区间内新增点影响了区间外画面")
            }
            let insertedControl = inserted.cameraControlPoints.first { abs($0.time - insertionTime) < 0.000001 }!
            let movedTime = insertionTime + (upper - lower) * 0.1
            let movedPose = inserted.pose(at: insertionTime)
            inserted.updateCameraKeyframe(id: insertedControl.id, time: movedTime, scale: insertedControl.scale)
            try check(matches(inserted.pose(at: movedTime), movedPose), "删除后新增节点移动时间时没有保留其取景位置")
            inserted.removeCameraKeyframes(ids: [insertedControl.id])
            for time in stride(from: 0.0, through: 8.0, by: 0.019) {
                try check(matches(inserted.pose(at: time), deleted.pose(at: time)), "直线区间内新增、拖动、移动时间再删除节点未恢复原有直连")
            }
        }
        let clip = DemoClip(title: "删除直线衔接", sourceStart: 0, duration: 8, zooms: [original])
        let model = EditorModel()
        model.clips = [clip]; model.selectedClipID = clip.id; model.selectedZoomID = original.id
        let selected: Set<UUID> = [controls[2].id, controls[3].id, controls[4].id]
        model.selectCameraAnchors(selected, in: clip.id, zoomID: original.id)
        try check(model.deleteSelected() && model.selectedZoom?.centerPath == path, "模型未执行连续节点删除")
        model.undo()
        try check(model.clips == [clip] && model.selectedCameraAnchorIDs == selected, "一次撤销未恢复直线区间删除前的数据与选择")
        print("PASS deleted motion spans: single/contiguous/disjoint groups, protected boundaries, straight monotone pans, unchanged outside/base, exact insertion, continued dragging, persistence, shifted cuts and Undo")
    }

    private static func checkCameraTargetNavigation() throws {
        let firstZoom = ZoomSegment(start: 0, riseEnd: 1, fallStart: 3, end: 4, peak: 1.6, manualFocus: true)
        var duplicate = firstZoom; duplicate.id = UUID()
        let overlap = ZoomSegment(start: 0.5, riseEnd: 1, fallStart: 2, end: 3, peak: 1.8, manualFocus: true)
        let secondZoom = ZoomSegment(start: 0, riseEnd: 0.5, fallStart: 2, end: 3, peak: 1.6, manualFocus: true)
        let hidden = ZoomSegment(start: -2, riseEnd: -0.5, fallStart: 2, end: 4, peak: 1.6, manualFocus: true)
        let first = DemoClip(title: "前片", sourceStart: 10, duration: 4, zooms: [firstZoom, duplicate, overlap])
        let second = DemoClip(title: "后片", sourceStart: 90, duration: 3, zooms: [secondZoom])
        let empty = DemoClip(title: "空镜头片段", sourceStart: 0, duration: 2, zooms: [])
        let clipped = DemoClip(title: "片外锚点", sourceStart: 0, duration: 1, zooms: [hidden])
        let original = [first, second, empty, clipped]
        let model = EditorModel()
        model.clips = original; model.selectedClipID = first.id; model.selectedZoomID = duplicate.id
        let expected = [0.0, 0.5, 1, 2, 3, 4, 4.5, 6, 7, 9, 10]
        try check(model.cameraNavigationTimes == expected && !model.showsFramingOverlay,
                  "导航未按全局时间合并锚点与片段边界、去除等时目标或排除片外锚点")
        model.seek(0.6)
        try check(model.navigateCameraTarget(forward: true) && model.playhead == 1 &&
                  model.selectedClipID == first.id && model.selectedZoomID == duplicate.id &&
                  model.selectedCameraAnchorIDs == [duplicate.cameraControlPoints[1].id] && model.editingSelectionTarget == .cameraAnchors,
                  "关闭辅助层时无法导航，或重合时刻未优先保留当前镜头选择")
        try check(model.navigateCameraTarget(forward: true) && model.playhead == 2 && model.selectedZoomID == overlap.id,
                  "下一目标未跳到最近的其他镜头锚点")
        model.selectedClipID = second.id; model.selectedZoomID = secondZoom.id; model.seek(3.8)
        try check(model.navigateCameraTarget(forward: true) && model.playhead == 4 &&
                  model.selectedClipID == second.id && model.selectedClipID == model.activeClip?.id &&
                  model.selectedCameraAnchorIDs == [secondZoom.cameraControlPoints[0].id],
                  "片段交界处没有选中实际播放的后一片段及其同刻节点")
        model.seek(8)
        try check(model.navigateCameraTarget(forward: true) && model.playhead == 9 &&
                  model.editingSelectionTarget == .clip && model.selectedCameraAnchorIDs.isEmpty && model.selectedZoomID == nil &&
                  model.selectedClipID == clipped.id && model.selectedClipID == model.activeClip?.id,
                  "纯片段边界导航没有清除旧锚点选择")
        model.seek(10)
        for target in expected.reversed().dropFirst() {
            try check(model.navigateCameraTarget(forward: false) && model.playhead == target &&
                      model.selectedClipID == model.activeClip?.id,
                      "向前导航重复同刻目标、遗漏最近目标或混用了原片时间")
        }
        let firstSelection = model.selectedCameraAnchorIDs
        try check(!model.navigateCameraTarget(forward: false) && model.playhead == 0 && model.selectedCameraAnchorIDs == firstSelection,
                  "起点导航发生循环或无目标时更改了选择")
        for target in expected.dropFirst() {
            try check(model.navigateCameraTarget(forward: true) && model.playhead == target &&
                      model.selectedClipID == model.activeClip?.id, "向后导航没有遍历全局目标，或选择与实际画面所属片段不同")
        }
        try check(!model.navigateCameraTarget(forward: true) && model.playhead == 10 && model.clips == original && !model.canUndo,
                  "终点导航发生循环，或导航规范化/修改了镜头数据及撤销历史")
        model.seek(2.2); model.isPlaying = true
        try check(model.navigateCameraTarget(forward: true) && model.playhead == 3 && !model.isPlaying,
                  "播放时导航没有暂停并精确定位")
        model.isExporting = true
        let before = model.playhead
        try check(!model.navigateCameraTarget(forward: true) && model.playhead == before, "导出时导航未禁用")
        model.isExporting = false
        print("PASS camera target navigation: global chronological anchors/boundaries, same-time deduplication, contextual overlap selection, clipped/empty segments, no looping, processed-preview use, playback pause and no content/Undo mutation")
    }

    private static func checkCameraAnchorDragging() throws {
        let centers = [ZoomCenterPoint(time: 0, x: 0.5, y: 0.5),
            ZoomCenterPoint(time: 1, x: 0.62, y: 0.42),
            ZoomCenterPoint(time: 4, x: 0.48, y: 0.56),
            ZoomCenterPoint(time: 5, x: 0.5, y: 0.5)]
        let legacy = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6,
            manualFocus: true, manualCenterPath: centers).normalized()
        func prepared(_ zoom: ZoomSegment) -> EditorModel {
            let model = EditorModel()
            let clip = DemoClip(title: "锚点拖动", sourceStart: 0, duration: 6, zooms: [zoom])
            model.clips = [clip]; model.selectedClipID = clip.id; model.selectedZoomID = zoom.id
            return model
        }
        let firstPeak = legacy.cameraControlPoints[1]
        let model = prepared(legacy)
        let before = model.clips
        model.beginEditing()
        let stationaryGuide = model.dragCameraAnchors(from: legacy, ids: [firstPeak.id], timeDelta: 0,
            scaleDelta: 0.02, snapTolerance: 0.03)
        model.endEditing()
        try check(stationaryGuide == 1.6 && model.clips == before && !model.canUndo && model.selectedZoom?.cameraKeyframes == nil,
                  "原位吸附造成无效格式转换或撤销记录")
        model.beginEditing()
        model.dragCameraAnchors(from: legacy, ids: [firstPeak.id], timeDelta: 0, scaleDelta: 0.35, snapTolerance: 0)
        try check(abs(model.selectedZoom!.scale(at: 1) - 1.95) < 0.0000001 && model.selectedZoom!.scale(at: 4) == 1.6 &&
                  model.selectedZoom!.manualCenterPath == centers, "旧版两峰仍互相绑定位移，或倍率修改覆盖了已编辑位置路径")
        model.dragCameraAnchors(from: legacy, ids: [firstPeak.id], timeDelta: 0, scaleDelta: 0, snapTolerance: 0)
        model.endEditing()
        try check(model.clips == before && !model.canUndo, "拖动回到起点没有恢复原始曲线或制造了空撤销")
        let invalidBefore = model.clips
        model.dragCameraAnchors(from: legacy, ids: [UUID()], timeDelta: 1, scaleDelta: 1, snapTolerance: 0.1)
        model.dragCameraAnchors(from: legacy, ids: [firstPeak.id], timeDelta: 0, scaleDelta: .nan, snapTolerance: 0.1)
        try check(model.clips == invalidBefore && !model.canUndo, "无效锚点或非数值拖动改写了工程")

        var snapping = legacy
        let alignment = snapping.addCameraKeyframe(at: 2)!
        snapping.updateCameraKeyframe(id: alignment.id, time: 2, scale: 1.8)
        snapping = snapping.normalized()
        let snapModel = prepared(snapping)
        let near = snapModel.dragCameraAnchors(from: snapping, ids: [firstPeak.id], timeDelta: 0,
            scaleDelta: 0.18, snapTolerance: 0.03)
        try check(near == 1.8 && abs(snapModel.selectedZoom!.scale(at: 1) - 1.8) < 0.0000001,
                  "接近未选中锚点倍率时没有吸附")
        let far = snapModel.dragCameraAnchors(from: snapping, ids: [firstPeak.id], timeDelta: 0,
            scaleDelta: 0.1, snapTolerance: 0.03)
        try check(far == nil && abs(snapModel.selectedZoom!.scale(at: 1) - 1.7) < 0.0000001,
                  "离开吸附范围后仍被旧辅助线吸住，或拖动累积了增量")
        snapModel.clips.append(DemoClip(title: "其他片段", sourceStart: 6, duration: 3,
            zooms: [ZoomSegment.standard(duration: 3, peak: 1.85)]))
        let crossClip = snapModel.dragCameraAnchors(from: snapping, ids: [firstPeak.id], timeDelta: 0,
            scaleDelta: 0.23, snapTolerance: 0.03)
        try check(crossClip == 1.85 && abs(snapModel.selectedZoom!.scale(at: 1) - 1.85) < 0.0000001,
                  "没有吸附到其他可见片段的控制点倍率")

        var group = legacy
        let second = group.addCameraKeyframe(at: 2)!
        group.updateCameraKeyframe(id: second.id, time: 2, scale: 2.2)
        let third = group.addCameraKeyframe(at: 3)!
        group.updateCameraKeyframe(id: third.id, time: 3, scale: 1.3)
        group = group.normalized()
        let groupModel = prepared(group)
        groupModel.seek(2.7)
        let ids: Set<UUID> = [firstPeak.id, second.id, group.cameraControlPoints.first!.id]
        let originalTimes = group.cameraControlPoints.map(\.time)
        groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: 0, scaleDelta: 100, snapTolerance: 0)
        try check(abs(groupModel.selectedZoom!.scale(at: 1) - 2.4) < 0.0000001 && groupModel.selectedZoom!.scale(at: 2) == 3 &&
                  groupModel.selectedZoom!.cameraControlPoints.map(\.time) == originalTimes && abs(groupModel.playhead - 2.7) < 0.0000001,
                  "批量上拖到上限时抹平了原倍率差、移动了时间或跳转了播放头")
        groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: 0, scaleDelta: -100, snapTolerance: 0)
        try check(groupModel.selectedZoom!.scale(at: 1) == 1 && abs(groupModel.selectedZoom!.scale(at: 2) - 1.6) < 0.0000001 &&
                  groupModel.selectedZoom!.cameraControlPoints.first!.scale == 1,
                  "批量下拖到下限时单独压平了节点，或改变了端点倍率")
        let groupGuide = groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: 0,
            scaleDelta: -0.28, snapTolerance: 0.03)
        try check(groupGuide == 1.3 && abs(groupModel.selectedZoom!.scale(at: 1) - 1.3) < 0.0000001 &&
                  abs(groupModel.selectedZoom!.scale(at: 2) - 1.9) < 0.0000001,
                  "批量吸附没有给所有选中节点应用相同偏移")
        func assertShift(_ result: ZoomSegment, from base: ZoomSegment, ids: Set<UUID>, by delta: Double) throws {
            for point in base.cameraControlPoints {
                let moved = result.cameraControlPoints.first { $0.id == point.id }!
                try check(abs(moved.time - point.time - (ids.contains(point.id) ? delta : 0)) < 0.0000001,
                          "框选组没有应用同一时间位移，或移动了未选节点")
            }
            try check(result.cameraControlPoints.first!.scale == 1 && result.cameraControlPoints.last!.scale == 1,
                      "框选组左右移动改变了全景端点倍率")
        }
        let horizontalModel = prepared(group)
        horizontalModel.clips.append(DemoClip(title: "接近的外部倍率", sourceStart: 6, duration: 3,
            zooms: [ZoomSegment.standard(duration: 3, peak: 1.58)]))
        let horizontalIDs = Set(group.cameraControlPoints.map(\.id))
        let horizontalGuide = horizontalModel.dragCameraAnchors(from: group, ids: horizontalIDs,
            timeDelta: 0.25, scaleDelta: 0, snapTolerance: 0.03)
        try assertShift(horizontalModel.selectedZoom!, from: group, ids: horizontalIDs, by: 0.25)
        try check(horizontalGuide == nil && horizontalModel.selectedZoom!.cameraControlPoints.map(\.scale) == group.cameraControlPoints.map(\.scale),
                  "完全水平的框选组拖动被其他片段的接近倍率吸附，改变了节点高度")
        groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: 0.4, scaleDelta: 0.2, snapTolerance: 0)
        try assertShift(groupModel.selectedZoom!, from: group, ids: ids, by: 0.4)
        try check(abs(groupModel.selectedZoom!.cameraControlPoints.first { $0.id == second.id }!.scale - 2.4) < 0.0000001,
                  "端点与中间点一起斜向拖动时，中间点倍率没有独立变化")
        groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: 100, scaleDelta: 0, snapTolerance: 0)
        try assertShift(groupModel.selectedZoom!, from: group, ids: ids, by: 0.95)
        groupModel.dragCameraAnchors(from: group, ids: ids, timeDelta: -100, scaleDelta: 0, snapTolerance: 0)
        try check(groupModel.selectedZoom == group, "选中片段起点的组越过零时刻，或原位拖动产生无效格式转换")
        let rightIDs: Set<UUID> = [group.cameraControlPoints[group.cameraControlPoints.count - 2].id,
                                    group.cameraControlPoints.last!.id]
        groupModel.dragCameraAnchors(from: group, ids: rightIDs, timeDelta: -0.4, scaleDelta: 0, snapTolerance: 0)
        try assertShift(groupModel.selectedZoom!, from: group, ids: rightIDs, by: -0.4)
        groupModel.dragCameraAnchors(from: group, ids: rightIDs, timeDelta: 100, scaleDelta: 0, snapTolerance: 0)
        try assertShift(groupModel.selectedZoom!, from: group, ids: rightIDs, by: 1)
        let separateIDs: Set<UUID> = [firstPeak.id, third.id]
        groupModel.dragCameraAnchors(from: group, ids: separateIDs, timeDelta: -100, scaleDelta: 0, snapTolerance: 0)
        try assertShift(groupModel.selectedZoom!, from: group, ids: separateIDs, by: -0.95)
        var pan = group
        pan.removeCameraKeyframes(ids: [second.id])
        pan = pan.normalized()
        let panModel = prepared(pan), panIDs: Set<UUID> = [firstPeak.id, third.id]
        panModel.dragCameraAnchors(from: pan, ids: panIDs, timeDelta: 0.4, scaleDelta: 0, snapTolerance: 0)
        try assertShift(panModel.selectedZoom!, from: pan, ids: panIDs, by: 0.4)
        try check(panModel.selectedZoom!.centerPanSpans?.contains {
            abs($0.start - 1.4) < 0.0000001 && abs($0.end - 3.4) < 0.0000001
        } == true, "批量平移没有同步移动删除锚点后形成的平移区间边界")
        var automatic = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.8,
            centerPath: centers)
        _ = automatic.addCameraKeyframe(at: 2)
        automatic.setFramingCenter(x: 0.58, y: 0.44, at: 2)
        automatic = automatic.normalized()
        let automaticModel = prepared(automatic)
        let allIDs = Set(automatic.cameraControlPoints.map(\.id))
        automaticModel.dragCameraAnchors(from: automatic, ids: allIDs, timeDelta: 0.4, scaleDelta: 0, snapTolerance: 0)
        let shifted = automaticModel.selectedZoom!
        try assertShift(shifted, from: automatic, ids: allIDs, by: 0.4)
        for point in automatic.cameraControlPoints {
            let a = automatic.pose(at: point.time), b = shifted.pose(at: point.time + 0.4)
            try check(abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001,
                      "批量时间平移没有从原始快照同步移动取景中心")
        }
        try check(shifted.centerPath == automatic.centerPath, "批量时间平移覆盖了原始鼠标中心轨迹")
        let endpoint = legacy.cameraControlPoints.first!
        let endpointModel = prepared(legacy)
        endpointModel.dragCameraAnchors(from: legacy, ids: [endpoint.id], timeDelta: 0.2, scaleDelta: 2, snapTolerance: 0)
        try check(abs(endpointModel.selectedZoom!.start - 0.2) < 0.0000001 && endpointModel.selectedZoom!.cameraControlPoints.first!.scale == 1 &&
                  endpointModel.selectedZoom!.scale(at: 4) == 1.6, "端点不能调整时间，或端点拖动改变了固定全景倍率")
        print("PASS camera anchor drag: independent peaks, no-op/history, shared time/scale deltas and snapping, contiguous/disjoint and endpoint group bounds, linked automatic centers, fixed endpoint scales and invalid-input guard")
    }

    private static func checkCameraSelectionDeletion() throws {
        var zoom = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6, manualFocus: true)
        let a = zoom.addCameraKeyframe(at: 2)!
        zoom.setFramingCenter(x: 0.58, y: 0.44, at: 2)
        let b = zoom.addCameraKeyframe(at: 3)!
        zoom.setFramingCenter(x: 0.6, y: 0.42, at: 3)
        zoom = zoom.normalized()
        let first = DemoClip(title: "锚点片段", sourceStart: 0, duration: 6, zooms: [zoom])
        let second = DemoClip(title: "后续片段", sourceStart: 6, duration: 2, zooms: [])
        let original = [first, second]
        let model = EditorModel()
        model.clips = original; model.selectedClipID = first.id; model.selectedZoomID = zoom.id
        model.selectCameraAnchors([a.id], in: first.id, zoomID: zoom.id)
        try check(model.editingSelectionTarget == .cameraAnchors && model.canDeleteSelection && model.deleteSelected(),
                  "取景节点选择没有交给节点删除")
        try check(model.clips.count == 2 && model.totalDuration == 8 &&
                  model.selectedZoom!.cameraControlPoints.count == 5 &&
                  !model.selectedZoom!.cameraControlPoints.contains(where: { $0.id == a.id }) &&
                  model.selectedZoom!.manualCenterPath == zoom.manualCenterPath &&
                  !model.selectedZoom!.framingKeyframes.contains(where: { abs($0.time - 2) < 0.000001 }),
                  "删除锚点误删片段、改变总长或残留对应位置控制")
        let after = model.clips
        try check(!model.canDeleteSelection && !model.deleteSelected() && model.clips == after,
                  "锚点删除后继续按Delete误删了整段素材")
        model.undo()
        try check(model.clips == original && model.editingSelectionTarget == .cameraAnchors &&
                  model.selectedCameraAnchorIDs == [a.id], "撤销节点删除未恢复节点选择，或错误恢复为素材删除状态")
        let endpoints = [zoom.cameraControlPoints.first!.id, zoom.cameraControlPoints.last!.id]
        model.selectCameraAnchors(Set(endpoints), in: first.id, zoomID: zoom.id)
        try check(!model.canDeleteSelection && !model.deleteSelected() && model.clips == original && !model.canUndo,
                  "受保护的首尾节点被删除或触发素材删除")
        let group = Set(endpoints + [a.id, b.id])
        model.selectCameraAnchors(group, in: first.id, zoomID: zoom.id)
        try check(model.deleteSelected() && model.selectedZoom!.cameraControlPoints.count == 4 && model.clips.count == 2 &&
                  Set(model.selectedZoom!.cameraControlPoints.map(\.id)).isSuperset(of: endpoints),
                  "批量节点删除没有保留受保护端点")
        model.undo()
        try check(model.clips == original && model.selectedCameraAnchorIDs == group &&
                  model.editingSelectionTarget == .cameraAnchors, "批量节点删除没有由一次撤销恢复内容及选择")
        model.clearCameraAnchorSelection()
        try check(!model.canDeleteSelection && !model.deleteSelected() && model.clips == original,
                  "取景空白处的Delete不应删除片段")
        model.select(second.id)
        try check(model.editingSelectionTarget == .clip && model.selectedCameraAnchorIDs.isEmpty && model.canDeleteSelection &&
                  model.deleteSelected() && model.clips.count == 1 && !model.deleteSelected(),
                  "显式选择素材后无法删除素材，或最后一个片段保护失效")
        model.undo()
        try check(model.clips == original && model.editingSelectionTarget == .clip, "素材删除撤销没有保留素材选择目标")

        let path = [ZoomCenterPoint(time: 0, x: 0.5, y: 0.5), ZoomCenterPoint(time: 1, x: 0.58, y: 0.44),
            ZoomCenterPoint(time: 2.2, x: 0.63, y: 0.4), ZoomCenterPoint(time: 4, x: 0.58, y: 0.44),
            ZoomCenterPoint(time: 5, x: 0.5, y: 0.5)]
        let legacy = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6,
            manualFocus: true, manualCenterPath: path).normalized()
        var legacyClip = first; legacyClip.zooms = [legacy]
        let legacyModel = EditorModel()
        legacyModel.clips = [legacyClip, second]
        legacyModel.selectedClipID = legacyClip.id; legacyModel.selectedZoomID = legacy.id
        legacyModel.selectZoom(legacy.id)
        legacyModel.selectedMotionPointTime = 2.2
        try check(legacyModel.canDeleteSelection && legacyModel.deleteSelected() && legacyModel.clips.count == 2 &&
                  legacyModel.selectedZoom!.cameraKeyframes == nil && legacyModel.selectedZoom!.manualCenterPath == path &&
                  !legacyModel.selectedZoom!.framingKeyframes.contains(where: { abs($0.time - 2.2) < 0.000001 }),
                  "旧版中心轨迹节点无法单独删除")
        for time in stride(from: 0.0, through: 5.0, by: 0.05) {
            try check(legacyModel.selectedZoom!.scale(at: time) == legacy.scale(at: time),
                      "删除旧版中心节点改变了独立缩放曲线")
        }
        legacyModel.undo()
        try check(legacyModel.selectedZoom == legacy && legacyModel.selectedMotionPointTime == 2.2 &&
                  legacyModel.editingSelectionTarget == .cameraAnchors, "旧版轨迹节点删除撤销没有恢复路径及焦点")
        legacyModel.select(legacyClip.id)
        legacyModel.beginFramingEditing()
        var changed = legacy; changed.setFramingCenter(x: 0.59, y: 0.43, at: 2.4)
        legacyModel.setZoom(changed, for: legacyClip.id)
        legacyModel.endEditing(); legacyModel.undo()
        try check(legacyModel.editingSelectionTarget == .cameraAnchors && !legacyModel.canDeleteSelection &&
                  !legacyModel.deleteSelected() && legacyModel.clips.count == 2,
                  "从素材进入取景编辑再撤销后，Delete错误回退成素材删除")
        let structural = EditorModel()
        structural.clips = original; structural.selectedClipID = first.id; structural.selectedZoomID = zoom.id
        structural.selectCameraAnchors([a.id], in: first.id, zoomID: zoom.id)
        structural.seek(1.7)
        try check(structural.split(), "取景编辑焦点下分割失败")
        structural.undo()
        try check(structural.clips == original && structural.editingSelectionTarget == .cameraAnchors &&
                  structural.selectedCameraAnchorIDs == [a.id] && structural.deleteSelected() && structural.clips.count == 2,
                  "撤销分割后Delete错误删除素材而非原先选中的节点")
        structural.undo()
        structural.moveClip(id: second.id, before: first.id)
        structural.undo()
        try check(structural.clips == original && structural.editingSelectionTarget == .cameraAnchors &&
                  structural.selectedCameraAnchorIDs == [a.id], "撤销重排未恢复节点编辑焦点与选择")
        structural.moveClipToEnd(id: first.id)
        structural.undo()
        try check(structural.clips == original && structural.editingSelectionTarget == .cameraAnchors &&
                  structural.selectedCameraAnchorIDs == [a.id], "撤销移到末尾未恢复节点编辑焦点与选择")
        try check(structural.trimSelected(start: 0.1, end: 5.5), "取景编辑焦点下裁剪失败")
        structural.undo()
        try check(structural.clips == original && structural.editingSelectionTarget == .cameraAnchors &&
                  structural.selectedCameraAnchorIDs == [a.id], "撤销裁剪未恢复节点编辑焦点与选择")
        print("PASS selection-aware delete: camera versus clip focus, single/group nodes, protected endpoints, legacy position-only nodes, empty-camera no-op, selection Undo and last-clip protection")
    }

    private static func checkZoomCleanup() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-recorder-zoom-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("原片.mov")
        let original = Data("raw media must not change".utf8)
        try original.write(to: source)
        let duration = 13.386666666666667, cut = 7.802881270226536
        let path = (0..<342).map {
            ZoomCenterPoint(time: 2.033333333333333 + Double($0) / 30, x: 0.3 + Double($0) / 1000, y: 0.4)
        }
        let automatic = ZoomSegment(start: 2.033333333333333, riseEnd: 6.153665700737618,
            fallStart: duration, end: duration + 0.5, peak: 1.7689282654390384,
            focusX: 0.6346787299390928, focusY: 0.29315431837474504, centerPath: path, manualFocus: true)
        let manual = ZoomSegment(start: 5.102866100323625, riseEnd: 5.9028661003236245,
            fallStart: cut, end: 9.102866100323624, peak: 1.6054763719512197, manualFocus: true)
        let opening = ZoomSegment(start: 0, riseEnd: 0.8, fallStart: 3.2, end: 4, manualFocus: true)
        var continuation = manual.shifted(by: -cut)
        continuation.id = UUID()
        let next = ZoomSegment(start: continuation.end, riseEnd: continuation.end + 0.8,
            fallStart: continuation.end + 3.2, end: continuation.end + 4, manualFocus: true)
        func inactive(_ zoom: ZoomSegment) -> ZoomSegment {
            var result = zoom; result.id = UUID(); result.peak = 1; return result
        }
        let validClips = [
            DemoClip(title: "录屏", sourceStart: 0, duration: cut, zooms: [automatic, manual, opening]),
            DemoClip(title: "录屏", sourceStart: cut, duration: duration - cut, zooms: [continuation, next])
        ]
        var dirtyClips = validClips
        dirtyClips[0].zooms.insert(contentsOf: (0..<4).map { _ in inactive(manual) }, at: 1)
        dirtyClips[0].zooms.append(inactive(opening))
        dirtyClips[1].zooms.insert(contentsOf: [inactive(automatic.shifted(by: -cut))] +
            (0..<4).map { _ in inactive(continuation) }, at: 0)
        let trace = CursorTrace(samples: (0..<499).map {
            CursorSample(time: Double($0) * duration / 499, x: 0.3, y: 0.4, inside: true, clicked: $0 % 80 == 0)
        })
        var legacy = RecordingProject(folderURL: folder, originalFile: source.lastPathComponent,
            trace: trace, fps: 60, quality: .hevc, sourceDuration: duration,
            pixelSize: CGSize(width: 1920, height: 1080), clips: dirtyClips)
        legacy.selectedZoomID = dirtyClips[0].zooms[1].id
        let originalJSON = try JSONEncoder().encode(legacy)
        try originalJSON.write(to: legacy.jsonURL, options: .atomic)
        let cleaned = try ProjectStore.load(folder: folder)
        let backup = folder.appendingPathComponent(ProjectStore.zoomCleanupBackupName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try check(dirtyClips.reduce(0) { $0 + $1.zooms.count } == 15 && cleaned.clips == validClips &&
                  cleaned.selectedZoomID == automatic.id, "15 段遗留工程没有只清除 10 个无效段并恢复有效选择")
        try check(try encoder.encode(cleaned.trace) == encoder.encode(trace) &&
                  Data(contentsOf: source) == original && Data(contentsOf: backup) == originalJSON,
                  "清理修改了鼠标轨迹、原片，或没有原子保存原始工程备份")
        let migratedJSON = try Data(contentsOf: cleaned.jsonURL)
        let reopened = try ProjectStore.load(folder: folder)
        try check(reopened.clips == validClips && Data(contentsOf: cleaned.jsonURL) == migratedJSON &&
                  Data(contentsOf: backup) == originalJSON &&
                  FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3,
                  "重复加载重写了工程或累积了清理备份")

        var duplicate = manual; duplicate.id = UUID()
        var differentTime = manual; differentTime.id = UUID(); differentTime = differentTime.shifted(by: 0.01)
        var differentCenter = manual; differentCenter.id = UUID(); differentCenter.focusX += 0.01
        var differentPath = automatic; differentPath.id = UUID(); differentPath.centerPath[0].x += 0.01
        var tiny = opening; tiny.id = UUID(); tiny.peak = 1.00001
        var toSave = cleaned
        toSave.clips[0].zooms += [duplicate, differentTime, differentCenter, differentPath, tiny, inactive(opening)]
        try ProjectStore.save(toSave)
        let saved = try ProjectStore.load(folder: folder)
        try check(saved.clips[0].zooms == validClips[0].zooms + [differentTime, differentCenter, differentPath, tiny] &&
                  saved.clips[1] == validClips[1], "语义去重误删了不同时间、中心、轨迹、极小有效倍率或跨切片段")
        try check(try Data(contentsOf: backup) == originalJSON, "再次清理覆盖了首次原始工程备份")

        let model = EditorModel()
        let clip = DemoClip(title: "反复恢复", sourceStart: 0, duration: 12, zooms: [opening])
        model.clips = [clip]; model.selectedClipID = clip.id; model.selectedZoomID = opening.id
        for _ in 0..<20 {
            let before = model.clips
            model.resetZoom()
            try check(model.clips[0].zooms.isEmpty && model.selectedZoomID == nil && model.selectedZoom == nil,
                      "恢复全景后留下了无效放大段或选择")
            model.undo()
            try check(model.clips == before && model.selectedZoomID == before[0].zooms[0].id,
                      "恢复全景不能撤销到原有放大段")
            model.resetZoom(); model.seek(2); model.addZoom(); model.addZoom()
            try check(model.clips[0].zooms.count == 1 && model.selectedZoom?.isEnabled == true,
                      "反复恢复和添加积累了无效或重复放大段")
        }
        let beforeDrag = model.clips
        model.beginEditing()
        guard var disabled = model.selectedZoom else { throw RecorderError.message("拖动前没有有效放大段。") }
        disabled.peak = 1
        model.setZoom(disabled, for: clip.id)
        model.endEditing(); model.undo()
        try check(model.clips == beforeDrag, "拖动倍率到全景后无法整次撤销")

        var first = opening; first.peak = 1.4
        var dragged = opening; dragged.id = UUID(); dragged.peak = 2
        let dragClip = DemoClip(title: "拖动相遇", sourceStart: 0, duration: 12, zooms: [first, dragged])
        model.clips = [dragClip]; model.selectedClipID = dragClip.id; model.selectedZoomID = dragged.id
        model.beginEditing()
        dragged.peak = first.peak
        model.setZoom(dragged, for: dragClip.id)
        try check(model.clips[0].zooms == [dragged] && model.selectedZoomID == dragged.id,
                  "拖动与另一段相遇时去重删除了正在交互的节点")
        dragged.peak = 2.3
        model.setZoom(dragged, for: dragClip.id)
        model.endEditing(); model.undo()
        try check(model.clips == [dragClip] && model.selectedZoomID == dragged.id,
                  "拖动经过语义重合后继续编辑，不能整次撤销到原有两段")

        model.clips = validClips; model.selectedClipID = validClips[0].id
        model.moveClip(id: validClips[1].id, before: validClips[0].id)
        var reordered = cleaned; reordered.clips = model.clips
        try ProjectStore.save(reordered)
        let moved = try ProjectStore.load(folder: folder)
        try check(moved.clips == [validClips[1], validClips[0]], "清理后重排并重开改变了跨切放大的时域")
        model.undo()
        try check(model.clips == validClips, "清理后重排不能撤销")
        for time in stride(from: 0.0, through: validClips[1].duration, by: 0.025) {
            try check(abs(moved.clips[0].zooms[0].scale(at: time) - manual.scale(at: time + cut)) < 0.000000001,
                      "跨切放大延续曲线在清理、重排或重开后改变")
        }
        print("PASS zoom cleanup: 15-to-5 migration, exact single backup, trace/media preserved, semantic deduplication, reset/add/undo, reorder/reopen and cross-cut curves")
    }

    private static func checkAddZoomPlacement() throws {
        let firstZoom = ZoomSegment(start: 1, riseEnd: 1.4, fallStart: 2.6, end: 3)
        let clip = DemoClip(title: "新增放大", sourceStart: 0, duration: 12, zooms: [firstZoom])
        let model = EditorModel()
        model.clips = [clip]; model.selectedClipID = clip.id
        model.seek(2)
        model.addZoom()
        model.addZoom()
        try check(model.clips[0].zooms.count == 1 && model.selectedZoomID == firstZoom.id &&
                  abs(model.playhead - firstZoom.riseEnd) < 0.000000001 && !model.canUndo,
                  "重复添加没有选择已有段，而是堆叠了新镜头")
        model.seek(4)
        model.addZoom()
        guard let added = model.selectedZoom else { throw RecorderError.message("空档没有添加放大。") }
        try check(model.clips[0].zooms.count == 2 && added.id != firstZoom.id &&
                  added.start >= firstZoom.end - 0.000000001 && added.end <= clip.duration + 0.000000001 &&
                  added.end - added.start <= 4.000000001, "新增镜头跨过邻段或超过四秒")
        model.addZoom()
        try check(model.clips[0].zooms.count == 2 && model.selectedZoomID == added.id,
                  "新镜头建立后再次添加仍然发生堆叠")

        for gap in [0.08, 0.11] {
            let next = ZoomSegment(start: 3 + gap, riseEnd: 3.5 + gap, fallStart: 5, end: 6)
            let boundedClip = DemoClip(title: "相邻镜头空档", sourceStart: 0, duration: 8,
                                       zooms: [firstZoom, next])
            let bounded = EditorModel()
            bounded.clips = [boundedClip]; bounded.selectedClipID = boundedClip.id
            bounded.seek(3 + gap / 2)
            bounded.addZoom()
            if gap < ZoomSegment.minimumTransitionDuration * 2 + ZoomSegment.minimumHoldDuration {
                try check(bounded.clips[0].zooms.count == 2 && !bounded.canUndo,
                          "不足最小入出时长的空档仍建立了镜头")
            } else {
                guard let inserted = bounded.selectedZoom else { throw RecorderError.message("有效短空档未添加镜头。") }
                try check(bounded.clips[0].zooms.count == 3 && inserted.start >= firstZoom.end - 0.000000001 &&
                          inserted.end <= next.start + 0.000000001 && inserted.start < inserted.riseEnd &&
                          inserted.riseEnd < inserted.fallStart && inserted.fallStart < inserted.end,
                          "短空档新增镜头侵入相邻段或出现退化控制点")
            }
        }
        print("PASS add zoom placement: repeat selects existing segment, new segments stay in neighboring gaps, short gaps rejected")
    }

    private static func checkZoomMath() throws {
        func checkSegment(_ segment: ZoomSegment, label: String) throws {
            let value = segment.normalized()
            try check(value == value.normalized(), "\(label)：规范化不稳定")
            try check(value.start < value.riseEnd && value.riseEnd < value.fallStart && value.fallStart < value.end,
                      "\(label)：四个控制点没有严格时序")
            try check(value.riseEnd - value.start >= ZoomSegment.minimumTransitionDuration - 0.00000001 &&
                      value.end - value.fallStart >= ZoomSegment.minimumTransitionDuration - 0.00000001,
                      "\(label)：缺少非零进入或恢复段")
            let nodes = [(value.start, 1.0), (value.riseEnd, value.peak),
                         (value.fallStart, value.peak), (value.end, 1.0)]
            for (time, expected) in nodes {
                try check(abs(value.scale(at: time) - expected) < 0.000000001,
                          "\(label)：曲线未精确经过控制点")
                let before = value.scale(at: time - 0.000001)
                let after = value.scale(at: time + 0.000001)
                try check(abs(before - after) < 0.001, "\(label)：节点附近出现竖跳")
            }
            var previousRise = 1.0, previousFall = value.peak
            for index in 0...1000 {
                let fraction = Double(index) / 1000
                let rise = value.scale(at: value.start + (value.riseEnd - value.start) * fraction)
                let fall = value.scale(at: value.fallStart + (value.end - value.fallStart) * fraction)
                try check(rise.isFinite && fall.isFinite && rise >= previousRise - 0.000000001 &&
                          fall <= previousFall + 0.000000001 && rise <= value.peak + 0.000000001 && fall >= 1,
                          "\(label)：采样出现反向、越界或非法值")
                previousRise = rise; previousFall = fall
            }
            let quarter = value.start + (value.riseEnd - value.start) * 0.25
            let threeQuarter = value.start + (value.riseEnd - value.start) * 0.75
            if value.simpleMotion == true {
                for (a, b) in zip(value.cameraControlPoints, value.cameraControlPoints.dropFirst()) {
                    for fraction in [0.25, 0.75] {
                        let progress = fraction * fraction * (3 - 2 * fraction)
                        let expected = 1 / (1 / a.scale + (1 / b.scale - 1 / a.scale) * progress)
                        try check(abs(value.scale(at: a.time + (b.time - a.time) * fraction) - expected) < 0.00000001,
                                  "\(label)：简化镜头未按相邻控制点平滑改变取景画幅")
                    }
                }
            } else {
                try check(abs(value.scale(at: quarter) - (1 + (value.peak - 1) * 0.15625)) < 0.00000001 &&
                          abs(value.scale(at: threeQuarter) - (1 + (value.peak - 1) * 0.84375)) < 0.00000001,
                          "\(label)：曲线不是预期的 smoothstep")
            }
        }

        let cases = [
            ZoomSegment(start: 2, riseEnd: 2, fallStart: 2, end: 2),
            ZoomSegment(start: 4, riseEnd: 3, fallStart: 2, end: 1),
            ZoomSegment(start: 1, riseEnd: 1, fallStart: 3, end: 4),
            ZoomSegment(start: 1, riseEnd: 2, fallStart: 4, end: 4),
            ZoomSegment(start: 1, riseEnd: 2, fallStart: 2, end: 3),
            ZoomSegment(start: -0.033333333, riseEnd: -0.033333333, fallStart: 0, end: 0.01),
            ZoomSegment.standard(duration: 0.02)
        ]
        for (index, segment) in cases.enumerated() {
            try checkSegment(segment, label: "退化组\(index)")
            for shift in [-2.0001, -0.1, 0.033333333, 100.00001] {
                let shifted = segment.normalized().shifted(by: shift)
                try check(shifted == shifted.normalized(), "切片平移导致已经规范的节点被再次挤动")
            }
        }

        let model = EditorModel()
        let initialZoom = ZoomSegment(start: 1, riseEnd: 2, fallStart: 7, end: 8, peak: 1.6)
        let clip = DemoClip(title: "倍率拖动", sourceStart: 0, duration: 10, zooms: [initialZoom])
        model.clips = [clip]; model.selectedClipID = clip.id; model.selectedZoomID = initialZoom.id
        for target in [2.4, 1.2, 1.6, 1.0, 3.0, 0.8, 4.0] {
            var changed = initialZoom
            changed.peak = target
            model.setZoom(changed, for: clip.id)
            if target <= 1 {
                try check(model.clips[0].zooms.isEmpty && model.selectedZoomID == nil && model.selectedZoom == nil,
                          "倍率降至全景后仍留下放大段或无效选择")
                continue
            }
            // Each edit uses initialZoom.id explicitly, including recreation
            // after the preceding target removed the segment.
            guard let actual = model.selectedZoom else { throw RecorderError.message("有效倍率未恢复放大段。") }
            try check(actual.start == initialZoom.start && actual.riseEnd == initialZoom.riseEnd &&
                      actual.fallStart == initialZoom.fallStart && actual.end == initialZoom.end &&
                      actual.peak == min(3, target) && actual.id == initialZoom.id &&
                      model.clips[0].zooms.count == 1, "拖动倍率时改变了节点时刻、身份或重复添加")
            try checkSegment(actual, label: "拖动倍率\(target)")
        }
        model.setZoom(initialZoom, for: clip.id)
        try check(model.trimSelected(start: 1.5, end: 7.5), "半段曲线裁剪失败")
        let retained = model.selectedClip!
        try check(retained.zoom.start < 0 && retained.zoom.end > retained.duration,
                  "半段曲线的片外控制点被伪夹回片段边界")
        for time in [0.0, 0.000001, retained.duration - 0.000001, retained.duration] {
            try check(abs(retained.scale(at: time) - initialZoom.scale(at: time + 1.5)) < 0.000000001,
                      "片段起止位置的倍率不稳定")
        }

        for fps: Int32 in [30, 60] {
            let scenarios: [(Double, [CursorSample])] = [
                (0.02, [CursorSample(time: 0, x: 0.3, y: 0.4, inside: true, clicked: true)]),
                (0.15, [CursorSample(time: 0, x: 0.3, y: 0.4, inside: true, clicked: true)]),
                (3, [CursorSample(time: 0, x: 0.3, y: 0.4, inside: true, clicked: true),
                     CursorSample(time: 0.03, x: 1.1, y: 0.4, inside: false, clicked: false)]),
                (3, [CursorSample(time: 2.9, x: 0.7, y: 0.6, inside: true, clicked: true)]),
                (6, [CursorSample(time: 0.5, x: 0.3, y: 0.4, inside: true, clicked: true),
                     CursorSample(time: 4, x: 0.7, y: 0.6, inside: true, clicked: true)])
            ]
            for (duration, samples) in scenarios {
                for automatic in ProjectStore.automaticZooms(trace: CursorTrace(samples: samples), duration: duration, fps: fps) {
                    try checkSegment(automatic, label: "自动\(fps)fps/\(duration)s")
                }
            }
        }
        print("PASS curve math: strict four-point timing, nonzero smooth ramps, exact nodes, dense monotone samples, amplitude drags, degenerate repair and partial-cut boundaries")
    }

    private static func checkUnchangedAutosave(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("已保存工程重复保存", isDirectory: true)
        let movedFolder = directory.appendingPathComponent("已保存工程外部移动", isDirectory: true)
        let project = try ProjectStore.create(directory: folder, rawURL: source,
            trace: CursorTrace(samples: []), fps: 30, quality: .hevc, duration: duration,
            pixelSize: CGSize(width: 640, height: 360), autoZoomEnabled: false)
        let model = EditorModel()
        try await model.loadProject(folder: folder)
        let saved = try Data(contentsOf: project.jsonURL)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: project.jsonURL.path)
        try model.autosave()
        let attributes = try FileManager.default.attributesOfItem(atPath: project.jsonURL.path)
        try check(attributes[.modificationDate] as? Date == timestamp && Data(contentsOf: project.jsonURL) == saved,
                  "未修改的工程不应重复写入参数文件")

        try FileManager.default.moveItem(at: folder, to: movedFolder)
        try model.autosave()
        try check(!FileManager.default.fileExists(atPath: folder.path) &&
                  Data(contentsOf: movedFolder.appendingPathComponent("project.json")) == saved,
                  "已保存工程被外部移动后重复保存不应报错、重建旧目录或改动工程")

        model.fps = 60; model.quality = .proRes
        var saveFailed = false
        do { try model.autosave() } catch { saveFailed = true }
        try check(saveFailed && !FileManager.default.fileExists(atPath: folder.path),
                  "旧工程确有未保存修改时必须保留失败，不能吞错或重建失效目录")
        try FileManager.default.moveItem(at: movedFolder, to: folder)
        try model.autosave()
        let retried = try ProjectStore.load(folder: folder)
        try check(retried.fps == 60 && retried.quality == .proRes && retried.clips == model.clips,
                  "失败后恢复目录并重试，必须真正保存未提交修改")
        print("PASS unchanged autosave: no redundant writes, moved saved projects do not block new work, unsaved failures remain explicit and retry persists changes")
    }

    private static func checkOverlappingLoads(olderFolder: URL, source: URL,
                                               duration: Double, directory: URL) async throws {
        let newerFolder = directory.appendingPathComponent("加载竞态-新工程", isDirectory: true)
        let newer = try ProjectStore.create(directory: newerFolder, rawURL: source,
            trace: CursorTrace(samples: []), fps: 60, quality: .proRes, duration: duration,
            pixelSize: CGSize(width: 640, height: 360))
        let model = EditorModel()
        var releaseOlder: CheckedContinuation<Void, Never>?
        var olderTask: Task<Void, Error>?
        var announced = false
        defer {
            releaseOlder?.resume()
            olderTask?.cancel()
            model.beforeProjectLoadCommit = nil
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            model.beforeProjectLoadCommit = { folder in
                guard folder == olderFolder else { return }
                await withCheckedContinuation { continuation in
                    releaseOlder = continuation
                    announced = true
                    ready.resume(returning: ())
                }
            }
            olderTask = Task {
                do { try await model.loadProject(folder: olderFolder) }
                catch {
                    if !announced { announced = true; ready.resume(throwing: error) }
                    throw error
                }
            }
        }
        try await model.loadProject(folder: newerFolder)
        let newerItem = model.player.currentItem
        model.message = "最新请求已经提交"
        releaseOlder?.resume()
        releaseOlder = nil
        do {
            try await olderTask?.value
            throw RecorderError.message("较旧的加载请求应被丢弃。")
        } catch is CancellationError {}
        try check(model.projectURL == newerFolder && model.sourceURL == newer.sourceURL &&
                  model.clips == newer.clips && model.fps == 60 && model.quality == .proRes &&
                  model.selectedZoomID == nil && model.player.currentItem === newerItem &&
                  model.message == "最新请求已经提交", "旧的异步加载覆盖了较新的工程或预览")
        print("PASS overlapping project loads: delayed old request cannot replace newer document, selection, format, message or player")
    }

    private static func checkFramingPaths() throws {
        let trace = [ZoomCenterPoint(time: -1, x: 0.4, y: 0.5),
            ZoomCenterPoint(time: 0.5, x: 0.45, y: 0.55),
            ZoomCenterPoint(time: 2, x: 0.6, y: 0.5),
            ZoomCenterPoint(time: 4, x: 0.55, y: 0.4),
            ZoomCenterPoint(time: 7, x: 0.5, y: 0.5)]
        let original = ZoomSegment(start: -1, riseEnd: 0.5, fallStart: 5, end: 7, peak: 2,
                                   centerPath: trace)
        let leftBoundary = original.cameraControlPoints.last(where: { $0.time < 3 })!.time
        let rightBoundary = original.cameraControlPoints.first(where: { $0.time > 3 })!.time
        var automatic = original
        automatic.setFramingCenter(x: 4, y: -3, at: 3)
        try check(automatic.centerPath == trace &&
                  automatic.centerOffsets?.contains(where: { abs($0.time - 3) < 0.000001 }) == true && !automatic.manualFocus,
                  "编辑单个中心点丢失了原轨迹或把整段变成固定焦点")
        try check(automatic.pose(at: 3).x == 0.75 && automatic.pose(at: 3).y == 0.25,
                  "取景框没有限制在完整原画内")
        for time in stride(from: -1.0, through: 7.0, by: 0.1) where time <= leftBoundary || time >= rightBoundary {
            let before = original.pose(at: time), after = automatic.pose(at: time)
            try check(abs(before.x - after.x) < 0.0000001 && abs(before.y - after.y) < 0.0000001 &&
                      abs(before.scale - after.scale) < 0.0000001, "局部中心编辑修改了相邻关键点之外的轨迹")
        }
        try check(automatic.start == -1 && automatic.end == 7 && automatic.centerPath.first?.time == -1 &&
                  automatic.centerPath.last?.time == 7, "切片的片外路径或缓动域被裁掉")

        let manual = ZoomSegment(start: -1, riseEnd: 1, fallStart: 4, end: 7, peak: 2,
                                 focusX: 0.63, focusY: 0.38, centerPath: trace, manualFocus: true)
        var edited = manual
        edited.setFramingCenter(x: manual.focusX, y: manual.focusY, at: manual.riseEnd)
        for time in stride(from: -1.0, through: 7, by: 0.025) {
            let before = manual.pose(at: time), after = edited.pose(at: time)
            try check(abs(before.x - after.x) < 0.000000001 && abs(before.y - after.y) < 0.000000001 &&
                      before.scale == after.scale, "手动中心转稀疏路径改变了原始缓动")
        }
        edited.setFramingCenter(x: 0.42, y: 0.58, at: 2.5)
        try check(edited.centerPath == trace && edited.manualCenterPath?.count == 5,
                  "手动取景编辑覆盖了原指针轨迹或未保留阶段点")
        let shifted = edited.shifted(by: -2)
        for time in stride(from: 0.0, through: 3, by: 0.05) {
            let a = shifted.pose(at: time), b = edited.pose(at: time + 2)
            try check(abs(a.scale - b.scale) < 0.000000001 && abs(a.x - b.x) < 0.000000001 &&
                      abs(a.y - b.y) < 0.000000001, "切片移动丢失了手动取景路径")
        }
        let decoded = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(edited))
        try check(decoded == edited, "取景路径未完整持久化")
        print("PASS framing paths: local keyframes, preserved pointer trace/easing domains, sparse manual conversion, bounded crop and shifted persistence")
    }

    private static func checkFramingPreview(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("取景辅助回归", isDirectory: true)
        var project = try ProjectStore.create(directory: folder, rawURL: source, trace: CursorTrace(samples: []),
            fps: 30, quality: .hevc, duration: duration, pixelSize: CGSize(width: 640, height: 360))
        let path = [ZoomCenterPoint(time: -1, x: 0.5, y: 0.5),
            ZoomCenterPoint(time: 0.5, x: 0.58, y: 0.48),
            ZoomCenterPoint(time: 2.5, x: 0.62, y: 0.45),
            ZoomCenterPoint(time: 5, x: 0.6, y: 0.5),
            ZoomCenterPoint(time: 7, x: 0.5, y: 0.5)]
        let zoom = ZoomSegment(start: -1, riseEnd: 0.5, fallStart: 5, end: 7, peak: 2, centerPath: path)
        project.clips[0].zooms = [zoom]
        project.selectedZoomID = zoom.id
        try ProjectStore.save(project)
        let beforeJSON = try Data(contentsOf: project.jsonURL)
        let model = EditorModel()
        model.beforeProjectLoadCommit = { [weak model] _ in model?.isPlaying = true }
        try await model.loadProject(folder: folder)
        model.beforeProjectLoadCommit = nil
        try check(model.isPlaying && model.player.rate > 0, "加载末尾seek未恢复较新的播放请求")
        model.isPlaying = false
        try check(!model.showsFramingOverlay && model.previewCameraEffectsEnabled && !model.isFramingPreviewReady,
                  "取景辅助未默认关闭")
        model.seek(2)
        model.setShowsFramingOverlay(true)
        model.setShowsFramingOverlay(false)
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        try check(!model.isPlaying && abs(model.playhead - 2) < 0.000001 &&
                  abs(model.player.currentTime().seconds - 2) < 0.01, "快速切换取景辅助改变了暂停位置或播放状态")
        try check(try Data(contentsOf: project.jsonURL) == beforeJSON, "仅查看取景辅助改写了工程JSON")
        model.setShowsFramingOverlay(false)
        try await waitForFraming(model, enabled: false)
        var releasePreview: CheckedContinuation<Void, Never>?
        var suspendedPreview = false
        defer {
            releasePreview?.resume()
            model.beforePreviewCommit = nil
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            model.beforePreviewCommit = { cameraEnabled in
                guard !cameraEnabled, !suspendedPreview else { return }
                suspendedPreview = true
                await withCheckedContinuation { continuation in
                    releasePreview = continuation
                    ready.resume()
                }
            }
            model.setShowsFramingOverlay(true)
        }
        model.seek(2.25)
        model.setShowsFramingOverlay(false)
        releasePreview?.resume()
        releasePreview = nil
        try await waitForFraming(model, enabled: false)
        try check(abs(model.playhead - 2.25) < 0.000001, "旧取景构建覆盖了较新的seek位置")
        model.beforePreviewCommit = nil
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        try check(try Data(contentsOf: project.jsonURL) == beforeJSON, "丢弃过时的取景预览修改了工程JSON")
        guard let state = model.framingState else { throw RecorderError.message("取景辅助没有生成可编辑状态。") }
        try check(state.canEdit && !state.handles.isEmpty && state.pathSamples.count >= state.handles.count &&
                  state.pose == model.activePose && state.normalizedRect.minX >= 0 && state.normalizedRect.maxX <= 1,
                  "取景辅助几何或稀疏控制点无效")
        for handle in state.handles {
            try check(state.pathSamples.contains(where: { abs($0.time - handle.time) < 0.000001 &&
                abs($0.x - handle.x) < 0.000001 && abs($0.y - handle.y) < 0.000001 }),
                "自动轨迹绘线漏过了实际显示节点")
        }

        let originalClips = model.clips
        let originalPose = model.activePose
        let originalPlayerItem = model.player.currentItem
        var resizingID: UUID?
        model.beginFramingEditing()
        for scale in [1.0, 2.4, 1.05, 2.7, 1.0, 2.4] {
            model.updateFramingScale(scale)
            let value = model.activePose, margin = 0.5 / scale
            try check(abs(value.scale - scale) < 1e-8 &&
                      abs(value.x - min(1 - margin, max(margin, originalPose.x))) < 1e-8 &&
                      abs(value.y - min(1 - margin, max(margin, originalPose.y))) < 1e-8,
                      "反复缩放取景框时中心逐渐漂移")
            let point = model.selectedZoom!.cameraControlPoints.first { abs($0.time - model.activeLocalTime) < 1e-6 }!
            if let resizingID { try check(point.id == resizingID, "同次缩放拖动反复替换倍率节点身份") }
            resizingID = point.id
        }
        model.endEditing()
        try check(model.player.currentItem === originalPlayerItem && (model.selectedZoom?.localCenterEdits?.count ?? 0) <= 1,
                  "一次反复缩放替换了原片播放器或累积多个修正")
        model.undo()
        try check(model.clips == originalClips && !model.canUndo, "反复缩放未由一次撤销恢复")
        model.beginFramingEditing()
        model.updateFramingScale(1)
        model.updateFramingScale(2.8)
        model.updateFramingScale(originalPose.scale)
        model.endEditing()
        try check(model.clips == originalClips && !model.canUndo,
                  "取景框缩放后拖回原位留下了修改或多余撤销记录")
        print("PASS framing resize gestures: original-center recovery across full view, stable node identity, one correction/Undo, exact drag-back cancellation and raw player retention")
        let framingPlayerItem = model.player.currentItem
        model.beginEditing()
        model.updateFramingCenter(x: 0.67, y: 0.39)
        model.updateFramingCenter(x: 0.7, y: 0.4)
        model.endEditing()
        try check(model.player.currentItem === framingPlayerItem,
                  "仅拖动取景框不应替换原片播放器内容")
        let edited = model.clips
        try check(model.selectedZoom?.localCenterEdits?.count == 1 &&
                  model.selectedZoom?.cameraKeyframes == originalClips.first?.zooms.first?.cameraKeyframes,
                  "一次拖框生成多个修正记录，或改变了倍率锚点")
        try check(edited != originalClips && model.selectedZoom?.manualFocus == false &&
                  path.allSatisfy { model.selectedZoom?.centerPath.contains($0) == true },
                  "拖动当前框替换了已有自动路径")
        try check(try ProjectStore.load(folder: folder).clips == edited, "取景拖动未自动保存")
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == edited, "重开未恢复取景路径")
        let localDocument = try ProjectStore.load(folder: folder)
        let originalTimeline = try await ProjectExporter.buildTimeline(project: project)
        let localTimeline = try await ProjectExporter.buildTimeline(project: localDocument)
        let oldFrames = AVAssetImageGenerator(asset: originalTimeline.asset)
        oldFrames.videoComposition = originalTimeline.videoComposition
        let newFrames = AVAssetImageGenerator(asset: localTimeline.asset)
        newFrames.videoComposition = localTimeline.videoComposition
        let localOutput = directory.appendingPathComponent("局部取景修正导出.mov")
        try await model.export(to: localOutput)
        let outputFrames = AVAssetImageGenerator(asset: AVURLAsset(url: localOutput))
        func meanRed(_ image: CGImage) throws -> Double {
            var pixels = [UInt8](repeating: 0, count: 32 * 18 * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 18,
                    bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw RecorderError.message("不能读取局部取景导出像素")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
            }
            return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / (32 * 18)
        }
        for time in [0.5, 2.25, 4.75] {
            let stamp = CMTime(seconds: time, preferredTimescale: 600)
            let before = try meanRed(try await oldFrames.image(at: stamp).image)
            let expected = try meanRed(try await newFrames.image(at: stamp).image)
            let actual = try meanRed(try await outputFrames.image(at: stamp).image)
            try check(abs(actual - expected) < 5, "实际导出未应用与预览一致的局部取景修正")
            try check(time == 2.25 ? abs(expected - before) > 3 : abs(expected - before) < 0.1,
                      "局部取景未改变目标时刻，或误改了影响区间外的实际视频帧")
        }
        print("PASS local framing video: persisted/reopened single correction, actual exported pixels match preview and outside-window frames stay unchanged")
        model.seek(3.25)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.undo()
        try check(model.clips == originalClips && !model.canUndo && model.showsFramingOverlay,
                  "一个取景拖动未由一次Undo恢复，或Undo改变了查看开关")
        try check(model.player.currentItem === framingPlayerItem,
                  "撤销取景移动不应替换原片播放器内容")
        for _ in 0..<100 {
            if abs(model.player.currentTime().seconds - 2.25) < 0.01 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(abs(model.playhead - 2.25) < 0.000001 && abs(model.player.currentTime().seconds - 2.25) < 0.01,
                  "撤销取景编辑后播放头与实际视频时间不同步")
        try await waitForFraming(model, enabled: true)

        model.togglePlayback()
        let playingTime = model.playhead
        model.toggleFramingOverlay()
        model.toggleFramingOverlay()
        model.toggleFramingOverlay()
        try await waitForFraming(model, enabled: false)
        try check(model.isPlaying && model.playhead >= playingTime - 0.05 && model.playhead < playingTime + 2,
                  "播放中切换取景辅助暂停或跳转了播放头")
        model.isPlaying = false

        let raw = try await ProjectExporter.buildTimeline(project: project, cameraEffectsEnabled: false)
        let rendered = try await ProjectExporter.buildTimeline(project: project)
        let rawGenerator = AVAssetImageGenerator(asset: raw.asset)
        rawGenerator.videoComposition = raw.videoComposition
        let renderGenerator = AVAssetImageGenerator(asset: rendered.asset)
        renderGenerator.videoComposition = rendered.videoComposition
        let rawFrame = try await rawGenerator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
        let renderedFrame = try await renderGenerator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
        try check(raw.size == CGSize(width: 640, height: 360) && rawFrame.width == 640 && rawFrame.height == 360 &&
                  renderedFrame.width == rawFrame.width && renderedFrame.height == rawFrame.height &&
                  (rawFrame.dataProvider?.data as Data?) != (renderedFrame.dataProvider?.data as Data?),
                  "辅助预览改变了原画尺寸，或导出组合没有真实摄像机效果")
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        let destination = directory.appendingPathComponent("取景开启时导出.mov")
        try await model.export(to: destination)
        let exportedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        let exportedFrame = try await exportedGenerator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
        let rawSpan = try horizontalRedSpan(rawFrame)
        let renderedSpan = try horizontalRedSpan(renderedFrame)
        let exportedSpan = try horizontalRedSpan(exportedFrame)
        try check(model.showsFramingOverlay && model.isFramingPreviewReady &&
                  exportedFrame.width == rawFrame.width && exportedFrame.height == rawFrame.height &&
                  rawSpan > 40 && renderedSpan < rawSpan * 0.7 && exportedSpan < rawSpan * 0.7 &&
                  abs(exportedSpan - renderedSpan) < 8,
                  "开启辅助层时真实导出遗漏了摄像机效果，或辅助图形进入了输出")
        let early = ZoomSegment(start: 0.1, riseEnd: 0.2, fallStart: 1, end: 1.4, peak: 1.5)
        let late = ZoomSegment(start: 1.6, riseEnd: 1.8, fallStart: 2.7, end: 2.9, peak: 2)
        let next = ZoomSegment(start: 0.1, riseEnd: 0.3, fallStart: 2.5, end: 2.9, peak: 1.8)
        let firstClip = DemoClip(title: "播放前片", sourceStart: 0, duration: 3, zooms: [early, late])
        let nextClip = DemoClip(title: "播放后片", sourceStart: 3, duration: duration - 3, zooms: [next])
        model.clips = [firstClip, nextClip]
        model.selectedClipID = firstClip.id; model.selectedZoomID = early.id
        model.seek(2.2); model.isPlaying = true
        try check(model.framingState?.zoomID == late.id && model.framingState?.pose == model.activePose &&
                  model.framingState?.canEdit == false, "同片播放未跟随当前放大段的轨迹")
        model.seek(4)
        try check(model.framingState?.clipID == nextClip.id && model.framingState?.zoomID == next.id &&
                  model.framingState?.pose == model.activePose && model.framingState?.canEdit == false,
                  "跨片播放丢失了只读取景框或采用错误轨迹")
        model.isPlaying = false
        for (time, targetClip, targetZoom) in [(2.2, firstClip, late), (4.0, nextClip, next)] {
            let before = [firstClip, nextClip]
            model.clips = before
            model.selectedClipID = firstClip.id; model.selectedZoomID = early.id
            model.seek(time)
            try check(model.framingState?.zoomID == targetZoom.id && model.framingState?.canEdit == true &&
                      model.selectedZoomID == early.id, "旧选择挡住了当前画面的取景拖动，或仅查看就改了选择")
            let pose = model.activePose
            model.beginEditing()
            model.updateFramingCenter(x: pose.x + 0.03, y: pose.y - 0.025)
            model.updateFramingCenter(x: pose.x + 0.06, y: pose.y - 0.05)
            model.endEditing()
            let after = model.clips
            try check(model.selectedClipID == targetClip.id && model.selectedZoomID == targetZoom.id &&
                      after != before, "未选中当前段时拖框没有编辑并选中实际目标")
            for clip in before {
                guard let actual = after.first(where: { $0.id == clip.id }) else {
                    throw RecorderError.message("取景拖动丢失片段。")
                }
                try check(actual.zooms.filter { $0.id != targetZoom.id } == clip.zooms.filter { $0.id != targetZoom.id },
                          "取景拖动修改了其他放大段")
            }
            let changed = after.first(where: { $0.id == targetClip.id })!.zooms.first(where: { $0.id == targetZoom.id })!
            try check(changed.pose(at: model.activeLocalTime) != targetZoom.pose(at: model.activeLocalTime),
                      "取景拖动没有改变播放头处的实际中心")
            try check(try ProjectStore.load(folder: folder).clips == after, "跨选择取景拖动未保存")
            let reopenedAfterDrag = EditorModel()
            try await reopenedAfterDrag.loadProject(folder: folder)
            try check(reopenedAfterDrag.clips == after && reopenedAfterDrag.selectedZoomID == targetZoom.id,
                      "重新打开未保留取景拖动及目标选择")
            model.undo()
            try check(model.clips == before && model.selectedClipID == firstClip.id &&
                      model.selectedZoomID == early.id && abs(model.playhead - time) < 0.000001,
                      "一次撤销未恢复取景拖动前的内容、旧选择和播放头")
            try await waitForFraming(model, enabled: true)
        }
        model.seek(1.5)
        let beforeFullView = model.clips
        try check(model.framingState?.pose.scale == 1 && model.framingState?.canEdit == false,
                  "全景取景框不应允许无效平移")
        model.beginEditing(); model.updateFramingCenter(x: 0.7, y: 0.3); model.endEditing()
        try check(model.clips == beforeFullView, "全景拖动误改工程")
        var overlapping = firstClip
        let stronger = ZoomSegment(start: 0.1, riseEnd: 0.3, fallStart: 1, end: 1.4, peak: 2.4)
        overlapping.zooms.append(stronger)
        model.clips = [overlapping, nextClip]
        model.selectedClipID = firstClip.id; model.selectedZoomID = early.id
        model.seek(0.7)
        try check(model.framingState?.zoomID == early.id && model.framingState?.canEdit == true,
                  "重叠放大时丢弃了用户选中的有效编辑目标")
        model.clips = originalClips
        print("PASS framing preview: default off, rapid paused/playing toggles preserve player state and JSON, stale same/across-clip selections allow current-frame drag with autosave/reopen/one Undo, full-view guard, overlap selection and real camera-rendered export")
    }

    private static func checkAutomaticMotionEditing(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("自动轨迹编辑回归", isDirectory: true)
        let trace = CursorTrace(samples: [CursorSample(time: 1, x: 0.4, y: 0.6, inside: true, clicked: true)])
        var project = try ProjectStore.create(directory: folder, rawURL: source, trace: trace, fps: 30,
            quality: .hevc, duration: duration, pixelSize: CGSize(width: 640, height: 360), autoZoomEnabled: false)
        let path = (0...150).map { index -> ZoomCenterPoint in
            let time = Double(index) / 30
            let phase = (time - 1) * 2 * .pi / 3
            return ZoomCenterPoint(time: time, x: 0.5 + 0.12 * cos(phase), y: 0.5 + 0.1 * sin(phase))
        }
        let zoom = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.8, centerPath: path).normalized()
        project.clips[0].zooms = [zoom]
        project.selectedZoomID = zoom.id
        try ProjectStore.save(project)
        let raw = try Data(contentsOf: project.sourceURL)
        let json = try Data(contentsOf: project.jsonURL)
        let model = EditorModel()
        try await model.loadProject(folder: folder)
        model.seek(2.117)
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        try check(try Data(contentsOf: project.jsonURL) == json, "仅查看自动路线改写了工程")
        func checkVisiblePoints() throws {
            guard let state = model.framingState, let active = model.selectedZoom else {
                throw RecorderError.message("自动路线未生成取景节点。")
            }
            try check(state.handles.count == active.cameraControlPoints.count && state.pose == model.activePose,
                      "预览节点与下方倍率节点不同步，或取景框没有使用实际播放姿态")
            for handle in state.handles {
                try check(active.cameraControlPoints.contains(where: { abs($0.time - handle.time) < 0.000001 }) &&
                          state.pathSamples.contains(where: { abs($0.time - handle.time) < 0.000001 &&
                              abs($0.x - handle.x) < 0.000001 && abs($0.y - handle.y) < 0.000001 }),
                          "密集自动轨迹的圆点脱离虚线，或显示了并非真实控制点的采样点")
            }
        }
        try checkVisiblePoints()
        let before = model.clips
        let item = model.player.currentItem
        let pose = model.activePose
        model.beginEditing()
        model.updateFramingKeyframe(time: 2.117, x: pose.x + 0.03, y: pose.y - 0.025)
        model.endEditing()
        try checkVisiblePoints()
        let edited = model.clips
        try check(edited != before && model.selectedZoom!.centerPath == path && model.player.currentItem === item &&
                  abs(model.activePose.x - pose.x - 0.03) < 0.0000001 &&
                  abs(model.activePose.y - pose.y + 0.025) < 0.0000001,
                  "密集自动路线编辑没有修改实际取景位置，或覆盖了基底/重载了播放器")
        let saved = try ProjectStore.load(folder: folder)
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(saved.clips == edited && reopened.clips == edited &&
                  (try Data(contentsOf: saved.sourceURL)) == raw && saved.trace.samples.count == trace.samples.count &&
                  saved.trace.samples[0].x == trace.samples[0].x,
                  "自动路线编辑没有保存重开，或改变了原片与鼠标记录")
        model.selectFramingAnchor(at: 2.117)
        let beforeDeletion = model.selectedZoom!
        let deletingIndex = beforeDeletion.cameraControlPoints.firstIndex { abs($0.time - 2.117) < 0.000001 }!
        let lower = beforeDeletion.cameraControlPoints[deletingIndex - 1].time
        let upper = beforeDeletion.cameraControlPoints[deletingIndex + 1].time
        try check(model.selectedCameraAnchorIDs.count == 1 && model.canDeleteSelection && model.deleteSelected() &&
                  model.clips.count == before.count && model.selectedZoom!.centerPath == path,
                  "自动路线节点选择或删除失败，或误改素材/原始路线")
        let startCenter = beforeDeletion.pose(at: lower), endCenter = beforeDeletion.pose(at: upper)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.02) {
            let center = model.selectedZoom!.pose(at: lower + (upper - lower) * fraction)
            try check(abs((center.x - startCenter.x) * (endCenter.y - startCenter.y) -
                          (center.y - startCenter.y) * (endCenter.x - startCenter.x)) < 0.0000001,
                      "模型删除节点后没有直线连接幸存节点")
        }
        try check((try ProjectStore.load(folder: folder).clips) == model.clips, "删除后的直线平移未自动保存")
        model.undo()
        try check(model.clips == edited && model.selectedCameraAnchorIDs.count == 1,
                  "自动路线节点删除未由一次撤销恢复修改及选择")
        try checkVisiblePoints()
        model.undo()
        try check(model.clips == before && model.player.currentItem === item &&
                  (try ProjectStore.load(folder: folder).clips) == before,
                  "一次轨迹拖动未完整撤销并保存，或重载了原片")
        model.setShowsFramingOverlay(false)
        try await waitForFraming(model, enabled: false)
        let beforeNavigation = try Data(contentsOf: project.jsonURL)
        let canUndoBeforeNavigation = model.canUndo
        model.seek(2.117)
        let nextTime = model.cameraNavigationTimes.first { $0 > model.playhead + 0.000001 }!
        try check(model.navigateCameraTarget(forward: true) && abs(model.playhead - nextTime) < 0.000001 &&
                  model.clips == before && model.canUndo == canUndoBeforeNavigation &&
                  (try Data(contentsOf: project.jsonURL)) == beforeNavigation,
                  "导航修改了编辑数据、撤销历史或工程文件")
        print("PASS automatic motion editing: dense circular preview/curve identity, exact visible handles, raw player retention, original media/trace, persisted offsets, node delete and single-gesture Undo")
    }

    private static func checkCameraAnchorEditing(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("取景锚点回归", isDirectory: true)
        let trace = CursorTrace(samples: [CursorSample(time: 1, x: 0.4, y: 0.6, inside: true, clicked: true)])
        var project = try ProjectStore.create(directory: folder, rawURL: source, trace: trace, fps: 30,
            quality: .hevc, duration: duration, pixelSize: CGSize(width: 640, height: 360), autoZoomEnabled: false)
        let zoom = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6,
            focusX: 0.56, focusY: 0.46, manualFocus: true)
        project.clips[0].zooms = [zoom]
        project.selectedZoomID = zoom.id
        try ProjectStore.save(project)
        let model = EditorModel()
        try await model.loadProject(folder: folder)
        model.seek(2)
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        let playerItem = model.player.currentItem
        try check(model.canAddFramingAnchor, "没有启用当前取景锚点添加")
        model.addFramingAnchor()
        let initialControls = model.selectedZoom!.cameraControlPoints
        try check(initialControls.count == 5 && model.player.currentItem === playerItem, "添加锚点没有保留原画预览或控制点")
        for time in stride(from: 0.0, through: 5.0, by: 0.01) {
            let before = zoom.pose(at: time), after = model.selectedZoom!.pose(at: time)
            try check(abs(before.scale - after.scale) < 0.0000001 && abs(before.x - after.x) < 0.0000001 && abs(before.y - after.y) < 0.0000001,
                      "添加锚点改变了未编辑的镜头")
        }
        model.addFramingAnchor()
        try check(model.selectedZoom!.cameraControlPoints == initialControls, "同一帧重复添加创建了多余锚点")
        for (time, scale) in [(2.0, 1.3), (3.0, 2.0), (3.5, 1.0)] {
            model.seek(time)
            model.addFramingAnchor()
            model.beginEditing(); model.updateFramingScale(scale); model.endEditing()
            try check(abs(model.activePose.scale - scale) < 0.0000001, "取景框大小没有同步到对应锚点倍率")
        }
        try check(model.framingState?.canResize == true && model.framingState?.canEdit == false,
                  "中间全景锚点必须支持重新放大而不允许无效平移")
        let beforeRaising = model.clips
        model.beginEditing(); model.updateFramingScale(1.8); model.endEditing()
        try check(abs(model.activePose.scale - 1.8) < 0.0000001, "全景锚点不能重新缩小取景框")
        model.undo()
        try check(model.clips == beforeRaising && model.activePose.scale == 1, "全景锚点大小修改未由一次撤销恢复")
        let edited = model.clips
        try check(model.framingState?.handles.count == 7, "编辑锚点被旧版五点展示上限隐藏")
        for control in model.selectedZoom!.cameraControlPoints {
            let pose = model.selectedZoom!.pose(at: control.time)
            try check(model.framingState!.pathSamples.contains(where: {
                abs($0.time - control.time) < 0.000001 && abs($0.x - pose.x) < 0.000001 && abs($0.y - pose.y) < 0.000001
            }), "取景轨迹抽样漏过精确锚点，导致控制点脱离路径")
        }
        let saved = try ProjectStore.load(folder: folder)
        try check(saved.clips == edited && saved.trace.samples.count == trace.samples.count &&
                  saved.trace.samples[0].x == trace.samples[0].x, "锚点编辑未持久化或改写了原始鼠标记录")
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == edited && reopened.selectedZoom?.cameraControlPoints.count == 7,
                  "重开未恢复全部取景与倍率锚点")
        model.seek(2)
        let moving = model.selectedZoom!.cameraControlPoints.first { abs($0.time - 2) < 0.000001 }!
        model.beginEditing()
        model.updateCameraAnchor(id: moving.id, time: 2.25, scale: 1.4)
        model.endEditing()
        try check(abs(model.playhead - 2.25) < 0.000001 && abs(model.activePose.scale - 1.4) < 0.000001 &&
                  model.player.currentItem === playerItem, "下方锚点编辑没有同步取景时间和倍率，或重载了原片")
        model.undo()
        try check(model.clips == edited && abs(model.playhead - 2) < 0.000001, "一次撤销未恢复曲线锚点与播放时间")

        let destination = directory.appendingPathComponent("多段倍率锚点.mov")
        try await model.export(to: destination)
        let actual = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        actual.requestedTimeToleranceBefore = .zero
        actual.requestedTimeToleranceAfter = .zero
        let rawTimeline = try await ProjectExporter.buildTimeline(project: saved, cameraEffectsEnabled: false)
        let raw = AVAssetImageGenerator(asset: rawTimeline.asset)
        raw.videoComposition = rawTimeline.videoComposition
        raw.requestedTimeToleranceBefore = .zero
        raw.requestedTimeToleranceAfter = .zero
        for (time, expectedScale) in [(2.0, 1.3), (3.0, 2.0), (3.5, 1.0)] {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let a = try await actual.image(at: cmTime), b = try await raw.image(at: cmTime)
            try check(abs(a.actualTime.seconds - time) < 0.034,
                      "锚点导出验证没有采样到指定视频帧")
            let ratio = try horizontalRedSpan(a.image) / horizontalRedSpan(b.image)
            try check(abs(ratio - 1 / expectedScale) < 0.1,
                      "真实导出视频没有按多段锚点显示不同倍率：时间\(time)，实际\(a.actualTime.seconds)，倍率\(expectedScale)，像素梯度比\(ratio)")
        }
        model.seek(2.5)
        let beforeCut = model.clips
        try check(model.split(), "多段锚点剪切失败")
        let right = model.clips[1]
        for time in stride(from: 0.0, through: right.duration, by: 0.019) {
            let a = beforeCut[0].pose(at: time + 2.5), b = right.pose(at: time)
            try check(abs(a.scale - b.scale) < 0.0000001 && abs(a.x - b.x) < 0.0000001 && abs(a.y - b.y) < 0.0000001,
                      "剪切后多段锚点摄像机跳变")
        }
        model.undo()
        try check(model.clips == beforeCut, "多段锚点剪切撤销未恢复")
        model.resetZoom()
        try check(model.clips[0].zooms.isEmpty, "减号未移除整个多段放大段")
        model.undo()
        try check(model.clips == beforeCut, "多段放大移除未由一次撤销恢复")
        var bounded = ZoomSegment(start: 1, riseEnd: 1.5, fallStart: 3.5, end: 4, peak: 1.6, manualFocus: true)
        _ = bounded.addCameraKeyframe(at: 2)
        bounded = bounded.normalized()
        let left = ZoomSegment(start: 0, riseEnd: 0.2, fallStart: 0.6, end: 0.8, peak: 1.6)
        let rightNeighbor = ZoomSegment(start: 4.2, riseEnd: 4.5, fallStart: 5.5, end: 5.8, peak: 1.6)
        var boundsClip = beforeCut[0]
        boundsClip.zooms = [left, bounded, rightNeighbor]
        model.clips = [boundsClip]
        model.selectedClipID = boundsClip.id; model.selectedZoomID = bounded.id
        model.updateCameraAnchor(id: bounded.cameraControlPoints.first!.id, time: 0, scale: 1)
        model.updateCameraAnchor(id: bounded.cameraControlPoints.last!.id, time: duration, scale: 1)
        try check(model.selectedZoom!.start == 0.8 && model.selectedZoom!.end == 4.2,
                  "拖动多段曲线两端创建了与邻段的新重叠")
        let stronger = ZoomSegment(start: 0.5, riseEnd: 1, fallStart: 4.5, end: 5, peak: 2, focusX: 0.5, focusY: 0.5, manualFocus: true)
        boundsClip.zooms = [bounded, stronger]
        model.clips = [boundsClip]
        model.selectedClipID = boundsClip.id; model.selectedZoomID = bounded.id
        model.seek(2)
        let beforeShadowedResize = model.clips
        model.beginEditing(); model.updateFramingScale(1.1); model.endEditing()
        try check(model.activePose.scale == 2 && model.clips == beforeShadowedResize &&
                  model.framingState?.minimumResizeScale == 2 && model.message.contains("重叠"),
                  "被更强镜头覆盖时，无法缩小的取景拖动偷偷修改了较弱镜头")
        var dominant = bounded
        let peakPoint = dominant.cameraControlPoints.first { abs($0.time - 2) < 0.000001 }!
        dominant.updateCameraKeyframe(id: peakPoint.id, time: 2, scale: 3)
        boundsClip.zooms = [dominant.normalized(), stronger]
        model.clips = [boundsClip]
        model.seek(2)
        model.beginEditing(); model.updateFramingScale(1.1); model.endEditing()
        try check(model.activePose.scale == 2 && model.selectedZoom!.scale(at: 2) == 2,
                  "当前主导镜头不能缩小到其他重叠段允许的倍率")
        print("PASS camera anchor editing: current-frame add/dedup, resize and independent amplitudes, interior full-view resize, all handles, same raw player, saved trace/reopen/Undo, real exported scale ratios and cut continuity")
    }

    private static func checkCameraAnchorBatchEditing(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("批量取景锚点回归", isDirectory: true)
        let trace = CursorTrace(samples: [CursorSample(time: 1, x: 0.41, y: 0.59, inside: true, clicked: true)])
        var project = try ProjectStore.create(directory: folder, rawURL: source, trace: trace, fps: 30,
            quality: .hevc, duration: duration, pixelSize: CGSize(width: 640, height: 360), autoZoomEnabled: false)
        var zoom = ZoomSegment(start: 0, riseEnd: 1, fallStart: 4, end: 5, peak: 1.6,
            focusX: 0.56, focusY: 0.46, manualFocus: true)
        let lower = zoom.addCameraKeyframe(at: 2)!
        zoom.updateCameraKeyframe(id: lower.id, time: 2, scale: 1.3)
        let higher = zoom.addCameraKeyframe(at: 3)!
        zoom.updateCameraKeyframe(id: higher.id, time: 3, scale: 2.2)
        zoom.setFramingCenter(x: 0.55, y: 0.46, at: 2.5)
        zoom = zoom.normalized()
        project.clips[0].zooms = [zoom]
        project.selectedZoomID = zoom.id
        try ProjectStore.save(project)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let originalTrace = try encoder.encode(project.trace)
        let originalRaw = try Data(contentsOf: project.sourceURL)
        let model = EditorModel()
        try await model.loadProject(folder: folder)
        model.seek(2)
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        let item = model.player.currentItem
        let before = model.clips
        let ids: Set<UUID> = [lower.id, higher.id]
        model.beginEditing()
        model.dragCameraAnchors(from: zoom, ids: ids, timeDelta: 0, scaleDelta: 0.2, snapTolerance: 0)
        model.dragCameraAnchors(from: zoom, ids: ids, timeDelta: 0, scaleDelta: 10, snapTolerance: 0)
        model.endEditing()
        let changed = model.clips
        try check(abs(model.selectedZoom!.scale(at: 2) - 2.1) < 0.0000001 && model.selectedZoom!.scale(at: 3) == 3 &&
                  model.selectedZoom!.cameraControlPoints.map(\.time) == zoom.cameraControlPoints.map(\.time) &&
                  model.selectedZoom!.manualCenterPath == zoom.manualCenterPath && abs(model.playhead - 2) < 0.0000001,
                  "批量倍率拖动没有保留节点之间的倍率差、时间、已编辑路径或播放位置")
        try check(model.player.currentItem === item && model.canUndo, "批量倍率拖动重新加载了原画或没有记录单次撤销")
        let saved = try ProjectStore.load(folder: folder)
        try check(saved.clips == changed && (try encoder.encode(saved.trace)) == originalTrace &&
                  (try Data(contentsOf: project.sourceURL)) == originalRaw, "批量倍率编辑未保存，或覆盖了轨迹和原片")
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == changed, "重开未恢复批量调整后的独立倍率")
        model.undo()
        try check(model.clips == before && !model.canUndo && model.player.currentItem === item &&
                  (try ProjectStore.load(folder: folder).clips) == before, "一个批量手势不能由一次撤销完整恢复")
        let mixedIDs: Set<UUID> = [zoom.cameraControlPoints.first!.id, lower.id]
        let originalCenter = zoom.pose(at: 2)
        model.beginEditing()
        model.dragCameraAnchors(from: zoom, ids: mixedIDs, timeDelta: 0.1, scaleDelta: 0.1, snapTolerance: 0)
        model.dragCameraAnchors(from: zoom, ids: mixedIDs, timeDelta: 0.25, scaleDelta: 0.2, snapTolerance: 0)
        model.endEditing()
        let moved = model.clips
        let movedZoom = model.selectedZoom!
        try check(abs(movedZoom.start - 0.25) < 0.0000001 && movedZoom.cameraControlPoints.first!.scale == 1 &&
                  abs(movedZoom.cameraControlPoints.first { $0.id == lower.id }!.time - 2.25) < 0.0000001 &&
                  abs(movedZoom.cameraControlPoints.first { $0.id == lower.id }!.scale - 1.5) < 0.0000001 &&
                  abs(movedZoom.pose(at: 2.25).x - originalCenter.x) < 0.0000001 &&
                  abs(movedZoom.pose(at: 2.25).y - originalCenter.y) < 0.0000001,
                  "混合框选组没有同步保存时间、倍率和取景中心，或抬升了1×端点")
        try check(model.player.currentItem === item && (try ProjectStore.load(folder: folder).clips) == moved &&
                  (try encoder.encode(ProjectStore.load(folder: folder).trace)) == originalTrace &&
                  (try Data(contentsOf: project.sourceURL)) == originalRaw,
                  "混合框选组时间平移未保存，或替换了原片/轨迹/播放器")
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == moved, "重开工程没有恢复端点组的共同时间位移")
        model.undo()
        try check(model.clips == before && !model.canUndo && model.player.currentItem === item &&
                  (try ProjectStore.load(folder: folder).clips) == before, "一次撤销未恢复端点组时间平移")
        model.beginEditing()
        model.dragCameraAnchors(from: zoom, ids: [UUID()], timeDelta: 1, scaleDelta: 1, snapTolerance: 0.1)
        model.endEditing()
        try check(model.clips == before && !model.canUndo, "失效锚点选择制造了空修改或撤销记录")
        print("PASS camera anchor batch persistence: shared bounded delta preserves amplitudes/times/edited centers, one gesture/Undo, raw player identity, autosave/reopen and original media/trace retained")
    }

    private static func checkCameraAnchorDeletion(source: URL, duration: Double, directory: URL) async throws {
        let folder = directory.appendingPathComponent("取景节点删除回归", isDirectory: true)
        let trace = CursorTrace(samples: [CursorSample(time: 1, x: 0.4, y: 0.6, inside: true, clicked: true)])
        var project = try ProjectStore.create(directory: folder, rawURL: source, trace: trace, fps: 30,
            quality: .hevc, duration: duration, pixelSize: CGSize(width: 640, height: 360), autoZoomEnabled: false)
        var zoom = ZoomSegment(start: 0, riseEnd: 0.5, fallStart: 2.5, end: 3, peak: 1.6, manualFocus: true)
        let a = zoom.addCameraKeyframe(at: 1.2)!
        zoom.setFramingCenter(x: 0.58, y: 0.44, at: 1.2)
        let b = zoom.addCameraKeyframe(at: 2)!
        zoom.setFramingCenter(x: 0.6, y: 0.42, at: 2)
        zoom = zoom.normalized()
        let first = DemoClip(title: "节点编辑", sourceStart: 0, duration: 3, zooms: [zoom])
        let second = DemoClip(title: "后续素材", sourceStart: 3, duration: duration - 3, zooms: [])
        project.clips = [first, second]; project.selectedClipID = first.id; project.selectedZoomID = zoom.id
        try ProjectStore.save(project)
        let originalRaw = try Data(contentsOf: project.sourceURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let originalTrace = try encoder.encode(project.trace)
        let model = EditorModel()
        try await model.loadProject(folder: folder)
        model.seek(1.2)
        model.setShowsFramingOverlay(true)
        try await waitForFraming(model, enabled: true)
        let item = model.player.currentItem
        let original = model.clips
        try check(model.editingSelectionTarget == .cameraAnchors && !model.canDeleteSelection && !model.deleteSelected(),
                  "进入取景模式后空选择仍可删除整段素材")
        model.selectFramingAnchor(at: 1.2)
        try check(model.selectedCameraAnchorIDs == [a.id] && model.framingState?.selectedHandleTimes == [1.2] &&
                  model.canDeleteSelection && model.deleteSelected(), "预览锚点选中没有同步到删除目标和高亮")
        let changed = model.clips
        try check(model.clips.count == 2 && abs(model.totalDuration - duration) < 0.000001 &&
                  !model.selectedZoom!.cameraControlPoints.contains(where: { $0.id == a.id }) && model.player.currentItem === item,
                  "预览节点删除误删素材、改变总长或重载原画")
        let saved = try ProjectStore.load(folder: folder)
        try check(saved.clips == changed && (try encoder.encode(saved.trace)) == originalTrace &&
                  (try Data(contentsOf: project.sourceURL)) == originalRaw, "节点删除未保存或改变原片/原鼠标轨迹")
        let json = try String(contentsOf: project.jsonURL, encoding: .utf8)
        try check(!json.contains("\"editingSelectionTarget\"") && !json.contains("\"selectedCameraAnchorIDs\""),
                  "瞬时编辑焦点不应写入工程格式")
        let reopened = EditorModel()
        try await reopened.loadProject(folder: folder)
        try check(reopened.clips == changed && reopened.editingSelectionTarget == .clip && reopened.selectedCameraAnchorIDs.isEmpty,
                  "重开没有恢复删除结果，或沿用了旧界面选择")
        model.undo()
        try check(model.clips == original && model.editingSelectionTarget == .cameraAnchors &&
                  model.selectedCameraAnchorIDs == [a.id] && model.player.currentItem === item,
                  "一次撤销节点删除没有恢复内容、节点选择或原片播放器")
        let endpoints = [zoom.cameraControlPoints.first!.id, zoom.cameraControlPoints.last!.id]
        model.selectCameraAnchors(Set(endpoints), in: first.id, zoomID: zoom.id)
        let protectedJSON = try Data(contentsOf: project.jsonURL)
        try check(!model.canDeleteSelection && !model.deleteSelected() && model.clips == original &&
                  (try Data(contentsOf: project.jsonURL)) == protectedJSON, "首尾全景锚点删除意外修改了素材或工程")
        let group = Set(endpoints + [a.id, b.id])
        model.selectCameraAnchors(group, in: first.id, zoomID: zoom.id)
        try check(model.deleteSelected() && model.selectedZoom!.cameraControlPoints.count == 4 && model.clips.count == 2 &&
                  model.player.currentItem === item, "批量节点删除破坏素材或未保留边界")
        try check(try ProjectStore.load(folder: folder).clips == model.clips, "批量节点删除没有自动保存")
        model.undo()
        try check(model.clips == original && model.selectedCameraAnchorIDs == group &&
                  model.editingSelectionTarget == .cameraAnchors, "批量删除无法一次撤销并恢复多选")
        let path = [ZoomCenterPoint(time: 0, x: 0.5, y: 0.5), ZoomCenterPoint(time: 0.5, x: 0.58, y: 0.44),
            ZoomCenterPoint(time: 1.7, x: 0.63, y: 0.4), ZoomCenterPoint(time: 2.5, x: 0.58, y: 0.44),
            ZoomCenterPoint(time: 3, x: 0.5, y: 0.5)]
        let legacy = ZoomSegment(id: zoom.id, start: 0, riseEnd: 0.5, fallStart: 2.5, end: 3, peak: 1.6,
            manualFocus: true, manualCenterPath: path).normalized()
        model.setZoom(legacy, for: first.id)
        model.selectFramingAnchor(at: 1.7)
        try check(model.selectedMotionPointTime == 1.7 && model.canDeleteSelection && model.deleteSelected() &&
                  model.selectedZoom!.manualCenterPath == path && model.selectedZoom!.cameraKeyframes == nil &&
                  !model.selectedZoom!.framingKeyframes.contains(where: { abs($0.time - 1.7) < 0.000001 }) &&
                  model.clips.count == 2 && model.player.currentItem === item, "旧版预览位置节点删除失败或误删素材")
        model.undo()
        try check(model.selectedZoom == legacy && model.selectedMotionPointTime == 1.7 &&
                  model.editingSelectionTarget == .cameraAnchors, "旧版位置节点删除未恢复对应选择")
        model.isExporting = true
        try check(!model.canDeleteSelection && !model.deleteSelected(), "导出期间节点删除入口未统一禁用")
        model.isExporting = false
        model.select(second.id)
        try check(model.editingSelectionTarget == .clip && model.canDeleteSelection && model.deleteSelected() &&
                  model.clips.count == 1 && !model.canDeleteSelection && !model.deleteSelected(), "显式素材删除与最后一段保护失效")
        try check((try Data(contentsOf: project.sourceURL)) == originalRaw &&
                  (try encoder.encode(ProjectStore.load(folder: folder).trace)) == originalTrace, "删除操作修改了原片或原始轨迹")
        print("PASS camera delete persistence: preview-selected nodes and legacy motion points delete independently, protected boundaries/empty focus safe, group Undo restores selection, transient UI state, same raw item, autosave/reopen and original media/trace")
    }

    private static func horizontalRedSpan(_ image: CGImage) throws -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw RecorderError.message("不能采样取景导出像素。")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let left = bytes[(height / 2 * width + width / 10) * 4]
        let right = bytes[(height / 2 * width + width * 9 / 10) * 4]
        return abs(Double(right) - Double(left))
    }

    private static func waitForFraming(_ model: EditorModel, enabled: Bool) async throws {
        for _ in 0..<300 {
            if model.showsFramingOverlay == enabled && model.previewCameraEffectsEnabled == !enabled &&
                model.isFramingPreviewReady == enabled { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw RecorderError.message("取景预览切换未在限定时间内完成。")
    }

    private static func fixture(to url: URL) async throws {
        let width = 640, height = 360
        func sample(at time: Double, blue: Bool) throws -> CMSampleBuffer {
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
                      "合成图像分配失败")
            guard let pixel else { throw RecorderError.message("合成像素为空。") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<height { for x in 0..<width {
                let index = y * row + x * 4
                bytes[index] = UInt8((blue ? 160 : 40) + y * 70 / height)
                bytes[index + 1] = 105
                bytes[index + 2] = UInt8((blue ? 40 : 160) + x * 70 / width)
                bytes[index + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                        formatDescriptionOut: &format)
            guard let format else { throw RecorderError.message("合成视频格式失败。") }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(seconds: 1000.5 + time, preferredTimescale: 60_000),
                decodeTimeStamp: .invalid)
            var result: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
            guard status == noErr, let result else { throw RecorderError.message("合成视频样本失败。") }
            return result
        }
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 30, quality: .hevc)
        let first = try sample(at: 0, blue: false)
        writer.queue.sync { writer.appendVideo(first) }
        for tick in 0..<300 {
            if tick == 150 {
                let middle = try sample(at: 3, blue: true)
                writer.queue.sync { writer.appendVideo(middle) }
            }
            let frequency = tick < 150 ? 440.0 : 880.0
            let values = (0..<960).flatMap { index -> [Float] in
                let value = Float(sin(2 * Double.pi * frequency * Double(tick * 960 + index) / 48_000) * 0.15)
                return [value, value]
            }
            let audio = try AudioMixer.sample(values,
                pts: CMTime(seconds: 1000.5 + Double(tick) * 0.02, preferredTimescale: 48_000))
            writer.queue.sync { writer.appendAudio(audio) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let last = try sample(at: 6, blue: true)
        writer.queue.sync { writer.appendVideo(last) }
        _ = try await writer.finish(extendToNow: false)
    }

    private static func validate(output: URL, duration: Double, codec: FourCharCode, reordered: Bool) async throws {
        let asset = AVURLAsset(url: output)
        try check(abs(try await asset.load(.duration).seconds - duration) < 0.06, "导出时长改变")
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RecorderError.message("导出丢失视频或音轨。")
        }
        try check(try await video.load(.naturalSize) == CGSize(width: 640, height: 360), "导出尺寸改变")
        try check(try await video.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } == codec,
                  "导出编码格式错误")
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        try check(reader.startReading(), "导出视频不能解码")
        var count = 0
        var firstColor: [Int] = [], lastColor: [Int] = []
        while let sample = frames.copyNextSampleBuffer() {
            count += 1
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let index = CVPixelBufferGetHeight(pixel) / 2 * CVPixelBufferGetBytesPerRow(pixel) + CVPixelBufferGetWidth(pixel) / 2 * 4
            let color = [Int(pointer[index]), Int(pointer[index + 2])]
            if firstColor.isEmpty { firstColor = color }
            lastColor = color
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        }
        try check(reader.status == .completed && count >= Int(duration * 30) - 2,
                  "导出视频未完整解码或静态原片未持续生成帧")
        if reordered {
            try check(firstColor.count == 2 && lastColor.count == 2 && firstColor[0] > firstColor[1] + 40 &&
                      lastColor[1] > lastColor[0] + 40, "重排后真实画面顺序错误")
        }
        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        audioReader.add(audioOutput)
        try check(audioReader.startReading(), "导出音频不能解码")
        var audioFrames = 0
        var energy = 0.0
        while let sample = audioOutput.copyNextSampleBuffer() {
            audioFrames += CMSampleBufferGetNumSamples(sample)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            try check(status == noErr, "音频样本读取失败")
            energy += values.reduce(0) { $0 + Double($1 * $1) }
        }
        try check(audioReader.status == .completed && audioFrames > Int((duration - 0.1) * 48_000) && energy > 1,
                  "音频丢失、静音或未完整解码")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message(message) }
    }
}

#if PROJECT_SELF_TEST
@main
private struct ProjectSelfTestMain {
    @MainActor
    static func main() async {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/local-recorder-project-test")
            try await ProjectSelfTest.run(directory: directory)
        } catch {
            fputs("FAIL project: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
