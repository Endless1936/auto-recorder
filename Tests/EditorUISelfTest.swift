import AppKit
import Combine

/// Drives the displayed editor through its own NSApplication event queue.
/// Accessibility is used only to locate controls; actions never call the model.
@MainActor
enum EditorUISelfTest {
    static func run(window: NSWindow, model: EditorModel, directory: URL) async throws {
        let test = Harness(window: window, model: model, directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await test.run()
            try test.save(status: test.limitations.isEmpty ? "passed" : "partial")
        } catch {
            try? test.screenshot("failure")
            try? test.save(status: "failed", error: error.localizedDescription)
            throw error
        }
    }

    private struct Result: Codable {
        let name: String
        let elapsedMilliseconds: Double
        let detail: String
    }

    @MainActor
    private final class Harness {
        let window: NSWindow
        let model: EditorModel
        let directory: URL
        var results: [Result] = []
        var limitations: [String] = []
        var events: [[String: String]] = []
        var resolvedTargets: [String: [String: String]] = [:]
        var fullScreenNotifications: [[String: String]] = []
        var runtimeErrors: [String] = []
        var failurePhase: String?
        var eventNumber = 0
        let started = Date()

        init(window: NSWindow, model: EditorModel, directory: URL) {
            self.window = window
            self.model = model
            self.directory = directory
        }

        func run() async throws {
            let previousErrorHandler = model.onError
            model.onError = { [weak self] error in
                self?.runtimeErrors.append(error.localizedDescription)
            }
            defer { model.onError = previousErrorHandler }
            guard model.clips.count >= 2 else { throw failure("Fixture requires at least two clips.") }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(window.contentView)
            await settle(0.45)
            try await ensureActiveAndKeyWindow()
            if model.isPlaying { try await click("editor.preview.play") }
            try require(!model.isPlaying, "Unable to pause playback through the preview control.")
            let original = model.clips
            try require(!model.showsFramingOverlay && model.previewCameraEffectsEnabled,
                        "A newly opened editor must default to processed preview with framing assistance off.")
            try screenshot("initial")

            // Land on the formerly ambiguous halves of the neighboring clips.
            let left = original[0].id
            let right = original[1].id
            let rightFrame = try clipFrame(right)
            let leftFrame = try clipFrame(left)
            try require(min(rightFrame.width, leftFrame.width) >= 36,
                        "Fixture clips are too narrow for independent drag and trim targets.")
            var began = Date()
            try await drag(from: center(rightFrame), to: point(leftFrame, fraction: 0.75), delay: 0.12)
            var moved = original
            moved.swapAt(0, 1)
            try require(model.clips == moved, "Right-to-left drop did not reorder immediately after native mouse-up.")
            try screenshot("right-to-left")
            record("right-to-left-immediate", began, "Native drop into the left clip's right half committed within the first 120 ms observation.")
            try await undo()
            try require(model.clips == original, "One Command-Z did not restore the right-to-left move.")
            await refreshDisplayedLayout()
            try screenshot("undo-restored")

            began = Date()
            try await drag(from: center(try clipFrame(left)), to: point(try clipFrame(right), fraction: 0.25), delay: 0.12)
            try require(model.clips == moved, "Left-to-right drop into the target's left half did not reorder immediately.")
            try screenshot("left-to-right")
            try await undo()
            try require(model.clips == original, "One Command-Z did not restore the left-to-right move.")
            record("left-to-right-and-single-undo", began, "Both clip contents and order returned after one native Command-Z.")

            began = Date()
            let desktopBefore = desktopEntries()
            let pasteboard = NSPasteboard(name: .drag)
            let dragChange = pasteboard.changeCount
            let outsideScreen = NSPoint(x: window.frame.minX - 30, y: window.frame.maxY + 30)
            let outside = window.convertFromScreen(NSRect(origin: outsideScreen, size: .zero)).origin
            try await drag(from: center(try clipFrame(right)), to: outside)
            try require(model.clips == original, "Dropping outside the window modified the timeline.")
            try require(pasteboard.changeCount == dragChange,
                        "A timeline reorder unexpectedly declared an external drag pasteboard.")
            if let before = desktopBefore, let after = desktopEntries() {
                try require(after.subtracting(before).isEmpty, "Dropping outside the window created a Desktop entry.")
            } else {
                limitations.append("Desktop directory metadata could not be read. Off-window cancellation and an unchanged drag pasteboard passed; actual Desktop file creation was not verified.")
            }
            record("off-window-drop-cancels", began, "Own-window native events released outside the window; order/content and external drag pasteboard stayed unchanged.")

            began = Date()
            try await seekUsingRuler(fraction: 0.28)
            let timeline = try frame("editor.timeline")
            let marker = try frame("editor.timeline.playhead")
            let timelineAxis = EditorTimeAxisGeometry(containerWidth: timeline.width)
            let targetX = timeline.minX + timelineAxis.x(at: model.totalDuration * 0.72, total: model.totalDuration)
            // x + 13 and the bottom five points are outside the visible triangle.
            let markerGrab = NSPoint(x: marker.midX + 13, y: marker.minY + 5)
            try await drag(from: markerGrab, to: NSPoint(x: targetX, y: markerGrab.y))
            try require(abs(model.playhead - model.totalDuration * 0.72) < max(0.08, model.totalDuration * 0.008),
                        "The playhead's enlarged grab area did not scrub to the native drag position.")
            try require(model.clips == original, "Playhead scrubbing changed clip content.")
            try screenshot("expanded-playhead-grab")
            record("expanded-playhead-grab", began, "A drag starting outside the visible 10-by-20 triangle reached 72% of the timeline.")

            for edge in ["start", "end"] {
                began = Date()
                try await click(at: center(try clipFrame(left)))
                try require(model.selectedClipID == left, "Native clip click did not select the trim target.")
                let handle = try frame("editor.clip.\(left.uuidString).trim.\(edge)")
                let dx = min(32, (try clipFrame(left)).width * 0.15) * (edge == "start" ? 1 : -1)
                let handleCenter = center(handle)
                try await drag(from: handleCenter, to: NSPoint(x: handleCenter.x + dx, y: handleCenter.y))
                guard let trimmed = model.clips.first(where: { $0.id == left }) else { throw failure("Trimming removed its clip.") }
                try require(trimmed.duration < original[0].duration - 0.0001,
                            "Native \(edge) handle drag did not shorten its clip.")
                if edge == "start" {
                    try require(trimmed.sourceStart > original[0].sourceStart + 0.0001,
                                "Start trim did not advance the source boundary.")
                }
                try require(model.clips.map(\.id) == original.map(\.id), "Trim handle drag reordered clips.")
                try screenshot("trim-\(edge)")
                try await undo()
                try require(model.clips == original, "One Command-Z did not restore the \(edge) trim.")
                record("trim-\(edge)-and-single-undo", began, "The native handle shortened the clip without reordering; one Command-Z restored content.")
            }

            try await checkTimeAxisAlignment(original: original)
            try await checkPreviewControls(original: original)
            try require(model.clips == original, "The native UI test left content edits behind.")
            try screenshot("final")
            try requireNoRuntimeErrors()
        }

        func checkTimeAxisAlignment(original: [DemoClip]) async throws {
            guard original.count >= 2, original[0].duration > 0.3, original[1].duration > 0.3 else {
                throw failure("Time-axis alignment requires two nonempty source clips.")
            }
            let previousFrame = window.frame
            let previousClipID = model.selectedClipID, previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            defer { window.setFrame(previousFrame, display: true) }
            var fixture = original
            for index in fixture.indices { fixture[index].zooms = [] }
            func zoom(duration: Double) -> ZoomSegment {
                let points = [CameraKeyframe(time: 0, scale: 1),
                    CameraKeyframe(time: duration * 0.3, scale: 1.7),
                    CameraKeyframe(time: duration * 0.7, scale: 2),
                    CameraKeyframe(time: duration * 0.92, scale: 1)]
                return ZoomSegment(start: points[0].time, riseEnd: points[1].time,
                    fallStart: points[2].time, end: points[3].time, peak: 2,
                    manualFocus: true, cameraKeyframes: points).normalized()
            }
            let firstZoom = zoom(duration: fixture[0].duration), secondZoom = zoom(duration: fixture[1].duration)
            fixture[0].zooms = [firstZoom]; fixture[1].zooms = [secondZoom]
            model.clips = fixture
            model.selectedClipID = fixture[0].id; model.selectedZoomID = firstZoom.id
            model.seek(0)
            try model.autosave()
            try await model.rebuildPreview()
            let total = model.totalDuration
            let display = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let minimum = window.minSize
            try require(minimum.width >= 980 && minimum.height >= 730,
                        "The editor lost its supported minimum window size after installing its content view: \(minimum).")
            let large = NSSize(width: min(display.width - 24, max(previousFrame.width + 200, 1400)),
                               height: min(display.height - 24, max(previousFrame.height + 60, 940)))
            let cases: [(String, NSSize)] = [("normal", previousFrame.size), ("minimum", minimum), ("large", large)]
            for (name, size) in cases {
                let began = Date()
                let rect = NSRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2,
                                  width: size.width, height: size.height)
                window.setFrame(rect, display: true)
                await settle(0.12)
                await refreshDisplayedLayout()
                model.selectedClipID = fixture[0].id; model.selectedZoomID = firstZoom.id
                await refreshDisplayedLayout()
                let firstControl = firstZoom.cameraControlPoints[0]
                let firstNodeID = "editor.zoom.\(firstZoom.id.uuidString).anchor.\(firstControl.id.uuidString)"
                let firstNodeLocator = try frame(firstNodeID)
                try await click(at: center(firstNodeLocator), delay: 0.06)
                try require(model.selectedCameraAnchorIDs == [firstControl.id],
                            "The actual first endpoint could not be selected for visible halo/label verification.")
                let timelineCanvas = try actualViewFrame("editor.timeline.canvas")
                let graphCanvas = try actualViewFrame("editor.zoomGraph.canvas")
                let timelineData = try actualViewFrame("editor.timeline.dataFrame")
                let graphData = try actualViewFrame("editor.zoomGraph.dataFrame")
                let labels = try actualViewFrame("editor.zoomGraph.scaleLabels")
                let tools = optionalActualAccessibilityFrame("editor.zoomGraph.tools")
                let firstNode = optionalActualAccessibilityFrame(firstNodeID)
                let firstNodeOutline = firstNode?.insetBy(dx: -4, dy: -4)
                try require(abs(timelineCanvas.minX - graphCanvas.minX) <= 1 &&
                            abs(timelineCanvas.maxX - graphCanvas.maxX) <= 1 &&
                            abs(timelineData.minX - graphData.minX) <= 1 && abs(timelineData.maxX - graphData.maxX) <= 1,
                            "Actual drawn timeline/curve canvases or data regions have different visible widths after a \(name) resize.")
                try require(graphCanvas.minX - labels.maxX >= 12 - 0.01,
                            "The actual scale-label column leaves less than twelve points to the canvas after a \(name) resize.")
                if let firstNodeOutline {
                    try require(!labels.intersects(firstNodeOutline), "The actual label column overlaps the first node's selected outline.")
                } else {
                    let note = "SwiftUI node accessibility frames were unavailable. Native clicks verified endpoint selection; selected-halo/label separation requires review of visible-layout-*-first-endpoint.png. Locator frames are computed targets, not measured visible bounds."
                    if !limitations.contains(note) { limitations.append(note) }
                }
                for level in 1...3 {
                    let label = try actualViewFrame("editor.zoomGraph.scaleLabel.\(level)")
                    try require(graphCanvas.minX - label.maxX >= 12 - 0.01,
                                "An actual scale label touches the drawn canvas after a \(name) resize.")
                    if let firstNodeOutline {
                        try require(!label.intersects(firstNodeOutline), "An actual scale label touches the first node's selected outline.")
                    }
                    resolvedTargets["visible-layout.\(name).scaleLabel.\(level)"] = ["source": "actual native text field accessibility frame",
                        "windowFrame": NSStringFromRect(label), "canvasGap": String(format: "%.3f", graphCanvas.minX - label.maxX)]
                }
                if let tools {
                    try require(tools.minX >= graphCanvas.maxX - 0.01 && !tools.intersects(graphCanvas),
                                "The actual right-side tools intrude into the curve canvas after a \(name) resize.")
                } else {
                    let note = "SwiftUI toolbar accessibility frames were unavailable; tool/canvas separation requires review of visible-layout-*-first-endpoint.png. No computed toolbar bounds are counted as actual measurements."
                    if !limitations.contains(note) { limitations.append(note) }
                }
                for (id, measurement) in [("timelineCanvas", timelineCanvas), ("curveCanvas", graphCanvas),
                    ("timelineData", timelineData), ("curveData", graphData), ("scaleLabels", labels)] {
                    resolvedTargets["visible-layout.\(name).\(id)"] = ["source": "actual native view/accessibility frame; no layout fallback",
                        "windowFrame": NSStringFromRect(measurement)]
                }
                for (id, measurement) in [("tools", tools), ("firstNode", firstNode), ("firstNodeOutline", firstNodeOutline)] {
                    if let measurement {
                        resolvedTargets["visible-layout.\(name).\(id)"] = ["source": "actual accessibility frame; no layout fallback",
                            "windowFrame": NSStringFromRect(measurement)]
                    }
                }
                resolvedTargets["visible-layout.\(name).firstNodeClickTarget"] = ["source": "input locator only; native click verified selected ID; not measured visible bounds",
                    "windowFrame": NSStringFromRect(firstNodeLocator)]
                try screenshot("visible-layout-\(name)-first-endpoint")
                let ruler = try frame("editor.timeline.ruler")
                let graph = try frame("editor.zoomGraph")
                let axis = EditorTimeAxisGeometry(containerWidth: graph.width)
                try require(abs(ruler.minX - graph.minX - axis.minX) <= 1 &&
                            abs(ruler.maxX - graph.minX - axis.maxX) <= 1 &&
                            abs(ruler.minX - timelineData.minX) <= 1 && abs(ruler.maxX - timelineData.maxX) <= 1,
                            "The ruler and curve plot have different visible time ranges after a \(name) resize.")
                let timeTolerance = max(0.002, total * 1.1 / Double(max(1, ruler.width)))
                for fraction in [0.15, 0.5, 0.85] {
                    let time = total * fraction
                    let x = ruler.minX + ruler.width * fraction
                    try await click(at: NSPoint(x: x, y: ruler.midY), delay: 0.06)
                    try require(abs(model.playhead - time) <= timeTolerance &&
                                abs((try frame("editor.timeline.playhead")).midX - x) <= 1,
                                "Ruler click and playhead disagree at \(fraction) after a \(name) resize.")
                    // Take x from the independent, displayed ruler, not from the
                    // curve's mapping helper; native hit-testing must agree.
                    let curveY = try cameraGraphPoint(globalTime: time, scale: 2.85).y
                    try await click(at: NSPoint(x: x, y: curveY), delay: 0.06)
                    try require(abs(model.playhead - time) <= timeTolerance &&
                                abs((try frame("editor.timeline.playhead")).midX - x) <= 1 && model.clips == fixture,
                                "A curve click at the ruler's physical x seeks a different time after a \(name) resize.")
                }
                for (index, zoom) in [(0, firstZoom), (1, secondZoom)] {
                    model.selectedClipID = fixture[index].id; model.selectedZoomID = zoom.id
                    await refreshDisplayedLayout()
                    let control = zoom.cameraControlPoints[1]
                    let time = model.startTime(of: fixture[index].id) + control.time
                    let node = center(try frame("editor.zoom.\(zoom.id.uuidString).anchor.\(control.id.uuidString)"))
                    let expectedX = ruler.minX + ruler.width * CGFloat(time / total)
                    try require(abs(node.x - expectedX) <= 1,
                                "A curve node does not align with its global ruler time after a \(name) resize.")
                    try await click(at: node, delay: 0.06)
                    try require(abs(model.playhead - time) <= timeTolerance &&
                                abs((try frame("editor.timeline.playhead")).midX - node.x) <= 1 &&
                                model.selectedCameraAnchorIDs == [control.id],
                                "Curve node, playhead and selected global time disagree after a \(name) resize.")
                }
                let moving = secondZoom.cameraControlPoints[1]
                let identifier = "editor.zoom.\(secondZoom.id.uuidString).anchor.\(moving.id.uuidString)"
                let start = center(try frame(identifier))
                let targetTime = model.startTime(of: fixture[1].id) + fixture[1].duration * 0.44
                let targetX = ruler.minX + ruler.width * CGFloat(targetTime / total)
                try await drag(from: start, to: NSPoint(x: targetX, y: start.y))
                guard let moved = model.selectedZoom?.cameraControlPoints.first(where: { $0.id == moving.id }) else {
                    throw failure("Time-axis node drag lost its selected control.")
                }
                let movedTime = model.startTime(of: fixture[1].id) + moved.time
                try require(abs(movedTime - targetTime) <= timeTolerance && abs(model.playhead - targetTime) <= timeTolerance &&
                            abs((try frame(identifier)).midX - targetX) <= 1 &&
                            abs((try frame("editor.timeline.playhead")).midX - targetX) <= 1,
                            "Horizontal curve drag uses a different time scale from the ruler/playhead after a \(name) resize.")
                try await undo()
                try require(model.clips == fixture, "One Undo did not restore the axis-alignment node drag.")
                try screenshot("time-axis-\(name)")
                record("shared-time-axis-\(name)", began,
                       "Actual native canvas/data/text frames matched and labels kept a twelve-point gap; missing virtual node/tool bounds require the recorded screenshot review. Ruler clicks, curve nodes and dragging agreed within one point at window size \(window.frame.size).")
            }
            window.setFrame(previousFrame, display: true)
            model.clips = original; model.selectedClipID = previousClipID; model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Time-axis alignment fixtures left edits behind.")
        }

        func checkPreviewControls(original: [DemoClip]) async throws {
            let began = Date()
            var addedZoom = false
            if let clip = model.clips.first(where: { $0.zooms.contains(where: \.isEnabled) }) {
                try await click(at: center(try clipFrame(clip.id)))
            } else {
                try await seekUsingRuler(fraction: 0.35)
                try await click("editor.zoom.add")
                addedZoom = true
            }
            try require(model.selectedZoom != nil, "Preview focus interception cannot be tested without an enabled zoom.")
            let focusable = model.clips
            try await seekUsingRuler(fraction: 0.40)

            for (identifier, delta) in [("editor.preview.forward", 5.0), ("editor.preview.backward", -5.0)] {
                let before = model.playhead
                var changes = 0
                let observation = model.$playhead.dropFirst().sink { _ in changes += 1 }
                try await click(identifier)
                observation.cancel()
                let expected = min(model.totalDuration, max(0, before + delta))
                try require(abs(model.playhead - expected) < 0.02 && changes == 1,
                            "\(identifier) should seek exactly once; observed \(changes) playhead assignments at \(model.playhead), expected \(expected).")
                try require(model.clips == focusable, "\(identifier) also changed the preview focus/zoom.")
            }

            let beforePlay = model.playhead
            try await click("editor.preview.play", delay: 0.10)
            try require(model.isPlaying, "Native preview play click did not begin playback.")
            try require(model.clips == focusable, "Preview play click also changed focus/zoom.")
            try await click("editor.preview.play", delay: 0.08)
            try require(!model.isPlaying, "Native preview pause click did not pause playback.")
            try require(model.playhead >= beforePlay - 0.02 && model.playhead < beforePlay + 1,
                        "Preview play/pause unexpectedly scrubbed the playhead.")
            try require(model.clips == focusable, "Preview pause click also changed focus/zoom.")

            let beforeFullScreen = model.playhead
            var changes = 0
            let observation = model.$playhead.dropFirst().sink { _ in changes += 1 }
            try await clickFullScreen(enter: true)
            try require(model.clips == focusable && abs(model.playhead - beforeFullScreen) < 0.02 && changes == 0,
                        "Preview fullscreen click also changed focus or scrubbed the timeline.")
            try screenshot("fullscreen")
            try await clickFullScreen(enter: false)
            observation.cancel()
            try require(model.clips == focusable && abs(model.playhead - beforeFullScreen) < 0.02 && changes == 0,
                        "Exiting fullscreen also changed focus or scrubbed the timeline.")
            try await checkPreviewEditingTools(original: focusable)
            try await checkFramingOverlay(original: focusable)
            try await checkFramingStaleSelection(original: focusable)
            try await checkCameraAnchors(original: focusable)
            try await checkAutomaticCircularPath(original: focusable)
            try await checkAutomaticCircularPath(original: focusable, irregular: true)
            try await checkCameraCurveSelection(original: focusable)
            try await checkTargetAwareDelete(original: focusable)
            try await checkCameraTargetNavigation(original: focusable)
            if addedZoom {
                try await undo()
                try require(model.clips == original, "One Command-Z did not remove the UI-created test zoom.")
            }
            record("preview-controls-no-duplicate-scrub", began,
                   "Focusable preview: each skip sought once; play/pause and fullscreen toggles preserved zoom content and expected playback position.")
        }

        func checkPreviewEditingTools(original: [DemoClip]) async throws {
            let began = Date()
            guard let clip = model.selectedClip, clip.duration >= 0.5, model.selectedZoom != nil else {
                throw failure("Preview edit controls require a selected focusable clip long enough to split.")
            }
            let middle = model.startTime(of: clip.id) + clip.duration / 2
            try await seekUsingRuler(fraction: CGFloat(middle / model.totalDuration))
            try await click("editor.preview.split")
            try require(model.clips.count == original.count + 1,
                        "Native preview split did not create exactly one additional clip.")
            try await click("editor.preview.undo")
            try require(model.clips == original && model.selectedClipID == clip.id,
                        "One native preview Undo did not restore the split; an overlay click may have changed preview focus.")
            try await click(at: center(try clipFrame(clip.id)))
            try await click("editor.preview.delete")
            try require(model.clips == original.filter { $0.id != clip.id },
                        "Native preview Delete did not remove only the selected clip.")
            try await click("editor.preview.undo")
            try require(model.clips == original && model.selectedClipID == clip.id,
                        "One native preview Undo did not restore the deletion; an overlay click may have changed preview focus.")
            record("preview-edit-controls-and-single-undo", began,
                   "Focusable preview: split and selected-clip deletion each restored exact clip/zoom content with one native overlay Undo click.")
        }

        func checkFramingOverlay(original: [DemoClip]) async throws {
            guard let clip = model.selectedClip, let zoom = model.selectedZoom else {
                throw failure("Framing interactions require a selected enabled zoom.")
            }
            // Put the actual playhead inside the selected zoom through the ruler.
            let local = min(clip.duration - 0.05, max(0.05, (zoom.riseEnd + zoom.fallStart) / 2))
            try await seekUsingRuler(fraction: CGFloat((model.startTime(of: clip.id) + local) / model.totalDuration))
            var began = Date()
            let pausedTime = model.playhead
            try await click("editor.framing.toggle")
            try await waitUntil("The framing toggle did not finish preparing the raw preview.") {
                self.model.showsFramingOverlay && self.model.isFramingPreviewReady && self.model.framingState != nil
            }
            try require(!model.previewCameraEffectsEnabled && !model.isPlaying && abs(model.playhead - pausedTime) < 0.02,
                        "Paused framing toggle changed playback state/time or kept camera effects enabled.")
            try require(model.clips == original && model.framingState?.canEdit == true,
                        "Opening framing assistance edited the project or did not enable paused editing.")
            try screenshot("framing-paused")
            record("framing-default-off-and-paused-toggle", began,
                   "Default-off processed preview switched through its native toggle to raw framing assistance without changing paused time or project content.")

            began = Date()
            let beforeFrameZoom = model.selectedZoom
            let frameGrab = try framingFrameGrabPoint()
            let source = try framingSourceFrame()
            let dx = source.width * (model.framingState!.pose.x <= 0.5 ? 0.055 : -0.055)
            try await drag(from: frameGrab, to: NSPoint(x: frameGrab.x + dx, y: frameGrab.y))
            try require(model.clips != original &&
                        (model.selectedZoom?.centerPath != beforeFrameZoom?.centerPath ||
                         model.selectedZoom?.manualCenterPath != beforeFrameZoom?.manualCenterPath ||
                         model.selectedZoom?.centerOffsets != beforeFrameZoom?.centerOffsets) &&
                        (model.selectedZoom?.centerPath.isEmpty == false || model.selectedZoom?.manualCenterPath?.isEmpty == false),
                        "Native framing-frame drag did not change and retain the selected zoom's center path.")
            try require(try persistedClips() == model.clips, "Native frame drag was not saved in project.json.")
            try screenshot("framing-frame-drag")
            try await undo()
            try require(model.clips == original && !model.isPlaying && abs(model.playhead - pausedTime) < 0.02,
                        "One native Command-Z did not restore frame-drag content and paused time.")
            try require(try persistedClips() == original, "Frame-drag Undo did not restore the saved project.")
            try await waitUntil("Framing assistance did not become editable after frame-drag Undo.") {
                self.model.framingState?.canEdit == true
            }
            record("framing-frame-drag-save-and-single-undo", began,
                   "Native frame drag changed the persisted center path; one native Command-Z restored exact clip/zoom content and playback position.")

            began = Date()
            let preview = try frame("editor.preview.surface")
            var handleTarget: (handle: ZoomCenterPoint, point: NSPoint)?
            for (index, handle) in (model.framingState?.handles ?? []).enumerated() {
                guard (model.selectedZoom?.scale(at: handle.time) ?? 1) > 1.000001 else { continue }
                let point = center(try frame("editor.framing.handle.\(index)"))
                if point.y > preview.minY + 60 && preview.insetBy(dx: 14, dy: 14).contains(point) {
                    handleTarget = (handle, point)
                    break
                }
            }
            guard let handleTarget else {
                throw failure("Framing assistance did not expose any path handles.")
            }
            let handleGrab = handleTarget.point
            let handleDX = source.width * (handleTarget.handle.x <= 0.5 ? 0.045 : -0.045)
            let beforeHandleZoom = model.selectedZoom
            try await drag(from: handleGrab, to: NSPoint(x: handleGrab.x + handleDX, y: handleGrab.y))
            try require(model.clips != original &&
                        (model.selectedZoom?.centerPath != beforeHandleZoom?.centerPath ||
                         model.selectedZoom?.manualCenterPath != beforeHandleZoom?.manualCenterPath ||
                         model.selectedZoom?.centerOffsets != beforeHandleZoom?.centerOffsets),
                        "Native path-handle drag did not change the selected zoom's center path.")
            try require(try persistedClips() == model.clips, "Native path-handle drag was not saved in project.json.")
            try screenshot("framing-path-handle-drag")
            try await undo()
            try require(model.clips == original && abs(model.playhead - pausedTime) < 0.02,
                        "One native Command-Z did not restore path-handle content and paused time.")
            try require(try persistedClips() == original, "Path-handle Undo did not restore the saved project.")
            try await waitUntil("Framing assistance did not recover after path-handle Undo.") {
                self.model.framingState?.canEdit == true
            }
            record("framing-path-handle-save-and-single-undo", began,
                   "Native path-handle drag changed the persisted center path and one native Command-Z restored it exactly.")

            began = Date()
            let playbackBegan = Date()
            let beforePlay = model.playhead
            let readonlyGrab = try framingFrameGrabPoint()
            try await click("editor.preview.play", delay: 0.08)
            try require(model.isPlaying && model.framingState?.canEdit == false,
                        "Framing playback did not begin with a read-only overlay.")
            try await drag(from: readonlyGrab, to: NSPoint(x: readonlyGrab.x + dx, y: readonlyGrab.y), delay: 0.10)
            try require(model.clips == original && model.isPlaying,
                        "Dragging the framing overlay during playback edited the project or stopped playback.")
            try require(try persistedClips() == original, "Playback overlay drag changed the saved project.")
            try requirePlaybackContinuation(from: beforePlay, since: playbackBegan)
            record("framing-playback-is-read-only", began,
                   "Native drag during playback left in-memory and saved clip/zoom content unchanged while playback continued.")

            began = Date()
            for enabled in [false, true] {
                let time = model.playhead
                let switchedAt = Date()
                try await click("editor.framing.toggle", delay: 0.06)
                try await waitUntil("The playing framing toggle did not finish switching preview modes.") {
                    self.model.showsFramingOverlay == enabled && self.model.previewCameraEffectsEnabled == !enabled &&
                        (!enabled || self.model.isFramingPreviewReady)
                }
                try require(model.isPlaying && model.clips == original,
                            "Playing framing toggle paused playback or changed project content.")
                try requirePlaybackContinuation(from: time, since: switchedAt)
            }
            try screenshot("framing-playing")
            try await click("editor.preview.play", delay: 0.08)
            try require(!model.isPlaying, "Native preview pause did not stop framing playback.")
            let finalTime = model.playhead
            try await click("editor.framing.toggle", delay: 0.06)
            try await waitUntil("Closing framing assistance did not restore processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            try require(!model.isPlaying && abs(model.playhead - finalTime) < 0.02 && model.clips == original,
                        "Closing framing assistance changed paused time, playback state, or project content.")
            try screenshot("framing-off-processed")
            record("framing-playing-toggle-and-processed-restore", began,
                   "Native off/on toggles preserved ongoing playback with bounded natural time progression; closing after pause restored processed preview at the same time.")
        }

        func waitUntil(_ message: String, timeout: Double = 6, condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                try requireNoRuntimeErrors()
                await settle(0.025)
            }
            try requireNoRuntimeErrors()
            try require(condition(), message)
        }

        func checkFramingStaleSelection(original: [DemoClip]) async throws {
            guard let targetIndex = original.firstIndex(where: { $0.duration >= 0.5 }),
                  let otherIndex = original.indices.first(where: { $0 != targetIndex }) else {
                throw failure("Stale-selection framing requires two clips and one clip of at least half a second.")
            }
            let previousClipID = model.selectedClipID
            let previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            var fixture = original
            let duration = fixture[targetIndex].duration
            let target = ZoomSegment(start: 0, riseEnd: duration * 0.1,
                fallStart: duration * 0.35, end: duration * 0.45, peak: 1.6,
                focusX: 0.5, focusY: 0.5, manualFocus: true).normalized()
            let later = ZoomSegment(start: duration * 0.55, riseEnd: duration * 0.65,
                fallStart: duration * 0.9, end: duration, peak: 1.6,
                focusX: 0.5, focusY: 0.5, manualFocus: true).normalized()
            let otherZoom = ZoomSegment.standard(duration: fixture[otherIndex].duration)
            fixture[targetIndex].zooms = [target, later]
            fixture[otherIndex].zooms = [otherZoom]

            // Direct assignments establish deliberately inconsistent saved selection.
            // The edits under test still use the displayed view's native event queue.
            model.clips = fixture
            model.selectedClipID = fixture[targetIndex].id
            model.selectedZoomID = later.id
            model.seek(model.startTime(of: fixture[targetIndex].id) + duration * 0.22)
            try model.autosave()
            try await model.rebuildPreview()
            try await click("editor.framing.toggle")
            try await waitUntil("Stale-selection fixture did not prepare framing preview.") {
                self.model.showsFramingOverlay && self.model.isFramingPreviewReady
            }

            for crossClip in [false, true] {
                let began = Date()
                let staleClipID = fixture[crossClip ? otherIndex : targetIndex].id
                let staleZoomID = crossClip ? otherZoom.id : later.id
                model.selectedClipID = staleClipID
                model.selectedZoomID = staleZoomID
                try model.autosave()
                await refreshDisplayedLayout()
                try await waitUntil("The visible frame did not become editable with stale selection.") {
                    self.model.framingState?.clipID == fixture[targetIndex].id &&
                        self.model.framingState?.zoomID == target.id && self.model.framingState?.canEdit == true
                }
                try require(model.selectedClipID == staleClipID && model.selectedZoomID == staleZoomID,
                            "Merely showing the current frame unexpectedly replaced the saved stale selection.")
                let time = model.playhead
                guard let previewItem = model.player.currentItem else {
                    throw failure("Stale-selection drag has no prepared raw player item.")
                }
                let grab = try framingFrameGrabPoint()
                let source = try framingSourceFrame()
                let destination = NSPoint(x: grab.x + source.width * 0.055, y: grab.y)
                if crossClip { try await dragFramingSlowly(from: grab, to: destination) }
                else { try await drag(from: grab, to: destination) }
                try require(model.player.currentItem === previewItem,
                            "Zoom-only framing edits replaced the raw player item during drag or mouse-up.")
                try require(model.selectedClipID == fixture[targetIndex].id && model.selectedZoomID == target.id,
                            "Dragging the visible frame did not adopt its actual clip and zoom as selection.")
                guard let edited = model.clips[targetIndex].zooms.first(where: { $0.id == target.id }) else {
                    throw failure("Visible-frame drag removed its actual target zoom.")
                }
                try require(edited != target && edited.manualCenterPath?.isEmpty == false,
                            "Native frame drag with stale selection did not change its active motion path.")
                var expected = fixture
                expected[targetIndex].zooms = expected[targetIndex].zooms.map { $0.id == target.id ? edited : $0 }
                try require(model.clips == expected, "Visible-frame drag modified a zoom outside the actual active target.")
                try require(try persistedClips() == expected, "Visible-frame drag with stale selection was not persisted.")
                try screenshot(crossClip ? "framing-stale-other-clip-drag" : "framing-stale-same-clip-drag")
                try await undo()
                try require(model.player.currentItem === previewItem,
                            "Undoing a zoom-only framing drag replaced the raw player item.")
                try require(model.clips == fixture && model.selectedClipID == staleClipID &&
                            model.selectedZoomID == staleZoomID && abs(model.playhead - time) < 0.02,
                            "One native Undo failed to restore exact content, stale selection and time.")
                try require(try persistedClips() == fixture, "Stale-selection drag Undo did not restore saved content.")
                try await waitUntil("Stale-selection drag Undo did not recover editable framing.") {
                    self.model.framingState?.zoomID == target.id && self.model.framingState?.canEdit == true
                }
                record(crossClip ? "framing-stale-other-clip-drag-and-undo" : "framing-stale-same-clip-drag-and-undo", began,
                       "Native visible-frame drag adopted the active zoom despite stale selection, saved only its path, and one Command-Z restored content, selection and time.")
            }

            try await click("editor.framing.toggle")
            try await waitUntil("Stale-selection tests did not restore processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            model.clips = original
            model.selectedClipID = previousClipID
            model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Stale-selection fixture left content edits behind.")
        }

        func requirePlaybackContinuation(from time: Double, since date: Date) throws {
            let elapsed = Date().timeIntervalSince(date)
            try require(model.playhead >= time - 0.08 && model.playhead <= time + elapsed + 0.75,
                        "Preview mode switch reset or unexpectedly jumped playback time (before=\(time), after=\(model.playhead), elapsed=\(elapsed)).")
        }

        func checkCameraAnchors(original: [DemoClip]) async throws {
            guard let targetIndex = original.firstIndex(where: { $0.duration >= 1 }) else {
                throw failure("Camera-anchor interactions require a source clip of at least one second.")
            }
            let previousClipID = model.selectedClipID
            let previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            var fixture = original
            let duration = fixture[targetIndex].duration
            let zoom = ZoomSegment(start: 0, riseEnd: duration * 0.12,
                fallStart: duration * 0.88, end: duration, peak: 1.6,
                focusX: 0.5, focusY: 0.5, manualFocus: true).normalized()
            fixture[targetIndex].zooms = [zoom]
            model.clips = fixture
            model.selectedClipID = fixture[targetIndex].id
            model.selectedZoomID = zoom.id
            model.seek(model.startTime(of: fixture[targetIndex].id) + duration * 0.34)
            try model.autosave()
            try await model.rebuildPreview()
            try await click("editor.framing.toggle")
            try await waitUntil("Camera-anchor fixture did not prepare the editable raw preview.") {
                self.model.framingState?.canResize == true && self.model.isFramingPreviewReady
            }
            guard let previewItem = model.player.currentItem else {
                throw failure("Camera-anchor fixture has no raw preview item.")
            }

            var began = Date()
            let firstTime = model.activeLocalTime
            let firstPose = model.activePose
            try await click("editor.framing.addAnchor")
            guard model.selectedZoom?.cameraControlPoints.contains(where: { abs($0.time - firstTime) < 0.001 }) == true else {
                throw failure("The native Add Anchor button did not create a current-time camera anchor.")
            }
            let added = model.clips
            try require(added != fixture && abs(model.activePose.scale - firstPose.scale) < 0.000001,
                        "Adding a camera anchor did not persist a new anchor or jumped the current magnification.")
            try await click("editor.framing.addAnchor")
            try require(model.clips == added &&
                        model.selectedZoom?.cameraControlPoints.filter({ abs($0.time - firstTime) < 0.001 }).count == 1,
                        "Clicking Add Anchor twice at one time created duplicates or changed the camera.")
            try require(try persistedClips() == added, "Adding a camera anchor was not automatically saved.")
            let reopened = EditorModel()
            guard let folder = model.projectURL else { throw failure("Camera-anchor fixture has no project folder.") }
            try await reopened.loadProject(folder: folder)
            try require(reopened.clips == added, "Reopening the project did not restore its added anchor.")
            try await undo()
            try require(model.clips == fixture, "One native Undo did not remove the added anchor exactly.")
            try await click("editor.framing.addAnchor")
            guard let first = model.selectedZoom?.cameraControlPoints.first(where: { abs($0.time - firstTime) < 0.001 }) else {
                throw failure("Re-adding the current-time anchor did not restore an editable point.")
            }
            record("framing-add-anchor-repeat-save-reopen-and-undo", began,
                   "Native Add Anchor created one current-time point, repeat click preserved it, reopen retained it and one Command-Z restored the old camera.")

            began = Date()
            let beforeResize = model.clips
            try await resizeCurrentFrame(radialFactor: 0.76)
            let firstScale = model.activePose.scale
            try require(firstScale > firstPose.scale + 0.15 && firstScale <= 3,
                        "Shrinking the native frame corner did not increase current magnification.")
            try require(model.selectedZoom?.cameraKeyframes?.contains(where: { $0.id == first.id }) == true,
                        "Resizing replaced the current anchor identity.")
            try await undo()
            try require(model.clips == beforeResize, "One native Undo did not restore a corner resize.")
            try await resizeCurrentFrame(radialFactor: 0.76)
            let firstScaleAfterRedo = model.activePose.scale
            let grab = try framingFrameGrabPoint()
            let source = try framingSourceFrame()
            let beforeMoveX = model.activePose.x
            try await drag(from: grab, to: NSPoint(x: grab.x + source.width * 0.035, y: grab.y))
            try require(abs(model.activePose.x - beforeMoveX) > 0.01,
                        "A resized camera anchor could not be moved through the native frame.")
            try await seekUsingRuler(fraction: CGFloat((model.startTime(of: fixture[targetIndex].id) + duration * 0.66) / model.totalDuration))
            let secondTime = model.activeLocalTime
            try await click("editor.framing.addAnchor")
            guard let second = model.selectedZoom?.cameraControlPoints.first(where: { abs($0.time - secondTime) < 0.001 }) else {
                throw failure("Adding a second camera anchor did not create the later point.")
            }
            let beforeExpansion = model.activePose.scale
            try await resizeCurrentFrame(radialFactor: 1.2)
            let secondScale = model.activePose.scale
            try require(secondScale < beforeExpansion - 0.08 && secondScale > 1 &&
                        abs(secondScale - firstScaleAfterRedo) > 0.2,
                        "Two camera anchors did not retain independent enlargement and fallback amplitudes.")
            guard let multiZoom = model.selectedZoom else { throw failure("Native anchor resizing lost its zoom.") }
            try require(abs(multiZoom.scale(at: firstTime) - firstScaleAfterRedo) < 0.00001 &&
                        abs(multiZoom.scale(at: secondTime) - secondScale) < 0.00001,
                        "Editing the later anchor changed the earlier anchor's magnification.")
            let savedMultiStage = try persistedClips()
            try require(model.player.currentItem === previewItem && savedMultiStage == model.clips,
                        "Multi-stage frame edits reloaded raw video or were not saved.")
            try await reopened.loadProject(folder: folder)
            try require(reopened.clips == model.clips, "Reopening lost the independent camera amplitudes or positions.")
            try screenshot("framing-multiple-amplitudes")
            record("framing-corner-resize-independent-amplitudes", began,
                   "Native corner shrinks/expansions set different earlier/later magnifications; moving the first frame changed its path, resize Undo and reopening retained exact data without replacing raw video.")

            began = Date()
            guard let firstHandleIndex = model.framingState?.handles.firstIndex(where: { abs($0.time - firstTime) < 0.001 }) else {
                throw failure("An added earlier anchor was not exposed as a numbered path handle.")
            }
            try await click("editor.framing.handle.\(firstHandleIndex)")
            try require(abs(model.activeLocalTime - firstTime) < 0.02 &&
                        abs(model.activePose.scale - firstScaleAfterRedo) < 0.02,
                        "Clicking a numbered path handle did not preview its corresponding time and magnification.")
            let beforeCurve = model.clips
            let curveStart = center(try frame("editor.zoom.\(zoom.id.uuidString).anchor.\(first.id.uuidString)"))
            let newTime = firstTime + duration * 0.04
            let curveEnd = try cameraGraphPoint(globalTime: model.startTime(of: fixture[targetIndex].id) + newTime, scale: 2.35)
            try await drag(from: curveStart, to: curveEnd)
            guard let curveAnchor = model.selectedZoom?.cameraControlPoints.first(where: { $0.id == first.id }) else {
                throw failure("Dragging a curve anchor lost its identity.")
            }
            try require(abs(curveAnchor.time - newTime) < 0.05 && abs(curveAnchor.scale - 2.35) < 0.05 &&
                        abs(model.activePose.scale - curveAnchor.scale) < 0.025,
                        "Native curve-anchor time/scale drag did not update the corresponding preview frame.")
            try require(try persistedClips() == model.clips, "Curve-anchor drag did not save its new time and scale.")
            try screenshot("framing-curve-anchor-edit")
            try await undo()
            try require(model.clips == beforeCurve, "One native Undo did not restore the curve-anchor edit.")
            record("framing-numbered-path-selection-and-curve-bridge", began,
                   "Selecting a numbered path point sought its time; dragging its curve point changed independent time/magnification and the live frame, with one saved Undo.")

            began = Date()
            let secondCurve = center(try frame("editor.zoom.\(zoom.id.uuidString).anchor.\(second.id.uuidString)"))
            try await drag(from: secondCurve,
                           to: cameraGraphPoint(globalTime: model.startTime(of: fixture[targetIndex].id) + secondTime, scale: 1))
            try require(abs(model.activePose.scale - 1) < 0.00001 &&
                        model.framingState?.canResize == true && model.framingState?.canEdit == false,
                        "An intermediate 1× anchor did not allow resizing while preventing full-view panning.")
            let fullView = model.clips
            let fullGrab = try framingFrameGrabPoint()
            try await drag(from: fullGrab, to: NSPoint(x: fullGrab.x + 20, y: fullGrab.y))
            try require(model.clips == fullView, "Panning a 1× intermediate camera anchor unexpectedly changed its position.")
            try await resizeCurrentFrame(radialFactor: 0.8)
            try require(model.activePose.scale > 1.1 && model.framingState?.canEdit == true,
                        "A 1× frame could not be enlarged again using its native corner handle.")
            let savedFullViewResize = try persistedClips()
            try require(model.player.currentItem === previewItem && savedFullViewResize == model.clips,
                        "Resizing from full view reloaded raw video or failed to save.")
            record("framing-intermediate-full-view-resize", began,
                   "An interior curve anchor reached 1× without removing other peaks; full-view pan was ignored and its native corner restored enlargement.")

            // Consume this fixture's edits without disturbing earlier test history.
            // That history can contain the real Add Zoom exercised by the caller.
            var cleanupUndos = 0
            while model.clips != fixture && cleanupUndos < 20 {
                try await undo()
                cleanupUndos += 1
            }
            try require(model.clips == fixture, "Camera-anchor fixture edits could not be fully undone.")
            try await click("editor.framing.toggle")
            try await waitUntil("Camera-anchor tests did not restore normal processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            model.clips = original
            model.selectedClipID = previousClipID
            model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Camera-anchor test fixture left edits behind.")
        }

        func checkAutomaticCircularPath(original: [DemoClip], irregular: Bool = false) async throws {
            guard let targetIndex = original.indices.max(by: { original[$0].duration < original[$1].duration }),
                  original[targetIndex].duration >= 2 else {
                throw failure("Automatic circular-path interactions require a source clip of at least two seconds.")
            }
            let began = Date()
            let previousClipID = model.selectedClipID
            let previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            let duration = original[targetIndex].duration
            let clipID = original[targetIndex].id
            let offset = model.startTime(of: clipID)
            let scenario = irregular ? "irregular" : "circle"
            var path = (0...Int(floor(duration * 30))).map { index -> ZoomCenterPoint in
                let time = Double(index) / 30
                let progress = time / duration
                let phase = progress + (irregular ? 0.1 * sin(progress * 2 * Double.pi) : 0)
                let angle = phase * 2 * Double.pi
                return ZoomCenterPoint(time: time,
                    x: 0.5 + 0.11 * cos(angle) + (irregular ? 0.035 * sin(3 * angle) : 0),
                    y: 0.5 + 0.11 * sin(angle) + (irregular ? 0.025 * sin(5 * angle) : 0))
            }
            if duration - (path.last?.time ?? 0) > 0.000001 {
                path.append(ZoomCenterPoint(time: duration, x: 0.61, y: 0.5))
            }
            let zoom = ZoomSegment(start: 0, riseEnd: duration * 0.12,
                fallStart: duration * 0.88, end: duration, peak: 1.8, centerPath: path).normalized()
            let controls = zoom.cameraControlPoints
            try require(zoom.cameraKeyframes == nil && controls.count > 4,
                        "A dense automatic circle did not expose meaningful controls beyond its four scale stages.")
            let candidates = controls.indices.filter { index in
                index > 0 && index < controls.count - 1 &&
                    controls[index].time >= duration * 0.24 && controls[index].time <= duration * 0.76 &&
                    controls[index].time - controls[index - 1].time > 0.08 &&
                    controls[index + 1].time - controls[index].time > 0.08
            }
            guard let target = candidates.min(by: {
                abs(controls[$0].time - duration / 2) < abs(controls[$1].time - duration / 2)
            }) else { throw failure("The automatic circle has no interior control with independently testable neighboring intervals.") }
            let control = controls[target]
            var fixture = original
            fixture[targetIndex].zooms = [zoom]
            model.clips = fixture
            model.selectedClipID = clipID
            model.selectedZoomID = zoom.id
            model.seek(offset + duration * 0.2)
            try model.autosave()
            try await model.rebuildPreview()
            try await click("editor.framing.toggle")
            try await waitUntil("The automatic circle did not prepare its framing controls.") {
                self.model.isFramingPreviewReady && self.model.framingState?.handles.count == controls.count
            }

            let coincident = Array(repeating: CGPoint(x: 150, y: 150), count: 6)
            let badges = FramingOverlayGeometry.handleBadgeCenters(points: coincident,
                bounds: CGRect(x: 0, y: 0, width: 300, height: 300))
            for index in badges.indices {
                try require(FramingOverlayGeometry.badgeIndex(at: badges[index], centers: badges) == index,
                            "Coincident centers do not retain independently hittable numbered badges.")
            }

            let identifier = try cameraHandleIdentifier(at: control.time)
            try await click(identifier)
            try require(model.selectedClipID == clipID && model.selectedZoomID == zoom.id &&
                        model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs == [control.id] &&
                        abs(model.activeLocalTime - control.time) < 0.02,
                        "Clicking an automatic path badge did not select and seek its matching curve control.")
            _ = try frame("editor.zoom.\(zoom.id.uuidString).node.\(target)")
            let grab = center(try frame(identifier))
            let source = try framingSourceFrame()
            let before = zoom.pose(at: control.time)
            let dx = source.width * (before.x <= 0.5 ? 0.045 : -0.045)
            try await dragFramingSlowly(from: grab, to: NSPoint(x: grab.x + dx, y: grab.y))
            guard let edited = model.selectedZoom, let state = model.framingState else {
                throw failure("Dragging an automatic circle control lost its selected segment or overlay.")
            }
            try require(edited.centerPath == path && !edited.manualFocus && edited.centerOffsets?.isEmpty == false,
                        "A native automatic-path drag overwrote its original dense center path or failed to store a correction.")
            try require(model.selectedClipID == clipID && model.selectedZoomID == zoom.id &&
                        model.selectedCameraAnchorIDs == [control.id] &&
                        abs(model.activeLocalTime - control.time) < 0.02 &&
                        abs(edited.pose(at: control.time).x - before.x) > 0.02,
                        "A held native drag changed node identity/time or failed to move its selected control.")
            for neighbor in [controls[target - 1].time, controls[target + 1].time] {
                let middle = (neighbor + control.time) / 2
                let oldMiddle = zoom.pose(at: middle), newMiddle = edited.pose(at: middle)
                try require(abs(newMiddle.x - oldMiddle.x) > 0.003,
                            "Automatic control movement affected only one dense frame instead of its adjacent interval.")
                let oldBoundary = zoom.pose(at: neighbor), newBoundary = edited.pose(at: neighbor)
                try require(abs(newBoundary.x - oldBoundary.x) < 0.000001 &&
                            abs(newBoundary.y - oldBoundary.y) < 0.000001,
                            "Local automatic movement displaced an unchanged neighboring control.")
            }
            for handle in state.handles {
                try require(state.pathSamples.contains(where: {
                    abs($0.time - handle.time) < 0.000001 &&
                        abs($0.x - handle.x) < 0.000001 && abs($0.y - handle.y) < 0.000001
                }), "The visible automatic route missed an exact numbered control center.")
            }
            try require(try persistedClips() == model.clips, "The native automatic-path correction was not saved.")
            try screenshot("framing-automatic-\(scenario)-control-drag")
            try await undo()
            let savedUndo = try persistedClips()
            try require(model.clips == fixture && savedUndo == fixture,
                        "One native Undo did not restore the exact automatic circle and its saved data.")
            record("framing-automatic-\(scenario)-numbered-control-drag", began,
                   "A 30 Hz \(scenario) route exposed real controls; native badge selection and a held mouse drag retained curve identity and original samples, changed both adjacent intervals, kept every handle on the displayed path and saved one undoable correction.")

            try await click("editor.framing.toggle")
            try await waitUntil("The automatic circle did not restore processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            model.clips = original
            model.selectedClipID = previousClipID
            model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "The automatic circular-path fixture left edits behind.")
        }

        func resizeCurrentFrame(radialFactor: CGFloat) async throws {
            let crop = try frame("editor.framing.frame")
            let start = center(try frame("editor.framing.resize.2"))
            let destination = NSPoint(x: crop.midX + (start.x - crop.midX) * radialFactor,
                                      y: crop.midY + (start.y - crop.midY) * radialFactor)
            try await drag(from: start, to: destination)
        }

        func cameraGraphPoint(globalTime: Double, scale: Double) throws -> NSPoint {
            let graph = try frame("editor.zoomGraph")
            let axis = EditorTimeAxisGeometry(containerWidth: graph.width)
            let maximum = 3.05
            return NSPoint(x: graph.minX + axis.x(at: globalTime, total: model.totalDuration),
                           y: graph.maxY - 16 - CGFloat((maximum - scale) / max(0.1, maximum - 1)) * max(1, graph.height - 16 - 18))
        }

        func checkCameraCurveSelection(original: [DemoClip]) async throws {
            guard let targetIndex = original.firstIndex(where: { $0.duration >= 2 }) else {
                throw failure("Curve-selection interactions require a source clip of at least two seconds.")
            }
            let previousClipID = model.selectedClipID
            let previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            let duration = original[targetIndex].duration
            let clipID = original[targetIndex].id
            let offset = model.startTime(of: clipID)
            var fixture = original
            let legacy = ZoomSegment(start: duration * 0.08, riseEnd: duration * 0.25,
                fallStart: duration * 0.72, end: duration * 0.94, peak: 1.6,
                focusX: 0.5, focusY: 0.5, manualFocus: true).normalized()
            fixture[targetIndex].zooms = [legacy]
            model.clips = fixture
            model.selectedClipID = clipID
            model.selectedZoomID = legacy.id
            model.seek(offset + legacy.riseEnd)
            try model.autosave()
            try await model.rebuildPreview()
            try await click("editor.framing.toggle")
            try await waitUntil("Curve-selection fixture did not prepare the raw preview.") {
                self.model.showsFramingOverlay && self.model.isFramingPreviewReady
            }
            var previewItem = model.player.currentItem
            var began = Date()
            let legacyStart = center(try frame("editor.zoom.\(legacy.id.uuidString).node.1"))
            let legacyEnd = try cameraGraphPoint(globalTime: offset + legacy.riseEnd, scale: 2.1)
            try await drag(from: legacyStart, to: legacyEnd)
            guard let independent = model.selectedZoom?.cameraControlPoints else {
                throw failure("Dragging a legacy middle control did not retain camera controls.")
            }
            try require(independent.count == 4 && abs(independent[1].scale - 2.1) < 0.025 &&
                        abs(independent[2].scale - 1.6) < 0.000001 && independent.first?.scale == 1 && independent.last?.scale == 1,
                        "The first legacy middle node still changed the second middle node, or an endpoint's scale.")
            let savedIndependent = try persistedClips()
            try require(model.player.currentItem === previewItem && savedIndependent == model.clips,
                        "An independent legacy middle-node drag replaced raw video or was not saved.")
            try screenshot("curve-independent-legacy-middle")
            try await undo()
            try require(model.clips == fixture && model.selectedZoom?.cameraKeyframes == nil,
                        "One native Undo did not restore the exact legacy curve before independent editing.")
            record("curve-independent-legacy-middle-and-undo", began,
                   "Dragging only the first legacy peak to 2.1× preserved the later 1.6× node and both 1× endpoints; one Command-Z restored the legacy curve.")

            let snapPoints = [CameraKeyframe(time: duration * 0.08, scale: 1),
                              CameraKeyframe(time: duration * 0.25, scale: 1.9),
                              CameraKeyframe(time: duration * 0.72, scale: 1.6),
                              CameraKeyframe(time: duration * 0.94, scale: 1)]
            let snapZoom = ZoomSegment(start: snapPoints[0].time, riseEnd: snapPoints[1].time,
                fallStart: snapPoints[2].time, end: snapPoints[3].time, peak: 1.9,
                focusX: 0.5, focusY: 0.5, manualFocus: true, cameraKeyframes: snapPoints).normalized()
            fixture[targetIndex].zooms = [snapZoom]
            model.clips = fixture
            model.selectedClipID = clipID
            model.selectedZoomID = snapZoom.id
            model.seek(offset + snapPoints[1].time)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            previewItem = model.player.currentItem
            began = Date()
            let scalePerPixel = (3.05 - 1) / (116 - 16 - 18)
            let snapNodeID = "editor.zoom.\(snapZoom.id.uuidString).anchor.\(snapPoints[1].id.uuidString)"
            try await drag(from: center(try frame(snapNodeID)),
                           to: cameraGraphPoint(globalTime: offset + snapPoints[1].time, scale: 1.6 + scalePerPixel * 2))
            guard let snapped = model.selectedZoom?.cameraControlPoints.first(where: { $0.id == snapPoints[1].id }) else {
                throw failure("Magnetic alignment lost its dragged camera node.")
            }
            try require(abs(snapped.scale - 1.6) < 0.000001 &&
                        model.selectedZoom?.cameraControlPoints[2].scale == 1.6,
                        "Dragging within two pixels of another node's horizontal level did not snap exactly to it.")
            let aligned = model.clips
            let releasedScale = 1.6 + scalePerPixel * 14
            try await drag(from: center(try frame(snapNodeID)),
                           to: cameraGraphPoint(globalTime: offset + snapPoints[1].time, scale: releasedScale))
            guard let released = model.selectedZoom?.cameraControlPoints.first(where: { $0.id == snapPoints[1].id }) else {
                throw failure("Leaving magnetic alignment lost its dragged camera node.")
            }
            try require(abs(released.scale - releasedScale) < 0.03 && abs(released.scale - 1.6) > 0.2,
                        "Dragging fourteen pixels away from an aligned level did not release magnetic snapping.")
            let savedMagnetic = try persistedClips()
            try require(model.player.currentItem === previewItem && savedMagnetic == model.clips,
                        "Magnetic curve edits replaced raw video or were not automatically saved.")
            try await undo()
            try require(model.clips == aligned, "One native Undo did not restore the magnetically aligned state.")
            try await undo()
            try require(model.clips == fixture, "The second native Undo did not restore the unsnapped fixture.")
            record("curve-horizontal-snap-and-release", began,
                   "A native node drag two pixels from an existing level aligned exactly; dragging fourteen pixels away released it, and two Undo steps restored each saved state.")

            let groupPoints = [CameraKeyframe(time: 0, scale: 1),
                               CameraKeyframe(time: duration * 0.2, scale: 1.4),
                               CameraKeyframe(time: duration * 0.4, scale: 2.1),
                               CameraKeyframe(time: duration * 0.6, scale: 2.6),
                               CameraKeyframe(time: duration * 0.8, scale: 1.8),
                               CameraKeyframe(time: duration, scale: 1)]
            let groupZoom = ZoomSegment(start: 0, riseEnd: groupPoints[1].time,
                fallStart: groupPoints[4].time, end: duration, peak: 2.6,
                focusX: 0.5, focusY: 0.5, manualFocus: true, cameraKeyframes: groupPoints).normalized()
            fixture[targetIndex].zooms = [groupZoom]
            model.clips = fixture
            model.selectedClipID = clipID
            model.selectedZoomID = groupZoom.id
            model.seek(offset + groupPoints[2].time)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            previewItem = model.player.currentItem
            began = Date()
            let marqueeStart = try cameraGraphPoint(globalTime: offset + duration * 0.15, scale: 1.25)
            let marqueeEnd = try cameraGraphPoint(globalTime: offset + duration * 0.65, scale: 2.75)
            try await drag(from: marqueeStart, to: marqueeEnd)
            try require(model.clips == fixture, "Drawing a node-selection marquee modified camera data.")
            try screenshot("curve-marquee-three-selected")
            let groupNodeID = "editor.zoom.\(groupZoom.id.uuidString).anchor.\(groupPoints[2].id.uuidString)"
            try await drag(from: center(try frame(groupNodeID)),
                           to: cameraGraphPoint(globalTime: offset + duration * 0.46, scale: 2.9))
            guard let raised = model.selectedZoom?.cameraControlPoints else {
                throw failure("Moving marquee-selected nodes lost their camera controls.")
            }
            try require(raised.count == groupPoints.count && abs(raised[3].scale - 3) < 0.000001,
                        "Moving the marquee selection did not stop its highest selected node at 3×.")
            let raiseDelta = raised[1].scale - groupPoints[1].scale
            try require(abs(raiseDelta - 0.4) < 0.000001 && (1...3).allSatisfy({
                abs(raised[$0].scale - groupPoints[$0].scale - raiseDelta) < 0.000001 &&
                    abs(raised[$0].time - groupPoints[$0].time) < 0.000001
            }) && raised[4] == groupPoints[4] && raised.first?.scale == 1 && raised.last?.scale == 1,
                        "Group dragging flattened different heights, moved times, changed an unselected node, or changed endpoint scales.")
            let raisedClips = model.clips
            if CommandLine.arguments.contains("--capture-ui-video") {
                do {
                    try await WindowSnapshots.save(window, to: directory.appendingPathComponent("curve-group-up-actual.png"))
                } catch {
                    events.append(["action": "actual-video-snapshot-failed", "state": "curve-group-up",
                                   "error": error.localizedDescription])
                }
            }
            try await drag(from: center(try frame(groupNodeID)),
                           to: cameraGraphPoint(globalTime: offset + duration * 0.33, scale: 0.5))
            guard let lowered = model.selectedZoom?.cameraControlPoints else {
                throw failure("Lowering the selected group lost its camera controls.")
            }
            let lowerDelta = lowered[1].scale - raised[1].scale
            try require(abs(lowered[1].scale - 1) < 0.000001 && abs(lowerDelta + 0.8) < 0.000001 &&
                        (1...3).allSatisfy({ abs(lowered[$0].scale - raised[$0].scale - lowerDelta) < 0.000001 &&
                            abs(lowered[$0].time - groupPoints[$0].time) < 0.000001 }) &&
                        lowered[4] == groupPoints[4] && lowered.first?.scale == 1 && lowered.last?.scale == 1,
                        "Lowering a group did not stop its lowest node at 1× while preserving every selected height difference.")
            let savedGroup = try persistedClips()
            try require(model.player.currentItem === previewItem && savedGroup == model.clips,
                        "Marquee group dragging replaced raw video or was not saved.")
            try screenshot("curve-group-floor-preserved-differences")
            try await undo()
            try require(model.clips == raisedClips, "One native Undo did not restore the raised group exactly.")
            try await undo()
            try require(model.clips == fixture, "A second native Undo did not restore the original multilevel curve.")
            record("curve-marquee-common-delta-bounds-and-undo", began,
                   "A real background marquee selected three unequal interior nodes; diagonal dragging changed only their common height delta, respected 3×/1× bounds, preserved differences and left endpoints/unselected nodes untouched.")

            began = Date()
            for first in [true, false] {
                let endpoint = first ? groupPoints[0] : groupPoints[groupPoints.count - 1]
                let startTime = first ? duration * 0.07 : duration * 0.93
                try await drag(from: cameraGraphPoint(globalTime: offset + startTime, scale: 0.65),
                               to: cameraGraphPoint(globalTime: offset + endpoint.time, scale: 1.3))
                try require(model.editingSelectionTarget == .cameraAnchors &&
                            model.selectedCameraAnchorIDs == [endpoint.id] && !model.canDeleteSelection && model.clips == fixture,
                            "A native marquee did not select and highlight only its protected \(first ? "first" : "last") endpoint.")
                let endpointID = "editor.zoom.\(groupZoom.id.uuidString).anchor.\(endpoint.id.uuidString)"
                if let value = accessibilityElements().first(where: { $0.accessibilityIdentifier() == endpointID })?.accessibilityValue() as? String {
                    try require(value.contains("已选择"), "The marquee-selected protected endpoint did not expose its selected highlight state.")
                }
                try await deleteKey()
                try require(model.clips == fixture && model.selectedCameraAnchorIDs == [endpoint.id],
                            "Delete changed data or cleared selection on a protected marquee endpoint.")
            }
            try screenshot("curve-marquee-last-endpoint-selected")
            record("curve-marquee-protected-first-and-last-endpoints", began,
                   "Native background rectangles selected each 1× endpoint independently, exposed its selected state and kept both data and highlight when Delete was pressed.")

            began = Date()
            let mixedIDs: Set<UUID> = [groupPoints[4].id, groupPoints[5].id]
            try await drag(from: cameraGraphPoint(globalTime: offset + duration * 0.73, scale: 0.65),
                           to: cameraGraphPoint(globalTime: offset + duration, scale: 2.0))
            try require(model.selectedCameraAnchorIDs == mixedIDs && model.canDeleteSelection && model.clips == fixture,
                        "A native marquee did not select the last endpoint together with only its neighboring interior node.")
            let mixedNodeID = "editor.zoom.\(groupZoom.id.uuidString).anchor.\(groupPoints[4].id.uuidString)"
            try await drag(from: center(try frame(mixedNodeID)),
                           to: cameraGraphPoint(globalTime: offset + groupPoints[4].time, scale: 2.35))
            guard let mixedRaised = model.selectedZoom?.cameraControlPoints else {
                throw failure("Dragging a mixed endpoint/interior selection lost the camera curve.")
            }
            try require(mixedRaised.count == groupPoints.count && model.selectedCameraAnchorIDs == mixedIDs &&
                        mixedRaised[4].scale > groupPoints[4].scale + 0.25 &&
                        mixedRaised.first?.scale == 1 && mixedRaised.last?.scale == 1 &&
                        mixedRaised.indices.allSatisfy({ abs(mixedRaised[$0].time - groupPoints[$0].time) < 0.000001 }) &&
                        (0...3).allSatisfy({ mixedRaised[$0] == groupPoints[$0] }),
                        "Mixed group dragging raised a protected endpoint, failed to raise the interior node, or changed another node/time.")
            let mixedRaisedClips = model.clips
            try await deleteKey()
            guard let mixedDeleted = model.selectedZoom?.cameraControlPoints else {
                throw failure("Deleting a mixed endpoint/interior selection removed its zoom.")
            }
            try require(model.clips.count == fixture.count && mixedDeleted.count == groupPoints.count - 1 &&
                        mixedDeleted.map(\.id) == groupPoints.filter { $0.id != groupPoints[4].id }.map(\.id) &&
                        mixedDeleted.first?.scale == 1 && mixedDeleted.last?.scale == 1 &&
                        model.player.currentItem === previewItem && (try persistedClips()) == model.clips,
                        "Delete on a mixed marquee did not preserve its protected endpoints and remove only the interior node.")
            try await undo()
            try require(model.clips == mixedRaisedClips && model.selectedCameraAnchorIDs == mixedIDs,
                        "One Undo did not restore the deleted interior node and its mixed endpoint selection.")
            try await undo()
            try require(model.clips == fixture && model.selectedCameraAnchorIDs == mixedIDs &&
                        (try persistedClips()) == fixture && model.player.currentItem === previewItem,
                        "The second Undo did not restore the mixed group's original amplitudes, selection and saved data.")
            record("curve-marquee-mixed-endpoint-group-drag-delete-undo", began,
                   "A rectangle selected the final 1× endpoint and its neighboring interior node; upward dragging raised only the interior amplitude, Delete removed only that node and two Undo steps restored data and mixed selection.")

            try await click("editor.framing.toggle")
            try await waitUntil("Curve-selection tests did not restore processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            model.clips = original
            model.selectedClipID = previousClipID
            model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Curve-selection fixture left content edits behind.")
        }

        func persistedClips() throws -> [DemoClip] {
            guard let folder = model.projectURL else { throw failure("UI fixture has no saved project URL.") }
            return try JSONDecoder().decode(RecordingProject.self,
                from: Data(contentsOf: folder.appendingPathComponent("project.json"))).clips
        }

        func checkTargetAwareDelete(original: [DemoClip]) async throws {
            guard let sourceClip = original.first(where: { $0.duration >= 2 }), original.count >= 2 else {
                throw failure("Target-aware Delete requires two source clips and one clip of at least two seconds.")
            }
            let previousClipID = model.selectedClipID
            let previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            let duration = sourceClip.duration
            let controls = [CameraKeyframe(time: duration * 0.08, scale: 1),
                            CameraKeyframe(time: duration * 0.25, scale: 1.6),
                            CameraKeyframe(time: duration * 0.45, scale: 2),
                            CameraKeyframe(time: duration * 0.68, scale: 1.8),
                            CameraKeyframe(time: duration * 0.82, scale: 1.4),
                            CameraKeyframe(time: duration * 0.94, scale: 1)]
            let centers = [ZoomCenterPoint(time: controls[0].time, x: 0.5, y: 0.5),
                           ZoomCenterPoint(time: controls[1].time, x: 0.43, y: 0.46),
                           ZoomCenterPoint(time: controls[2].time, x: 0.57, y: 0.4),
                           ZoomCenterPoint(time: controls[3].time, x: 0.53, y: 0.57),
                           ZoomCenterPoint(time: controls[4].time, x: 0.45, y: 0.53),
                           ZoomCenterPoint(time: controls[5].time, x: 0.5, y: 0.5)]
            let zoom = ZoomSegment(start: controls[0].time, riseEnd: controls[1].time,
                fallStart: controls[4].time, end: controls[5].time, peak: 2,
                focusX: 0.5, focusY: 0.5, manualFocus: true,
                manualCenterPath: centers, cameraKeyframes: controls).normalized()
            var onlyClip = sourceClip
            onlyClip.zooms = [zoom]
            let oneClip = [onlyClip]
            model.clips = oneClip
            model.select(onlyClip.id)
            model.selectedZoomID = zoom.id
            model.seek(controls[2].time)
            try model.autosave()
            try await model.rebuildPreview()
            try await click("editor.framing.toggle")
            try await waitUntil("Target-aware Delete did not prepare its framing preview.") {
                self.model.isFramingPreviewReady && self.model.framingState?.canSelectAnchors == true
            }
            let sourceURL = model.sourceURL
            let projectURL = model.projectURL
            var previewItem = model.player.currentItem
            var began = Date()
            let handleID = try cameraHandleIdentifier(at: controls[2].time)
            try await click(handleID)
            try require(model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs.contains(controls[2].id) && model.canDeleteSelection,
                        "A native path badge did not focus its deletable camera anchor.")
            try requireTimelineFocus(onlyClip.id, selected: false)
            try await deleteKey()
            guard let afterNodeDelete = model.selectedZoom else {
                throw failure("Deleting a path anchor removed its containing zoom or clip.")
            }
            var expected = oneClip
            expected[0].zooms = [afterNodeDelete]
            try require(model.clips == expected && model.clips.count == 1 &&
                        model.totalDuration == duration && model.sourceURL == sourceURL && model.projectURL == projectURL,
                        "Deleting a path badge modified the clip, media reference or timeline duration.")
            try require(afterNodeDelete.cameraControlPoints == controls.filter { $0.id != controls[2].id } &&
                        afterNodeDelete.manualCenterPath == centers &&
                        !afterNodeDelete.framingKeyframes.contains(where: { abs($0.time - controls[2].time) < 0.000001 }),
                        "Delete did not remove its visible node while retaining the original movement data.")
            try requireStraightPan(afterNodeDelete, before: zoom, from: controls[1].time, to: controls[3].time)
            let savedNodeDelete = try persistedClips()
            try require(savedNodeDelete == model.clips && model.player.currentItem === previewItem,
                        "Deleting a camera anchor did not save or unnecessarily reloaded raw video.")
            try await undo()
            try require(model.clips == oneClip && model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs.contains(controls[2].id),
                        "Undo did not restore the path anchor and its camera editing focus.")
            try await click(try cameraHandleIdentifier(at: controls[2].time))
            try await deleteKey()
            try require(model.clips.count == 1 && model.selectedZoom?.cameraControlPoints.contains(where: { $0.id == controls[2].id }) == false,
                        "Deleting a restored/reselected camera anchor fell back to deleting its clip.")
            try await undo()
            try require(model.clips == oneClip, "Repeated camera Delete/Undo did not restore exact content.")
            try await click(try cameraHandleIdentifier(at: controls[2].time))
            try await deleteKey(forward: true)
            try require(model.clips.count == 1 && model.selectedZoom?.cameraControlPoints.contains(where: { $0.id == controls[2].id }) == false,
                        "Forward Delete did not remove the selected camera anchor without deleting its clip.")
            try await undo()
            try require(model.clips == oneClip, "Forward Delete/Undo did not restore exact camera content.")
            do {
                guard let contentView = window.contentView else { throw failure("The text-editing Delete check has no content view.") }
                let previousResponder = window.firstResponder
                let field = NSTextField(frame: NSRect(x: 40, y: 40, width: 120, height: 24))
                field.isEditable = true
                field.isSelectable = true
                field.stringValue = "AB"
                contentView.addSubview(field)
                defer {
                    window.makeFirstResponder(previousResponder)
                    field.removeFromSuperview()
                }
                try require(window.makeFirstResponder(field), "The native text field could not become first responder.")
                field.selectText(nil)
                guard let editor = window.firstResponder as? NSTextView, editor.isEditable else {
                    throw failure("The text field did not install an editable native field editor.")
                }
                editor.setSelectedRange(NSRange(location: 2, length: 0))
                let beforeTextDelete = model.clips
                try await deleteKey()
                try require(editor.string == "A" && model.clips == beforeTextDelete,
                            "Delete in an editable native text field did not delete only text, or also modified the project.")
                try require(window.makeFirstResponder(previousResponder), "The native text check could not restore its previous first responder.")
                try require(field.stringValue == "A" && model.clips == oneClip,
                            "Ending native text editing did not preserve its text change and unchanged project.")
            }
            record("delete-preview-path-anchor-keeps-single-clip", began,
                   "A numbered preview point focused camera editing; Delete and Forward Delete removed only that node even with one clip, with saved Undo. Delete in an editable native text field changed only text and restored the prior responder.")

            began = Date()
            let marqueeStart = try cameraGraphPoint(globalTime: duration * 0.17, scale: 1.35)
            let marqueeEnd = try cameraGraphPoint(globalTime: duration * 0.55, scale: 2.25)
            try await drag(from: marqueeStart, to: marqueeEnd)
            let deletedIDs: Set<UUID> = [controls[1].id, controls[2].id]
            try require(model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs == deletedIDs && model.canDeleteSelection,
                        "A native marquee did not focus exactly its two deletable interior camera nodes.")
            try requireTimelineFocus(onlyClip.id, selected: false)
            try await click("editor.preview.delete")
            guard let afterGroupDelete = model.selectedZoom else {
                throw failure("The preview trash button removed the zoom containing a selected node group.")
            }
            try require(model.clips.count == 1 && model.totalDuration == duration &&
                        afterGroupDelete.cameraControlPoints == controls.filter { !deletedIDs.contains($0.id) } &&
                        afterGroupDelete.manualCenterPath == centers,
                        "Preview trash did not delete only the marquee-selected camera nodes in a one-clip project.")
            try requireStraightPan(afterGroupDelete, before: zoom, from: controls[0].time, to: controls[3].time)
            let savedGroupDelete = try persistedClips()
            try require(savedGroupDelete == model.clips && model.player.currentItem === previewItem,
                        "Deleting a camera-node group did not save or reloaded its raw video.")
            try await undo()
            try require(model.clips == oneClip && model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs == deletedIDs,
                        "One Undo did not restore the deleted camera-node group and focused selection.")
            record("delete-marquee-group-uses-preview-trash", began,
                   "A real marquee selected two camera points; preview trash removed those points and their matching position controls while keeping the sole clip, with one saved Undo.")

            began = Date()
            let legacyTimes = (0...8).map { zoom.start + (zoom.end - zoom.start) * Double($0) / 8 }
            let legacyPath = legacyTimes.enumerated().map { index, time in
                ZoomCenterPoint(time: time, x: 0.43 + Double(index % 3) * 0.055,
                                y: 0.44 + Double(index % 4) * 0.035)
            }
            let legacyZoom = ZoomSegment(start: zoom.start, riseEnd: zoom.riseEnd,
                fallStart: zoom.fallStart, end: zoom.end, peak: 1.8,
                centerPath: legacyPath, manualFocus: false).normalized()
            var legacyClip = sourceClip
            legacyClip.zooms = [legacyZoom]
            model.clips = [legacyClip]
            model.select(legacyClip.id)
            model.selectedZoomID = legacyZoom.id
            model.seek(duration * 0.45)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            previewItem = model.player.currentItem
            guard let sampledHandle = model.framingState?.handles.first(where: { handle in
                handle.time > legacyZoom.start && handle.time < legacyZoom.end && legacyZoom.scale(at: handle.time) > 1.000001
            }), let sampledControl = legacyZoom.cameraControlPoints.first(where: {
                abs($0.time - sampledHandle.time) < 0.000001
            }) else { throw failure("The automatic fixture did not expose an interior camera control.") }
            try await click(try cameraHandleIdentifier(at: sampledHandle.time))
            try require(model.editingSelectionTarget == .cameraAnchors &&
                        model.selectedCameraAnchorIDs == [sampledControl.id] && model.canDeleteSelection,
                        "Clicking an automatic path point did not focus its corresponding camera control.")
            try await deleteKey()
            guard let afterSampleDelete = model.selectedZoom else { throw failure("Delete removed a legacy sample's containing zoom.") }
            try require(model.clips.count == 1 && model.totalDuration == duration &&
                        afterSampleDelete.cameraControlPoints == legacyZoom.cameraControlPoints.filter { $0.id != sampledControl.id } &&
                        afterSampleDelete.centerPath == legacyPath,
                        "Deleting an automatic camera control changed retained source samples, duration, clip count or unrelated controls.")
            let sampledIndex = legacyZoom.cameraControlPoints.firstIndex { $0.id == sampledControl.id }!
            try requireStraightPan(afterSampleDelete, before: legacyZoom,
                from: legacyZoom.cameraControlPoints[sampledIndex - 1].time,
                to: legacyZoom.cameraControlPoints[sampledIndex + 1].time)
            let savedSampleDelete = try persistedClips()
            try require(savedSampleDelete == model.clips && model.player.currentItem === previewItem,
                        "Deleting a sampled movement point failed to save or reloaded raw video.")
            try await undo()
            try require(model.clips == [legacyClip], "One Undo did not restore the exact legacy movement samples.")
            record("delete-automatic-camera-control-keeps-source-path", began,
                   "A native path-badge click and Delete removed only its matching camera control while retaining every original automatic center sample; one Undo restored the exact data.")

            began = Date()
            var twoClips = original
            guard let clipIndex = twoClips.firstIndex(where: { $0.id == sourceClip.id }) else {
                throw failure("The original clip disappeared before focus-return verification.")
            }
            twoClips[clipIndex].zooms = [zoom]
            model.clips = twoClips
            model.select(sourceClip.id)
            model.selectedZoomID = zoom.id
            model.seek(model.startTime(of: sourceClip.id) + controls[2].time)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            let endpointID = "editor.zoom.\(zoom.id.uuidString).anchor.\(controls[0].id.uuidString)"
            try await click(endpointID)
            try require(model.editingSelectionTarget == .cameraAnchors && !model.canDeleteSelection,
                        "A protected 1× endpoint did not retain non-deletable camera focus.")
            try await deleteKey()
            try require(model.clips == twoClips, "Delete on a protected camera endpoint fell back to deleting a clip.")
            let blankPoint = try cameraGraphPoint(globalTime: model.startTime(of: sourceClip.id) + duration * 0.01, scale: 2.4)
            try await click(at: blankPoint)
            try require(model.editingSelectionTarget == .cameraAnchors && model.selectedCameraAnchorIDs.isEmpty &&
                        model.selectedMotionPointTime == nil && !model.canDeleteSelection,
                        "A blank graph click did not clear camera points while retaining camera focus.")
            try await deleteKey()
            try require(model.clips == twoClips, "Delete with empty camera selection fell back to the contextual clip.")
            try requireTimelineFocus(sourceClip.id, selected: false)
            for keyboard in [false, true] {
                try await click(at: center(try clipFrame(sourceClip.id)))
                try require(model.editingSelectionTarget == .clip && model.selectedClipID == sourceClip.id &&
                            model.selectedCameraAnchorIDs.isEmpty && model.selectedMotionPointTime == nil && model.canDeleteSelection,
                            "Clicking the same contextual timeline clip did not restore clip Delete focus.")
                try requireTimelineFocus(sourceClip.id, selected: true)
                if keyboard { try await deleteKey() }
                else { try await click("editor.preview.delete") }
                try require(model.clips == twoClips.filter { $0.id != sourceClip.id },
                            "An explicit timeline selection did not delete the clip through its active Delete control.")
                try await undo()
                try require(model.clips == twoClips && model.editingSelectionTarget == .clip,
                            "One Undo did not restore the explicitly deleted clip and clip focus.")
            }
            record("delete-protected-empty-camera-and-explicit-clip-focus", began,
                   "Delete on a protected endpoint or empty camera selection kept both clips; clicking the same timeline clip restored clip focus, then both trash and keyboard Delete removed only that clip with one Undo.")

            try await click("editor.framing.toggle")
            try await waitUntil("Target-aware Delete tests did not restore processed preview.") {
                !self.model.showsFramingOverlay && self.model.previewCameraEffectsEnabled
            }
            model.clips = original
            if let previousClipID { model.select(previousClipID) }
            else { model.selectedClipID = nil }
            model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Target-aware Delete fixtures left edits behind.")
        }

        func requireStraightPan(_ zoom: ZoomSegment, before: ZoomSegment, from lower: Double, to upper: Double) throws {
            let a = before.pose(at: lower), b = before.pose(at: upper)
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            var previous = -0.0000001
            for fraction in stride(from: 0.0, through: 1.0, by: 0.02) {
                let pose = zoom.pose(at: lower + (upper - lower) * fraction)
                let x = pose.x - a.x, y = pose.y - a.y
                let progress = length > 0.000000001 ? (x * dx + y * dy) / length : 0
                try require(abs(x * dy - y * dx) < 0.000001 && progress >= previous - 0.000001 &&
                            progress >= -0.000001 && progress <= 1.000001,
                            "Native node deletion did not replace its surviving neighbors' route with one straight, forward pan.")
                previous = progress
            }
        }

        func checkCameraTargetNavigation(original: [DemoClip]) async throws {
            guard original.count >= 2, original[0].duration > 0.2, original[1].duration > 0.2 else {
                throw failure("Camera navigation requires two nonempty source clips.")
            }
            let began = Date()
            let previousClipID = model.selectedClipID, previousZoomID = model.selectedZoomID
            let previousTime = model.playhead
            var fixture = original
            for index in fixture.indices { fixture[index].zooms = [] }
            func zoom(duration: Double) -> ZoomSegment {
                let controls = [CameraKeyframe(time: 0, scale: 1), CameraKeyframe(time: duration * 0.25, scale: 1.6),
                    CameraKeyframe(time: duration * 0.6, scale: 1.6), CameraKeyframe(time: duration, scale: 1)]
                return ZoomSegment(start: 0, riseEnd: duration * 0.25, fallStart: duration * 0.6,
                    end: duration, peak: 1.6, manualFocus: true, cameraKeyframes: controls).normalized()
            }
            let firstZoom = zoom(duration: fixture[0].duration), secondZoom = zoom(duration: fixture[1].duration)
            let firstControls = firstZoom.cameraControlPoints, secondControls = secondZoom.cameraControlPoints
            fixture[0].zooms = [firstZoom]; fixture[1].zooms = [secondZoom]
            model.clips = fixture
            model.selectedClipID = fixture[0].id; model.selectedZoomID = firstZoom.id
            model.seek(fixture[0].duration * 0.125)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(!model.showsFramingOverlay, "Camera navigation should be tested with framing assistance off.")
            guard let folder = model.projectURL else { throw failure("Camera navigation has no project folder.") }
            let jsonURL = folder.appendingPathComponent("project.json")
            let jsonBefore = try Data(contentsOf: jsonURL)
            let canUndoBefore = model.canUndo
            window.makeFirstResponder(window.contentView)
            try await arrowKey(forward: true)
            try require(abs(model.playhead - firstControls[1].time) < 0.000001 && model.selectedClipID == fixture[0].id &&
                        model.selectedCameraAnchorIDs == [firstControls[1].id] && model.editingSelectionTarget == .cameraAnchors,
                        "Native Down did not select and seek the nearest camera node with framing assistance off.")
            try await arrowKey(forward: false)
            try require(model.playhead == 0, "Native Up did not seek the preceding protected start node.")
            try await arrowKey(forward: false)
            try require(model.playhead == 0, "Native Up looped from the first target.")
            for target in [firstControls[1].time, firstControls[2].time, fixture[0].duration,
                           fixture[0].duration + secondControls[1].time] {
                try await arrowKey(forward: true)
                try require(abs(model.playhead - target) < 0.000001 && model.selectedClipID == model.activeClip?.id,
                            "Native Down repeated/skipped a global target or selected a clip different from the displayed frame.")
                if abs(target - fixture[0].duration) < 0.000001 {
                    try require(model.selectedClipID == fixture[1].id &&
                                model.selectedCameraAnchorIDs == [secondControls[0].id],
                                "Join navigation selected the preceding clip's end instead of the following clip's displayed start node.")
                }
            }
            try require(model.selectedClipID == fixture[1].id && model.selectedZoomID == secondZoom.id &&
                        model.selectedCameraAnchorIDs == [secondControls[1].id],
                        "Cross-clip keyboard navigation did not synchronize camera selection.")
            let modifierTime = model.playhead, modifierSelection = model.selectedCameraAnchorIDs
            try await arrowKey(forward: false, modifiers: .shift)
            try require(model.playhead == modifierTime && model.selectedCameraAnchorIDs == modifierSelection,
                        "Shift plus an arrow key triggered plain camera navigation.")
            do {
                guard let content = window.contentView else { throw failure("Navigation text check has no content view.") }
                let previousResponder = window.firstResponder
                let field = NSTextField(frame: NSRect(x: 40, y: 40, width: 140, height: 24))
                field.isEditable = true; field.isSelectable = true; field.stringValue = "AB"
                content.addSubview(field)
                defer { window.makeFirstResponder(previousResponder); field.removeFromSuperview() }
                try require(window.makeFirstResponder(field), "Navigation text field could not become first responder.")
                field.selectText(nil)
                let timeBefore = model.playhead, selectionBefore = model.selectedCameraAnchorIDs
                try await arrowKey(forward: false)
                try require(model.playhead == timeBefore && model.selectedCameraAnchorIDs == selectionBefore,
                            "Arrow key in an editable text field navigated the video.")
            }
            model.seek(model.totalDuration)
            try await arrowKey(forward: true)
            try require(model.playhead == model.totalDuration && model.clips == fixture && model.canUndo == canUndoBefore &&
                        (try Data(contentsOf: jsonURL)) == jsonBefore,
                        "Native navigation looped, edited content, created Undo or rewrote project JSON.")
            record("keyboard-global-camera-target-navigation", began,
                   "Native Up/Down sought and selected chronological camera nodes across clip boundaries with assistance off, deduplicated joins, clamped endpoints, respected text editing and left source data/JSON/Undo unchanged.")
            model.clips = original; model.selectedClipID = previousClipID; model.selectedZoomID = previousZoomID
            model.seek(previousTime)
            try model.autosave()
            try await model.rebuildPreview()
            await refreshDisplayedLayout()
            try require(model.clips == original, "Camera navigation fixture left edits behind.")
        }

        func cameraHandleIdentifier(at time: Double) throws -> String {
            guard let index = model.framingState?.handles.firstIndex(where: { abs($0.time - time) < 0.000001 }) else {
                throw failure("The requested movement time is not exposed as a native path badge.")
            }
            return "editor.framing.handle.\(index)"
        }

        func requireTimelineFocus(_ clipID: UUID, selected: Bool) throws {
            try require((model.editingSelectionTarget == .clip && model.selectedClipID == clipID) == selected,
                        "The timeline's effective highlight does not match the active editing target.")
            if let clipElement = accessibilityElements().first(where: { $0.accessibilityIdentifier() == "editor.clip.\(clipID.uuidString)" }),
               let value = clipElement.accessibilityValue() as? String {
                try require(value.contains(selected ? "已选择" : "未选择"),
                            "The timeline's native accessibility selection value disagrees with its editing focus.")
            }
        }

        func framingFrameGrabPoint() throws -> NSPoint {
            let crop = try frame("editor.framing.frame")
            let preview = try frame("editor.preview.surface")
            let handles = try (model.framingState?.handles.indices ?? 0..<0).map {
                try frame("editor.framing.handle.\($0)").insetBy(dx: -3, dy: -3)
            }
            for (x, y) in [(0.3, 0.7), (0.7, 0.7), (0.3, 0.4), (0.7, 0.4), (0.5, 0.7)] {
                let point = NSPoint(x: crop.minX + crop.width * x, y: crop.minY + crop.height * y)
                if point.y > preview.minY + 60 && crop.insetBy(dx: 8, dy: 8).contains(point) &&
                    !handles.contains(where: { $0.contains(point) }) { return point }
            }
            throw failure("No framing-frame interior target avoids path handles and preview controls.")
        }

        func framingSourceFrame() throws -> NSRect {
            let preview = try frame("editor.preview.surface")
            let pixels = model.sourcePixelSize
            guard pixels.width > 0, pixels.height > 0 else { throw failure("Raw preview has no source dimensions.") }
            let fit = min(preview.width / pixels.width, preview.height / pixels.height)
            let size = NSSize(width: pixels.width * fit, height: pixels.height * fit)
            return NSRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2,
                          width: size.width, height: size.height)
        }

        @MainActor
        final class FullScreenSignal {
            var completed = false
        }

        func clickFullScreen(enter: Bool) async throws {
            let expected: Notification.Name = enter ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
            let signal = FullScreenSignal()
            let names: [Notification.Name] = [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                                              NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification]
            // Register before the native click; styleMask changes before AppKit's
            // animation completes and cannot serve as a completion signal.
            let observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.recordFullScreen(notification.name.rawValue)
                        if notification.name == expected { signal.completed = true }
                    }
                }
            }
            defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
            recordFullScreen(enter ? "click-request-enter" : "click-request-exit")
            try await click("editor.preview.fullscreen", delay: 0.05)
            let deadline = Date().addingTimeInterval(10)
            while !signal.completed, Date() < deadline { await settle(0.05) }
            guard signal.completed else {
                recordFullScreen("timeout-waiting-for-\(expected.rawValue)")
                throw failure("Native fullscreen click did not produce \(expected.rawValue) within 10 seconds.")
            }
            try require(window.styleMask.contains(.fullScreen) == enter,
                        "Fullscreen completion notification disagreed with the window style mask.")
        }

        func recordFullScreen(_ name: String) {
            fullScreenNotifications.append(["event": name, "at": ISO8601DateFormatter().string(from: Date()),
                "millisecondsSinceStart": String(format: "%.3f", Date().timeIntervalSince(started) * 1000),
                "styleMask": "\(window.styleMask.rawValue)", "fullScreen": "\(window.styleMask.contains(.fullScreen))"])
        }

        func seekUsingRuler(fraction: CGFloat) async throws {
            let ruler = try frame("editor.timeline.ruler")
            try await click(at: NSPoint(x: ruler.minX + ruler.width * fraction, y: ruler.midY))
        }

        func undo() async throws {
            try await ensureActiveAndKeyWindow()
            try requireInputFocus()
            let now = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                    timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "z",
                    charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) else {
                    throw failure("Could not construct native Command-Z events.")
                }
                NSApp.postEvent(event, atStart: false)
            }
            events.append(["action": "keyboard", "key": "Command-Z", "isActive": "\(NSApp.isActive)",
                           "isKeyWindow": "\(window.isKeyWindow)"])
            await settle(0.16)
        }

        func deleteKey(forward: Bool = false) async throws {
            try await ensureActiveAndKeyWindow()
            try requireInputFocus()
            let now = ProcessInfo.processInfo.systemUptime
            let character = forward ? "\u{f728}" : "\u{7f}"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: forward ? 117 : 51) else {
                    throw failure("Could not construct native Delete key events.")
                }
                NSApp.postEvent(event, atStart: false)
            }
            events.append(["action": "keyboard", "key": forward ? "Forward Delete" : "Delete", "isActive": "\(NSApp.isActive)",
                           "isKeyWindow": "\(window.isKeyWindow)", "editingSelectionTarget": "\(model.editingSelectionTarget)"])
            await settle(0.16)
        }

        func arrowKey(forward: Bool, modifiers: NSEvent.ModifierFlags = []) async throws {
            try await ensureActiveAndKeyWindow()
            try requireInputFocus()
            let now = ProcessInfo.processInfo.systemUptime
            let character = forward ? "\u{f701}" : "\u{f700}"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: now, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: forward ? 125 : 126) else {
                    throw failure("Could not construct native arrow-key events.")
                }
                NSApp.postEvent(event, atStart: false)
            }
            events.append(["action": "keyboard", "key": forward ? "Down" : "Up", "modifiers": "\(modifiers.rawValue)", "isActive": "\(NSApp.isActive)",
                           "isKeyWindow": "\(window.isKeyWindow)"])
            await settle(0.16)
        }

        func ensureActiveAndKeyWindow() async throws {
            let activationAccepted = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await nextRunLoopTurn()
            let deadline = Date().addingTimeInterval(1)
            while (!NSApp.isActive || !window.isKeyWindow), Date() < deadline { await settle(0.02) }
            events.append(["action": "input-focus-setup", "activationAccepted": "\(activationAccepted)",
                           "isActive": "\(NSApp.isActive)", "isKeyWindow": "\(window.isKeyWindow)",
                           "frontmostApplication": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"])
            try requireInputFocus()
        }

        func requireInputFocus() throws {
            try requireNoRuntimeErrors()
            guard NSApp.isActive, window.isKeyWindow else {
                failurePhase = "input-setup"
                throw RecorderError.message("Editor UI setup failed: the OS did not give the app active/key-window focus; native input was not sent (active=\(NSApp.isActive), key=\(window.isKeyWindow)).")
            }
        }

        func requireNoRuntimeErrors() throws {
            guard runtimeErrors.isEmpty else {
                failurePhase = "runtime-error"
                throw failure("Editor model reported a runtime error: \(runtimeErrors.joined(separator: " | ")).")
            }
        }

        func nextRunLoopTurn() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
            }
        }

        func refreshDisplayedLayout() async {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            await nextRunLoopTurn()
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            events.append(["action": "layout-after-undo", "clipOrder": model.clips.map { $0.id.uuidString }.joined(separator: ",")])
        }

        func click(_ identifier: String, delay: Double = 0.16) async throws {
            try await click(at: center(try frame(identifier)), delay: delay)
        }

        func click(at point: NSPoint, delay: Double = 0.16) async throws {
            try await ensureActiveAndKeyWindow()
            try postMouse([(.leftMouseDown, point), (.leftMouseUp, point)])
            await settle(delay)
        }

        func drag(from start: NSPoint, to end: NSPoint, delay: Double = 0.16) async throws {
            try await ensureActiveAndKeyWindow()
            var sequence: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            for index in 1...12 {
                let fraction = CGFloat(index) / 12
                sequence.append((.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * fraction,
                                                            y: start.y + (end.y - start.y) * fraction)))
            }
            sequence.append((.leftMouseUp, end))
            // Queue the complete gesture before yielding: synchronous AppKit tracking
            // loops can then consume dragged/up events without blocking the test task.
            try postMouse(sequence)
            await settle(delay)
        }

        func dragFramingSlowly(from start: NSPoint, to end: NSPoint) async throws {
            try await ensureActiveAndKeyWindow()
            guard let previewItem = model.player.currentItem else {
                throw failure("Slow framing drag has no prepared raw player item.")
            }
            try postMouse([(.leftMouseDown, start)])
            // Unlike SwiftUI's synchronous tracking controls, the preview NSView
            // returns from mouseDown. Yield between real moves so preview rebuilds
            // and selection changes cannot be hidden by one queued event burst.
            for index in 1...12 {
                await settle(0.03)
                try require(model.player.currentItem === previewItem,
                            "A held framing drag rebuilt its raw video player item.")
                let fraction = CGFloat(index) / 12
                try postMouse([(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * fraction,
                                                         y: start.y + (end.y - start.y) * fraction))])
            }
            try postMouse([(.leftMouseUp, end)])
            await settle(0.16)
            try require(model.player.currentItem === previewItem,
                        "Committing a slow framing drag rebuilt its raw video player item.")
        }

        func postMouse(_ sequence: [(NSEvent.EventType, NSPoint)]) throws {
            try requireInputFocus()
            let timestamp = ProcessInfo.processInfo.systemUptime
            var nativeEvents: [NSEvent] = []
            for (index, item) in sequence.enumerated() {
                eventNumber += 1
                guard let event = NSEvent.mouseEvent(with: item.0, location: item.1, modifierFlags: [],
                    timestamp: timestamp + Double(index) * 0.008, windowNumber: window.windowNumber,
                    context: nil, eventNumber: eventNumber, clickCount: 1, pressure: item.0 == .leftMouseUp ? 0 : 1) else {
                    throw failure("Could not construct the native mouse event sequence.")
                }
                nativeEvents.append(event)
            }
            for event in nativeEvents { NSApp.postEvent(event, atStart: false) }
            if let first = sequence.first, let last = sequence.last {
                events.append(["action": sequence.count > 2 ? "drag" : "click",
                               "start": "\(first.1.x),\(first.1.y)", "end": "\(last.1.x),\(last.1.y)",
                               "isActive": "\(NSApp.isActive)", "isKeyWindow": "\(window.isKeyWindow)",
                               "eventCount": "\(sequence.count)"])
            }
        }

        func actualViewFrame(_ identifier: String) throws -> NSRect {
            guard let view = accessibilityElements().compactMap({ $0 as? NSView }).first(where: {
                $0.accessibilityIdentifier() == identifier && $0.window === window
            }), !view.isHiddenOrHasHiddenAncestor else {
                throw failure("Missing actual visible native view for \(identifier); visible-layout evidence cannot use a computed fallback.")
            }
            let drawnBounds = view.convert(view.bounds, to: nil)
            let actual = try actualAccessibilityFrame(identifier)
            try require(view.visibleRect.width > 0 && view.visibleRect.height > 0 &&
                        abs(actual.minX - drawnBounds.minX) <= 1 && abs(actual.maxX - drawnBounds.maxX) <= 1 &&
                        abs(actual.minY - drawnBounds.minY) <= 1 && abs(actual.maxY - drawnBounds.maxY) <= 1,
                        "Native view bounds and its actual accessibility frame disagree for \(identifier): bounds=\(drawnBounds), AX=\(actual).")
            resolvedTargets[identifier] = ["source": "actual native NSView drawing bounds verified against accessibility",
                "viewClass": String(describing: type(of: view)), "windowFrame": NSStringFromRect(actual)]
            return actual
        }

        func optionalActualAccessibilityFrame(_ identifier: String) -> NSRect? {
            guard let item = accessibilityElements().first(where: { $0.accessibilityIdentifier() == identifier }) else { return nil }
            let rect = window.convertFromScreen(item.accessibilityFrame())
            guard rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
                  rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
            resolvedTargets[identifier] = ["source": "actual accessibility frame; no layout fallback", "windowFrame": NSStringFromRect(rect)]
            return rect
        }

        func actualAccessibilityFrame(_ identifier: String) throws -> NSRect {
            guard let item = accessibilityElements().first(where: { $0.accessibilityIdentifier() == identifier }) else {
                throw failure("Missing actual accessibility element for \(identifier); visible-layout evidence cannot use a computed fallback.")
            }
            let rect = window.convertFromScreen(item.accessibilityFrame())
            guard rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
                  rect.maxX.isFinite, rect.maxY.isFinite else {
                throw failure("Invalid actual accessibility frame for \(identifier): \(rect).")
            }
            resolvedTargets[identifier] = ["source": "actual accessibility frame; no layout fallback", "windowFrame": NSStringFromRect(rect)]
            return rect
        }

        func frame(_ identifier: String) throws -> NSRect {
            let rect: NSRect
            let source: String
            if let item = accessibilityElements().first(where: { $0.accessibilityIdentifier() == identifier }),
               item.accessibilityFrame().width > 0, item.accessibilityFrame().height > 0 {
                rect = window.convertFromScreen(item.accessibilityFrame())
                source = "accessibility"
            } else {
                rect = try layoutFrame(identifier)
                source = identifier.hasPrefix("editor.framing.") && identifier != "editor.framing.toggle" && identifier != "editor.framing.addAnchor"
                    ? "Read-only framingState normalized geometry; sourcePixelSize aspect-fit in actual preview/contentView bounds"
                    : "EditorContent layout in actual contentView bounds"
            }
            guard rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite else {
                throw failure("Invalid native target geometry: \(identifier), \(rect).")
            }
            resolvedTargets[identifier] = ["source": source, "windowFrame": NSStringFromRect(rect)]
            return rect
        }

        /// SwiftUI may omit its virtual accessibility children in a headless test
        /// launch. This fallback only locates pixels; the same native events and
        /// observed-state assertions still have to succeed.
        func layoutFrame(_ identifier: String) throws -> NSRect {
            guard let view = window.contentView else {
                throw failure("Editor has no content view (frame=\(window.frame), minSize=\(window.minSize)).")
            }
            guard view.bounds.width.isFinite, view.bounds.height.isFinite,
                  view.bounds.width > 0, view.bounds.height > 0,
                  window.frame.width + 0.5 >= window.minSize.width,
                  window.frame.height + 0.5 >= window.minSize.height else {
                throw failure("Editor layout geometry is invalid or below its window minimum (bounds=\(view.bounds), frame=\(window.frame), minSize=\(window.minSize)).")
            }
            if identifier.hasPrefix("editor.framing."), identifier != "editor.framing.toggle", identifier != "editor.framing.addAnchor" {
                guard let state = model.framingState else { throw failure("Framing geometry is unavailable: \(identifier).") }
                let source = try framingSourceFrame()
                if identifier == "editor.framing.frame" {
                    let crop = state.normalizedRect
                    return NSRect(x: source.minX + source.width * crop.minX,
                                  y: source.maxY - source.height * crop.maxY,
                                  width: source.width * crop.width, height: source.height * crop.height)
                }
                if identifier == "editor.framing.path" { return source }
                if identifier.hasPrefix("editor.framing.resize."),
                   let index = Int(identifier.split(separator: ".").last ?? ""), (0..<4).contains(index) {
                    let crop = state.normalizedRect
                    let rect = NSRect(x: source.minX + source.width * crop.minX,
                                      y: source.maxY - source.height * crop.maxY,
                                      width: source.width * crop.width, height: source.height * crop.height)
                    let corners = FramingOverlayGeometry.resizeHandleCenters(in: rect)
                    return NSRect(x: corners[index].x - 14, y: corners[index].y - 14, width: 28, height: 28)
                }
                if identifier.hasPrefix("editor.framing.handle."),
                   let index = Int(identifier.split(separator: ".").last ?? ""), state.handles.indices.contains(index) {
                    let points = state.handles.map { NSPoint(x: source.minX + source.width * $0.x,
                                                            y: source.maxY - source.height * $0.y) }
                    let center = FramingOverlayGeometry.handleBadgeCenters(points: points, bounds: source)[index]
                    return NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
                }
                throw failure("Missing native framing target and read-only geometry: \(identifier).")
            }
            let size = view.bounds.size
            let previewHeight = max(220, size.height - 330)
            let timelineTop = 76 + previewHeight + 16
            let timelineWidth = size.width - 48
            let axis = EditorTimeAxisGeometry(containerWidth: timelineWidth)
            let rulerWidth = axis.width
            let total = max(0.001, model.totalDuration)
            var topRect: NSRect?
            switch identifier {
            case "editor.timeline":
                topRect = NSRect(x: 24, y: timelineTop, width: timelineWidth, height: 88)
            case "editor.timeline.ruler":
                topRect = NSRect(x: 24 + axis.minX, y: timelineTop, width: rulerWidth, height: 25)
            case "editor.timeline.playhead":
                let x = 24 + axis.x(at: model.playhead, total: total)
                topRect = NSRect(x: x - 16, y: timelineTop + 4, width: 32, height: 38)
            case "editor.zoomGraph":
                topRect = NSRect(x: 24, y: timelineTop + 88 + 14, width: timelineWidth, height: 116)
            case "editor.preview.surface":
                topRect = NSRect(x: 24, y: 76, width: timelineWidth, height: previewHeight)
            case "editor.preview.backward", "editor.preview.play", "editor.preview.forward":
                let index = identifier == "editor.preview.backward" ? 0 : (identifier == "editor.preview.play" ? 1 : 2)
                topRect = NSRect(x: size.width / 2 - 48 + CGFloat(index) * 36,
                                 y: 76 + previewHeight - 48, width: 24, height: 30)
            case "editor.preview.split", "editor.preview.undo", "editor.preview.delete":
                let index = identifier == "editor.preview.split" ? 0 : (identifier == "editor.preview.undo" ? 1 : 2)
                topRect = NSRect(x: 46 + CGFloat(index) * 36, y: 76 + previewHeight - 48, width: 24, height: 30)
            case "editor.preview.fullscreen":
                topRect = NSRect(x: size.width - 66, y: 76 + previewHeight - 48, width: 24, height: 30)
            case "editor.framing.toggle", "editor.framing.addAnchor", "editor.zoom.add", "editor.zoom.reset":
                let graphTop = timelineTop + 88 + 14
                let index = identifier == "editor.framing.toggle" ? 0 : (identifier == "editor.framing.addAnchor" ? 1 : (identifier == "editor.zoom.add" ? 2 : 3))
                topRect = NSRect(x: size.width - 58, y: graphTop + 1.5 + CGFloat(index) * 29,
                                 width: 32, height: 26)
            default:
                let components = identifier.split(separator: ".")
                if components.count == 5, components[0] == "editor", components[1] == "zoom", components[3] == "anchor",
                   let zoomID = UUID(uuidString: String(components[2])), let anchorID = UUID(uuidString: String(components[4])),
                   let clip = model.clips.first(where: { $0.zooms.contains(where: { $0.id == zoomID }) }),
                   let zoom = clip.zooms.first(where: { $0.id == zoomID }),
                   let anchor = zoom.cameraControlPoints.first(where: { $0.id == anchorID }) {
                    let point = try cameraGraphPoint(globalTime: model.startTime(of: clip.id) + anchor.time, scale: anchor.scale)
                    return NSRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
                }
                if components.count == 5, components[0] == "editor", components[1] == "zoom", components[3] == "node",
                   let zoomID = UUID(uuidString: String(components[2])), let index = Int(components[4]),
                   let clip = model.clips.first(where: { $0.zooms.contains(where: { $0.id == zoomID }) }),
                   let zoom = clip.zooms.first(where: { $0.id == zoomID }), zoom.cameraControlPoints.indices.contains(index) {
                    let anchor = zoom.cameraControlPoints[index]
                    let point = try cameraGraphPoint(globalTime: model.startTime(of: clip.id) + anchor.time, scale: anchor.scale)
                    return NSRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
                }
                var offset = 0.0
                for clip in model.clips {
                    let x = 24 + axis.x(at: offset, total: total)
                    let width = rulerWidth * clip.duration / total
                    let clipID = "editor.clip.\(clip.id.uuidString)"
                    if identifier == clipID {
                        topRect = NSRect(x: x, y: timelineTop + 31, width: width, height: 57)
                    } else if identifier == clipID + ".trim.start", model.selectedClipID == clip.id {
                        topRect = NSRect(x: x, y: timelineTop + 31, width: 12, height: 57)
                    } else if identifier == clipID + ".trim.end", model.selectedClipID == clip.id {
                        topRect = NSRect(x: x + width - 12, y: timelineTop + 31, width: 12, height: 57)
                    }
                    if topRect != nil { break }
                    offset += clip.duration
                }
            }
            guard let topRect else { throw failure("Missing native accessibility target and layout mapping: \(identifier).") }
            let local = NSRect(x: view.bounds.minX + topRect.minX,
                y: view.isFlipped ? view.bounds.minY + topRect.minY : view.bounds.maxY - topRect.maxY,
                width: topRect.width, height: topRect.height)
            return view.convert(local, to: nil)
        }

        func accessibilityElements() -> [NSAccessibilityProtocol] {
            var pending: [Any] = [window]
            if let content = window.contentView { pending.append(content) }
            var seen = Set<ObjectIdentifier>()
            var output: [NSAccessibilityProtocol] = []
            while let value = pending.popLast() {
                let object = value as AnyObject
                guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10_000 else { continue }
                if let accessible = object as? NSAccessibilityProtocol {
                    output.append(accessible)
                    pending.append(contentsOf: accessible.accessibilityChildren() ?? [])
                }
                if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            }
            return output
        }

        func clipFrame(_ id: UUID) throws -> NSRect { try frame("editor.clip.\(id.uuidString)") }
        func center(_ frame: NSRect) -> NSPoint { NSPoint(x: frame.midX, y: frame.midY) }
        func point(_ frame: NSRect, fraction: CGFloat) -> NSPoint {
            NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        }

        func desktopEntries() -> Set<String>? {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(atPath: desktop.path)).map(Set.init)
        }

        func screenshot(_ name: String) throws {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw failure("Unable to capture the editor's displayed content.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw failure("Unable to encode the editor screenshot.")
            }
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        }

        func save(status: String, error: String? = nil) throws {
            let targets = accessibilityElements().compactMap { item -> [String: String]? in
                guard let identifier = item.accessibilityIdentifier(), identifier.hasPrefix("editor.") else { return nil }
                return ["identifier": identifier, "screenFrame": NSStringFromRect(item.accessibilityFrame())]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedResults = try encoder.encode(results)
            let resultObject = try JSONSerialization.jsonObject(with: encodedResults)
            var report: [String: Any] = ["status": status, "startedAt": ISO8601DateFormatter().string(from: started),
                "input": "NSApp.postEvent, own-window NSEvent mouse/keyboard events; targets use accessibility or recorded EditorContent layout geometry",
                "passed": resultObject, "limitations": limitations, "events": events, "targets": targets,
                "resolvedTargets": resolvedTargets,
                "fullScreenNotifications": fullScreenNotifications, "runtimeErrors": runtimeErrors,
                "window": ["number": window.windowNumber, "visible": window.isVisible, "key": window.isKeyWindow,
                           "appActive": NSApp.isActive, "screenFrame": NSStringFromRect(window.frame)],
                "clipOrder": model.clips.map { $0.id.uuidString }]
            if let error { report["error"] = error }
            if let failurePhase { report["failurePhase"] = failurePhase }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("editor-ui-results.json"), options: .atomic)
            print("EDITOR_UI_TEST \(status): \(results.count) checks; \(directory.path)")
        }

        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw failure(message) }
        }
        func failure(_ message: String) -> Error { RecorderError.message("Editor UI regression: \(message)") }
        func record(_ name: String, _ began: Date, _ detail: String) {
            results.append(Result(name: name, elapsedMilliseconds: Date().timeIntervalSince(began) * 1000, detail: detail))
            print("PASS native editor UI: \(name)")
        }
    }
}
