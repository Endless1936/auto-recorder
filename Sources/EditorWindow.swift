import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Shared visible fraction of the project. This is navigation state, never an edit.
struct EditorTimeViewport: Equatable {
    static let maximumScale = 64.0
    var scale = 1.0
    var start = 0.0
    var maximumStart: Double { max(0, 1 - 1 / scale) }

    mutating func zoom(by factor: Double, anchor: Double) {
        guard factor.isFinite, factor > 0, anchor.isFinite else { return }
        let anchor = min(1, max(0, anchor))
        let time = start + anchor / scale
        scale = min(Self.maximumScale, max(1, scale * factor))
        start = min(maximumStart, max(0, time - anchor / scale))
    }

    mutating func pan(by fraction: Double) {
        guard fraction.isFinite else { return }
        start = min(maximumStart, max(0, start + fraction))
    }

    mutating func reveal(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let time = min(1, max(0, fraction))
        let position = (time - start) * scale
        // Leave room in the direction of travel without constantly recentering.
        if position < 0.15 {
            start = min(maximumStart, max(0, time - 0.25 / scale))
        } else if position > 0.85 {
            start = min(maximumStart, max(0, time - 0.75 / scale))
        }
    }
}

@MainActor
final class EditorWindow: NSWindow, NSWindowDelegate {
    private let editorModel: EditorModel
    private let backAction: () -> Void

    init(model: EditorModel, onBack: @escaping () -> Void,
         onOpen: @escaping () -> Void, onExport: @escaping () -> Void) {
        editorModel = model
        backAction = onBack
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 880),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Auto Recorder"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(AppTheme.background)
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenPrimary]
        let content = EditorContent(model: model, onBack: { [weak self] in self?.returnToRecorder() },
                                    onOpen: onOpen, onExport: onExport,
                                    onFullScreen: { [weak self] in self?.toggleFullScreen(nil) })
        let hosting = NSHostingView(rootView: content.preferredColorScheme(.dark)
            .frame(minWidth: 980, minHeight: 730).ignoresSafeArea())
        hosting.sizingOptions = [.minSize]
        contentView = hosting
        minSize = NSSize(width: 980, height: 730)
        hideSystemTitlebarControls()
        delegate = self
        center()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        returnToRecorder()
        return false
    }

    func windowDidResize(_ notification: Notification) { hideSystemTitlebarControls() }
    func windowDidExitFullScreen(_ notification: Notification) { hideSystemTitlebarControls() }

    private var isEditingText: Bool {
        firstResponder is NSText || firstResponder is NSTextField || firstResponder is NSTextInputClient
    }

    var canDeleteSelection: Bool {
        isKeyWindow && attachedSheet == nil && !isEditingText && editorModel.canDeleteSelection
    }

    func deleteSelection() {
        guard canDeleteSelection else { return }
        _ = editorModel.deleteSelected()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, isKeyWindow, attachedSheet == nil, event.window === self,
           let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            let y = contentView.isFlipped ? point.y : contentView.bounds.height - point.y
            let top = 76 + max(220, contentView.bounds.height - 330) + 16
            let axis = EditorTimeAxisGeometry(containerWidth: contentView.bounds.width - 48)
            if y >= top, y <= top + 218, point.x >= 24 + axis.canvasMinX, point.x <= 24 + axis.canvasMaxX {
                if event.modifierFlags.contains(.command) {
                    let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                    let sensitivity = event.hasPreciseScrollingDeltas ? 0.015 : 0.15
                    editorModel.zoomTimeAxis(by: exp(min(1, max(-1, Double(delta) * sensitivity))),
                                            anchor: Double((point.x - 24 - axis.minX) / axis.width))
                } else {
                    let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                    let sensitivity = event.modifierFlags.contains(.shift)
                        ? (event.hasPreciseScrollingDeltas ? 2.0 : 24.0) : 1.0
                    editorModel.panTimeAxis(by: -Double(delta) * sensitivity / Double(axis.width) / editorModel.timeViewport.scale)
                }
                return
            }
        }
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil,
              event.window === self, !isEditingText else {
            super.sendEvent(event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) {
            let text = event.charactersIgnoringModifiers ?? ""
            let increase = text == "+" || text == "=" || event.keyCode == 69
            let decrease = text == "-" || text == "−" || event.keyCode == 78
            if increase || decrease {
                let time = editorModel.playhead / max(0.001, editorModel.totalDuration)
                let position = (time - editorModel.timeViewport.start) * editorModel.timeViewport.scale
                editorModel.zoomTimeAxis(by: increase ? 1.25 : 0.8, anchor: (0...1).contains(position) ? position : 0.5)
                return
            }
        }
        if (event.keyCode == 126 || event.keyCode == 125),
           modifiers.isEmpty, !editorModel.isExporting {
            _ = editorModel.navigateCameraTarget(forward: event.keyCode == 125)
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
            deleteSelection()
            return
        }
        super.sendEvent(event)
    }

    private func hideSystemTitlebarControls() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(type), !button.isHidden { button.isHidden = true }
        }
    }

    private func returnToRecorder() {
        editorModel.isPlaying = false
        editorModel.player.pause()
        do { try editorModel.autosave() }
        catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: self)
            return
        }
        orderOut(nil)
        backAction()
    }
}

private struct EditorTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorTrafficLightsView {
        EditorTrafficLightsView(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
    }
    func updateNSView(_ view: EditorTrafficLightsView, context: Context) { }
}

private final class EditorTrafficLightsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.frame = NSRect(x: CGFloat(index) * 22, y: 5, width: 14, height: 14)
            button.tag = index
            button.target = self
            button.action = #selector(activateControl(_:))
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 24) }

    @objc private func activateControl(_ sender: NSButton) {
        switch sender.tag {
        case 0: window?.performClose(sender)
        case 1: window?.performMiniaturize(sender)
        default: window?.toggleFullScreen(sender)
        }
    }
}

private struct EditorContent: View {
    @ObservedObject var model: EditorModel
    let onBack: () -> Void
    let onOpen: () -> Void
    let onExport: () -> Void
    let onFullScreen: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let previewHeight = max(220, geometry.size.height - 330)
            VStack(spacing: 0) {
                header(width: geometry.size.width)
                VStack(spacing: 0) {
                    EditorVideoSurface(player: model.player, framingState: model.framingState,
                                       onBeginEditing: model.beginFramingEditing,
                                       onEndEditing: model.endEditing,
                                       onMoveFrame: { clipID, zoomID, time, x, y in
                                           model.updateFramingCenter(clipID: clipID, zoomID: zoomID, time: time, x: x, y: y)
                                       },
                                       onResizeFrame: { clipID, zoomID, time, scale in
                                           model.updateFramingScale(clipID: clipID, zoomID: zoomID, time: time, scale: scale)
                                       })
                    .accessibilityIdentifier("editor.preview.surface")
                    .frame(height: previewHeight)
                    .background(AppTheme.paper)
                    .overlay(alignment: .bottomLeading) { editingControls.padding(12) }
                    .overlay(alignment: .bottom) { playbackControls.padding(12) }
                    .overlay(alignment: .bottomTrailing) {
                        EditorIcon(symbol: "arrow.up.left.and.arrow.down.right", help: "全屏", compact: true, action: onFullScreen)
                            .accessibilityIdentifier("editor.preview.fullscreen")
                            .padding(6)
                            .background(AppTheme.background.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                            .padding(12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.line))
                    .padding(.top, 12)

                    HStack(spacing: 0) {
                        Spacer()
                        Text("\(appTime(model.playhead)) / \(appTime(model.totalDuration))")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .frame(height: 16)
                    ProductionTimeline(model: model)
                        .frame(height: 88)
                    ProductionZoomGraph(model: model)
                        .frame(height: 116)
                        .padding(.top, 14)
                    EditorTimeScroller(model: model)
                        .frame(height: 12)
                        .padding(.leading, EditorTimeAxisGeometry.leadingInset)
                        .padding(.trailing, EditorTimeAxisGeometry.trailingInset)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 24)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.background)
    }

    private func header(width: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "film").font(.system(size: 17, weight: .regular))
                    .foregroundStyle(AppTheme.secondary)
                Text(model.projectTitle).font(.system(size: 16, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: max(180, min(400, width - 620)))
            HStack(spacing: 16) {
                EditorTrafficLights().frame(width: 64, height: 24)
                Rectangle().fill(AppTheme.line).frame(width: 1, height: 24)
                Button(action: onBack) {
                    Label("返回录制", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .regular))
                }.buttonStyle(.plain)
                Spacer(minLength: 14)
                Button {
                    model.isPlaying = false
                    model.player.pause()
                    onOpen()
                } label: {
                    Label("打开工程", systemImage: "folder")
                        .font(.system(size: 14, weight: .regular))
                }.buttonStyle(.plain).keyboardShortcut("o", modifiers: .command)
                Button {
                    model.isPlaying = false
                    model.player.pause()
                    onExport()
                } label: {
                    Label("导出视频", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.13))
                        .padding(.horizontal, 17)
                        .frame(height: 36)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.sourceURL == nil || model.isExporting)
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 64)
        .background(AppTheme.paper.opacity(0.35))
    }

    private var editingControls: some View {
        HStack(spacing: 12) {
            EditorIcon(symbol: "scissors", help: "在播放头分割片段（B）", compact: true) { _ = model.split() }
                .keyboardShortcut("b", modifiers: [])
                .accessibilityIdentifier("editor.preview.split")
            EditorIcon(symbol: "arrow.uturn.backward", help: "撤销（⌘Z）", compact: true, action: model.undo)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .accessibilityIdentifier("editor.preview.undo")
            EditorIcon(symbol: "trash", help: model.editingSelectionTarget == .cameraAnchors ? "删除所选节点（Delete）" : "删除所选片段（Delete）", compact: true) { _ = model.deleteSelected() }
                .disabled(!model.canDeleteSelection)
                .accessibilityIdentifier("editor.preview.delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.background.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            EditorIcon(symbol: "backward.fill", help: "后退 5 秒", compact: true) { model.skip(by: -5) }
                .accessibilityIdentifier("editor.preview.backward")
            EditorIcon(symbol: model.isPlaying ? "pause.fill" : "play.fill",
                       help: model.isPlaying ? "暂停（空格）" : "播放（空格）", compact: true) {
                model.togglePlayback()
            }.keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("editor.preview.play")
            EditorIcon(symbol: "forward.fill", help: "前进 5 秒", compact: true) { model.skip(by: 5) }
                .accessibilityIdentifier("editor.preview.forward")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.background.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
    }

}

private struct EditorVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let framingState: FramingState?
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    let onMoveFrame: (UUID, UUID, Double, Double, Double) -> Void
    let onResizeFrame: (UUID, UUID, Double, Double) -> Void

    func makeNSView(context: Context) -> EditorPlayerLayerView {
        let view = EditorPlayerLayerView()
        view.videoLayer.player = player
        configure(view)
        return view
    }

    func updateNSView(_ view: EditorPlayerLayerView, context: Context) {
        if view.videoLayer.player !== player { view.videoLayer.player = player }
        configure(view)
    }

    private func configure(_ view: EditorPlayerLayerView) {
        view.onBeginEditing = onBeginEditing
        view.onEndEditing = onEndEditing
        view.onMoveFrame = onMoveFrame
        view.onResizeFrame = onResizeFrame
        view.framingState = framingState
    }
}

private final class EditorPlayerLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onMoveFrame: ((UUID, UUID, Double, Double, Double) -> Void)?
    var onResizeFrame: ((UUID, UUID, Double, Double) -> Void)?
    var framingState: FramingState? { didSet { updateFramingLayers() } }

    private let framingLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let centerLayer = CAShapeLayer()
    private let resizeLayer = CAShapeLayer()
    private let scaleLabel = CATextLayer()
    private let frameRegion = EditorFramingAccessibilityView(identifier: "editor.framing.frame", label: "取景框")
    private var resizeRegions: [EditorFramingAccessibilityView] = []
    private var videoRectObservation: NSKeyValueObservation?
    private var drag: FramingDrag?

    private struct FramingDrag {
        enum Kind: Equatable { case frame, resize }
        let origin: CGPoint
        let center: CGPoint
        let videoSize: CGSize
        let clipID: UUID
        let zoomID: UUID
        let time: Double
        let kind: Kind
        var resizeScale: Double?
        var resizeVector: CGPoint?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(AppTheme.paper).cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        layer?.addSublayer(framingLayer)
        framingLayer.addSublayer(dimLayer)
        framingLayer.addSublayer(frameLayer)
        framingLayer.addSublayer(centerLayer)
        framingLayer.addSublayer(resizeLayer)
        framingLayer.addSublayer(scaleLabel)
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.57).cgColor
        resizeLayer.lineWidth = 1.5
        scaleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        scaleLabel.fontSize = 11
        scaleLabel.alignmentMode = .center
        scaleLabel.cornerRadius = 4
        scaleLabel.masksToBounds = true
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1.5
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOffset = CGSize(width: 0, height: -1)
        frameLayer.shadowRadius = 2
        frameLayer.shadowOpacity = 0.45
        centerLayer.fillColor = nil
        centerLayer.lineWidth = 1
        addSubview(frameRegion)
        for index in 0..<4 {
            let region = EditorFramingAccessibilityView(identifier: "editor.framing.resize.\(index)", label: "取景框大小控制点 \(index + 1)")
            resizeRegions.append(region)
            addSubview(region)
        }
        videoRectObservation = videoLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateFramingLayers() }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        framingLayer.frame = bounds
        CATransaction.commit()
        updateFramingLayers()
    }

    override func mouseDown(with event: NSEvent) {
        guard let state = framingState, let zoomID = state.zoomID,
              state.canEdit || state.canResize || state.canSelectAnchors else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = videoLayer.videoRect
        guard rect.width > 0, rect.height > 0, rect.insetBy(dx: -14, dy: -14).contains(point), point.y > 58 else { return }
        let crop = cropRect(for: state, in: rect)
        let corners = FramingOverlayGeometry.resizeHandleCenters(in: crop)
        if state.canResize, let corner = corners.min(by: { distance(point, $0) < distance(point, $1) }),
           distance(point, corner) <= 14 {
            let center = CGPoint(x: rect.minX + CGFloat(state.pose.x) * rect.width,
                                 y: rect.maxY - CGFloat(state.pose.y) * rect.height)
            drag = FramingDrag(origin: point, center: center, videoSize: rect.size,
                               clipID: state.clipID, zoomID: zoomID, time: state.localTime, kind: .resize,
                               resizeScale: state.pose.scale,
                               resizeVector: CGPoint(x: (corner.x - center.x) / rect.width,
                                                     y: (corner.y - center.y) / rect.height))
        } else if state.canEdit, crop.insetBy(dx: -7, dy: -7).contains(point) {
            drag = FramingDrag(origin: point, center: CGPoint(x: state.pose.x, y: state.pose.y), videoSize: rect.size,
                               clipID: state.clipID, zoomID: zoomID, time: state.localTime, kind: .frame)
        }
        if let drag {
            onBeginEditing?()
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let state = framingState, state.canSelectAnchors,
              drag.videoSize.width > 0, drag.videoSize.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let scale = drag.resizeScale, let vector = drag.resizeVector {
            let dx = (point.x - drag.origin.x) / drag.videoSize.width
            let dy = (point.y - drag.origin.y) / drag.videoSize.height
            let denominator = max(0.000001, vector.x * vector.x + vector.y * vector.y)
            let ratio = max(0.01, 1 + (dx * vector.x + dy * vector.y) / denominator)
            onResizeFrame?(drag.clipID, drag.zoomID, drag.time, min(3, max(1, scale / Double(ratio))))
            return
        }
        let x = Double(drag.center.x + (point.x - drag.origin.x) / drag.videoSize.width)
        let y = Double(drag.center.y - (point.y - drag.origin.y) / drag.videoSize.height)
        onMoveFrame?(drag.clipID, drag.zoomID, drag.time, x, y)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        NSCursor.pop()
        onEndEditing?()
    }

    override func resetCursorRects() {
        guard let state = framingState, state.canEdit || state.canResize || state.canSelectAnchors else { return }
        let videoRect = videoLayer.videoRect
        let editable = bounds.intersection(CGRect(x: 0, y: 58, width: bounds.width, height: max(0, bounds.height - 58)))
        let frame = cropRect(for: state, in: videoRect).intersection(editable)
        if state.canEdit, !frame.isEmpty { addCursorRect(frame, cursor: .openHand) }
        if state.canResize {
            for point in FramingOverlayGeometry.resizeHandleCenters(in: cropRect(for: state, in: videoRect)) {
                let hit = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28).intersection(editable)
                if !hit.isEmpty { addCursorRect(hit, cursor: .crosshair) }
            }
        }
    }

    private func updateFramingLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = videoLayer.videoRect
        guard let state = framingState, rect.width > 0, rect.height > 0 else {
            framingLayer.isHidden = true
            frameRegion.isHidden = true
            resizeRegions.forEach { $0.isHidden = true }
            window?.invalidateCursorRects(for: self)
            return
        }
        framingLayer.isHidden = false
        let crop = cropRect(for: state, in: rect)
        let dim = CGMutablePath()
        dim.addRect(rect)
        dim.addRect(crop)
        dimLayer.path = dim
        let accent = NSColor(AppTheme.accent).cgColor
        frameLayer.strokeColor = accent
        frameLayer.path = CGPath(rect: crop.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        let center = CGPoint(x: rect.minX + CGFloat(state.pose.x) * rect.width,
                             y: rect.maxY - CGFloat(state.pose.y) * rect.height)
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: center.x - 5, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 5, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 5))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 5))
        centerLayer.path = cross
        centerLayer.strokeColor = accent
        let corners = CGMutablePath()
        for point in FramingOverlayGeometry.resizeHandleCenters(in: crop) {
            corners.addRect(CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
        }
        resizeLayer.path = corners
        resizeLayer.fillColor = NSColor(AppTheme.paper).cgColor
        resizeLayer.strokeColor = accent
        resizeLayer.isHidden = !state.canResize
        scaleLabel.isHidden = !state.canResize
        let limited = state.minimumResizeScale > 1.000001 && state.pose.scale <= state.minimumResizeScale + 0.000001
        scaleLabel.string = String(format: limited ? "≥%.2f×" : "%.2f×", state.pose.scale)
        scaleLabel.contentsScale = window?.backingScaleFactor ?? 2
        scaleLabel.foregroundColor = accent
        scaleLabel.backgroundColor = NSColor(AppTheme.background).withAlphaComponent(0.85).cgColor
        scaleLabel.frame = CGRect(x: min(rect.maxX - 62, max(rect.minX + 3, crop.minX + 10)),
                                  y: max(60, min(rect.maxY - 24, crop.maxY - 25)), width: 56, height: 18)
        updateAccessibilityRegions(state, videoRect: rect, cropRect: crop)
        window?.invalidateCursorRects(for: self)
    }

    private func updateAccessibilityRegions(_ state: FramingState, videoRect: CGRect, cropRect: CGRect) {
        frameRegion.frame = cropRect
        frameRegion.isHidden = false
        frameRegion.setAccessibilityEnabled(state.canEdit)
        frameRegion.setAccessibilityValue(String(format: "倍率 %.4f，中心 %.6f，%.6f", state.pose.scale, state.pose.x, state.pose.y))
        let frameHelp = state.canEdit ? "拖动调整附近一小段取景，拖四角调整倍率" :
            (state.pose.scale > 1.000001 ? "暂停后可直接拖动取景框" : "当前为全景；将播放头移到放大处后可拖动取景框")
        frameRegion.setAccessibilityHelp(frameHelp)
        frameRegion.toolTip = frameHelp
        for (index, region) in resizeRegions.enumerated() {
            let point = FramingOverlayGeometry.resizeHandleCenters(in: cropRect)[index]
            region.frame = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
            region.isHidden = !state.canResize
            region.setAccessibilityEnabled(state.canResize && point.y > 58)
            let limit = state.minimumResizeScale > 1.000001
                ? String(format: "；其他重叠放大段将最小倍率限制为 %.2f×", state.minimumResizeScale) : ""
            region.setAccessibilityHelp("向内拖动放大，向外拖动缩小；同步更新当前时刻的倍率曲线" + limit)
            region.toolTip = "拖动调整倍率" + limit
        }
    }

    private func cropRect(for state: FramingState, in rect: CGRect) -> CGRect {
        let normalized = state.normalizedRect
        return CGRect(x: rect.minX + normalized.minX * rect.width,
                      y: rect.maxY - normalized.maxY * rect.height,
                      width: normalized.width * rect.width, height: normalized.height * rect.height)
            .intersection(rect)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum FramingOverlayGeometry {
    static func badgeIndex(at point: CGPoint, centers: [CGPoint]) -> Int? {
        centers.indices.filter {
            CGRect(x: centers[$0].x - 9, y: centers[$0].y - 9, width: 18, height: 18).contains(point)
        }.min {
            let lhs = hypot(point.x - centers[$0].x, point.y - centers[$0].y)
            let rhs = hypot(point.x - centers[$1].x, point.y - centers[$1].y)
            return abs(lhs - rhs) > 0.000001 ? lhs < rhs : $0 < $1
        }
    }

    static func resizeHandleCenters(in rect: CGRect) -> [CGPoint] {
        // Keep full-view controls inside the video surface's hit-test bounds.
        corners(of: rect.insetBy(dx: 4, dy: 4))
    }

    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func handleBadgeCenters(points: [CGPoint], bounds: CGRect) -> [CGPoint] {
        let safe = bounds.insetBy(dx: 10, dy: 10)
        var result: [CGPoint] = []
        for point in points {
            var candidates: [CGPoint] = []
            for radius in [CGFloat(18), 38, 58, 78, 98] {
                for direction in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1),
                                  CGPoint(x: 1, y: -1), CGPoint(x: -1, y: -1),
                                  CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0),
                                  CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1)] {
                    candidates.append(CGPoint(x: min(safe.maxX, max(safe.minX, point.x + radius * direction.x)),
                                              y: min(safe.maxY, max(safe.minY, point.y + radius * direction.y))))
                }
            }
            let candidate = candidates.first { candidate in
                result.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) >= 19 }
            } ?? candidates[0]
            result.append(candidate)
        }
        return result
    }

    static func directionArrows(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total >= 18 else { return path }
        let count = min(8, max(1, Int(total / 65)))
        var segment = 0
        var traveled: CGFloat = 0
        for index in 0..<count {
            // Uneven phase avoids opposing arrows landing on the same pixel
            // when a route goes out and back along the same line.
            let target = total * (CGFloat(index) + 0.38) / CGFloat(count)
            while segment < lengths.count - 1, traveled + lengths[segment] < target {
                traveled += lengths[segment]
                segment += 1
            }
            let length = lengths[segment]
            guard length > 0.000001 else { continue }
            let a = points[segment], b = points[segment + 1]
            let fraction = (target - traveled) / length
            let tip = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
            let dx = (b.x - a.x) / length, dy = (b.y - a.y) / length
            path.move(to: CGPoint(x: tip.x - dx * 5 - dy * 3, y: tip.y - dy * 5 + dx * 3))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - dx * 5 + dy * 3, y: tip.y - dy * 5 - dx * 3))
        }
        return path
    }
}

/// Native accessibility geometry follows the same fitted-video mapping as the
/// visible frame. These regions locate controls and never dispatch edits.
private final class EditorFramingAccessibilityView: NSView {
    init(identifier: String, label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TimelineClipLayout: Identifiable {
    let clip: DemoClip
    let frame: CGRect
    var id: UUID { clip.id }
}

private struct TimelineInsertion {
    let index: Int
    let x: CGFloat
}

private struct TimelineReorderState {
    let clipID: UUID
    let location: CGPoint
    let insertion: TimelineInsertion?
}

private struct TimelinePlayheadTip: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct EditorTimeAxisGeometry {
    static let scaleLabelWidth: CGFloat = 40
    static let scaleLabelSpacing: CGFloat = 12
    static let toolColumnWidth: CGFloat = 32
    static let toolSpacing: CGFloat = 12
    static let timePadding: CGFloat = 12
    static let leadingInset: CGFloat = scaleLabelWidth + scaleLabelSpacing + timePadding
    static let trailingInset: CGFloat = toolColumnWidth + toolSpacing + timePadding

    let containerWidth: CGFloat
    var viewport = EditorTimeViewport()
    var canvasMinX: CGFloat { Self.scaleLabelWidth + Self.scaleLabelSpacing }
    var canvasMaxX: CGFloat { max(canvasMinX + Self.timePadding * 2 + 1, containerWidth - Self.toolColumnWidth - Self.toolSpacing) }
    var canvasWidth: CGFloat { canvasMaxX - canvasMinX }
    var minX: CGFloat { canvasMinX + Self.timePadding }
    var maxX: CGFloat { canvasMaxX - Self.timePadding }
    var width: CGFloat { maxX - minX }
    var contentWidth: CGFloat { width * viewport.scale }

    func x(at time: Double, total: Double) -> CGFloat {
        minX + CGFloat(time / max(0.001, total) - viewport.start) * contentWidth
    }

    func time(at x: CGFloat, total: Double) -> Double {
        min(max(0, total), max(0, (Double((x - minX) / contentWidth) + viewport.start) * max(0, total)))
    }

    func timeDelta(for translation: CGFloat, total: Double) -> Double {
        Double(translation / contentWidth) * max(0, total)
    }
}

private struct EditorTimeScroller: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScroller {
        let view = EditorTimeScrollerView(frame: NSRect(x: 0, y: 0, width: 100, height: 12))
        view.scrollerStyle = .legacy
        view.knobStyle = .light
        view.controlSize = .small
        view.target = context.coordinator
        view.action = #selector(Coordinator.scroll(_:))
        view.setAccessibilityIdentifier("editor.timeAxis.scroller")
        view.setAccessibilityLabel("共同时间范围")
        view.toolTip = "⌘＋滚轮或 ⌘＋／− 缩放，横向滚动查看细节"
        return view
    }
    func updateNSView(_ view: NSScroller, context: Context) {
        let value = model.timeViewport
        view.knobProportion = 1 / value.scale
        view.doubleValue = value.maximumStart > 0 ? value.start / value.maximumStart : 0
        view.isEnabled = value.scale > 1
        view.alphaValue = value.scale > 1 ? 1 : 0
        view.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }
        @objc func scroll(_ sender: NSScroller) {
            switch sender.hitPart {
            case .decrementPage: model.panTimeAxis(by: -0.8 / model.timeViewport.scale)
            case .incrementPage: model.panTimeAxis(by: 0.8 / model.timeViewport.scale)
            default:
                model.panTimeAxis(by: sender.doubleValue * model.timeViewport.maximumStart - model.timeViewport.start)
            }
        }
    }
}

/// Keep AppKit's drag target while drawing a slim track and thumb.
final class EditorTimeScrollerView: NSScroller {
    var visibleKnobRect: NSRect {
        let knob = rect(for: .knob)
        return NSRect(x: knob.minX, y: bounds.midY - 2, width: knob.width, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        NSColor(AppTheme.line).setFill()
        let track = NSRect(x: slotRect.minX, y: bounds.midY - 1, width: slotRect.width, height: 2)
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
    }

    override func drawKnob() {
        NSColor(AppTheme.secondary).withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: visibleKnobRect, xRadius: 2, yRadius: 2).fill()
    }
}

private struct EditorAxisDrawing: NSViewRepresentable {
    enum Kind: Equatable { case canvas, track, grid }
    let kind: Kind
    let identifier: String
    var maximum: Double = 3.05

    func makeNSView(context: Context) -> EditorAxisDrawingView {
        let view = EditorAxisDrawingView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: EditorAxisDrawingView, context: Context) {
        view.kind = kind
        view.maximum = maximum
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(kind == .canvas ? "编辑画布" : kind == .track ? "视频时间范围" : "倍率时间范围")
        view.needsDisplay = true
    }
}

private final class EditorAxisDrawingView: NSView {
    var kind: EditorAxisDrawing.Kind = .canvas
    var maximum = 3.05

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch kind {
        case .canvas:
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor(AppTheme.paper).setFill()
            shape.fill()
            NSColor(AppTheme.line).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        case .track:
            NSColor(AppTheme.background).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        case .grid:
            let lines = NSBezierPath()
            for scale in [1.0, 2.0, 3.0] {
                let y = CGFloat((maximum - scale) / max(0.1, maximum - 1)) * bounds.height
                lines.move(to: NSPoint(x: 0, y: y))
                lines.line(to: NSPoint(x: bounds.width, y: y))
            }
            lines.lineWidth = 1
            lines.setLineDash([4, 5], count: 2, phase: 0)
            NSColor(AppTheme.ink).withAlphaComponent(0.25).setStroke()
            lines.stroke()
        }
    }
}

private struct EditorScaleLabels: NSViewRepresentable {
    let maximum: Double
    let top: CGFloat
    let bottom: CGFloat

    func makeNSView(context: Context) -> EditorScaleLabelsView { EditorScaleLabelsView() }

    func updateNSView(_ view: EditorScaleLabelsView, context: Context) {
        view.maximum = maximum
        view.top = top
        view.bottom = bottom
        view.needsLayout = true
    }
}

private final class EditorScaleLabelsView: NSView {
    var maximum = 3.05
    var top: CGFloat = 16
    var bottom: CGFloat = 18
    private let labels = [1, 2, 3].map { scale -> NSTextField in
        let label = NSTextField(labelWithString: "\(scale).0×")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(AppTheme.ink)
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(true)
        label.setAccessibilityIdentifier("editor.zoomGraph.scaleLabel.\(scale)")
        return label
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("倍率标尺")
        setAccessibilityIdentifier("editor.zoomGraph.scaleLabels")
        labels.forEach { addSubview($0) }
        setAccessibilityChildren(labels)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let height = max(1, bounds.height - top - bottom)
        for (index, label) in labels.enumerated() {
            let scale = Double(index + 1)
            let y = top + CGFloat((maximum - scale) / max(0.1, maximum - 1)) * height
            label.frame = NSRect(x: 0, y: y - 9, width: bounds.width, height: 18)
        }
    }
}

private struct ProductionTimeline: View {
    @ObservedObject var model: EditorModel
    @GestureState private var reorderState: TimelineReorderState?
    @AppState<UUID?> private var trimID: UUID?
    @AppState<Int> private var trimEdge = 0
    @AppState<CGFloat> private var trimDelta = 0

    var body: some View {
        GeometryReader { geo in
            let axis = EditorTimeAxisGeometry(containerWidth: geo.size.width, viewport: model.timeViewport)
            let total = max(0.001, model.totalDuration)
            let layouts = clipLayouts(axis: axis, total: total)
            EditorAxisDrawing(kind: .canvas, identifier: "editor.timeline.canvas")
                .frame(width: axis.width, height: 57)
                .position(x: (axis.minX + axis.maxX) / 2, y: 59.5)
            EditorAxisDrawing(kind: .track, identifier: "editor.timeline.dataFrame")
                .frame(width: axis.width, height: 51)
                .position(x: (axis.minX + axis.maxX) / 2, y: 59.5)
            ruler(axis: axis, total: total)
                .frame(width: axis.width, height: 25)
                .position(x: (axis.minX + axis.maxX) / 2, y: 12.5)
            ForEach(layouts) { layout in
                let visible = layout.frame.intersection(CGRect(x: axis.minX, y: 31, width: axis.width, height: 57))
                if !visible.isNull, visible.width > 0 {
                    clipCell(layout.clip, width: visible.width, axis: axis, total: total,
                             layouts: layouts, size: geo.size,
                             stripStart: layout.clip.sourceStart + Double((visible.minX - layout.frame.minX) / axis.contentWidth) * total,
                             stripDuration: Double(visible.width / axis.contentWidth) * total,
                             showStart: layout.frame.minX >= axis.minX - 0.5,
                             showEnd: layout.frame.maxX <= axis.maxX + 0.5)
                        .position(x: visible.midX, y: visible.midY)
                }
            }
            if axis.x(at: model.playhead, total: total) >= axis.minX - 0.5,
               axis.x(at: model.playhead, total: total) <= axis.maxX + 0.5 {
                Rectangle().fill(AppTheme.accent).frame(width: 1.5, height: 64)
                    .position(x: axis.x(at: model.playhead, total: total), y: 56)
                    .allowsHitTesting(false)
                TimelinePlayheadTip().fill(AppTheme.accent)
                    .frame(width: 10, height: 20)
                    .frame(width: 32, height: 38, alignment: .top)
                    .contentShape(Rectangle())
                    .position(x: axis.x(at: model.playhead, total: total), y: 23)
                    .highPriorityGesture(scrubGesture(axis: axis, total: total))
                    .help("拖动播放头浏览视频")
                    .accessibilityLabel("播放头")
                    .accessibilityIdentifier("editor.timeline.playhead")
                    .accessibilityValue(appTime(model.playhead))
                    .accessibilityAdjustableAction { direction in
                        model.skip(by: direction == .increment ? 1 : -1)
                    }
            }
            if let drag = reorderState {
                if let insertion = drag.insertion {
                    Rectangle().fill(AppTheme.accent).frame(width: 3, height: 62)
                        .overlay(alignment: .top) { Circle().fill(AppTheme.accent).frame(width: 7, height: 7) }
                        .position(x: min(axis.maxX, max(axis.minX, insertion.x)), y: 57)
                        .allowsHitTesting(false)
                }
                if let clip = model.clips.first(where: { $0.id == drag.clipID }) {
                    ClipFrameStrip(source: model.sourceURL, start: clip.sourceStart, duration: clip.duration)
                        .frame(width: 144, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppTheme.accent, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .position(x: min(max(74, drag.location.x), max(74, geo.size.width - 74)),
                                  y: drag.location.y - 48)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(name: "productionTimeline")
        .zIndex(reorderState == nil ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.timeline")
    }

    private func ruler(axis: EditorTimeAxisGeometry, total: Double) -> some View {
        let width = axis.width
        return ZStack(alignment: .topLeading) {
            ForEach(0..<9) { index in
                let time = axis.time(at: axis.minX + width * CGFloat(index) / 8, total: total)
                let span = total / model.timeViewport.scale
                Text(span < 2 ? String(format: span < 0.2 ? "%.3f" : "%.2f", time)
                     : total < 10 ? EditorModel.timeLabel(time) : appTime(time))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(AppTheme.secondary)
                    .position(x: max(17, min(width - 17, width * CGFloat(index) / 8)), y: 7)
            }
            Path { path in
                for index in 0...32 {
                    let x = width * CGFloat(index) / 32
                    path.move(to: CGPoint(x: x, y: index % 4 == 0 ? 17 : 21))
                    path.addLine(to: CGPoint(x: x, y: 25))
                }
                path.move(to: CGPoint(x: 0, y: 25))
                path.addLine(to: CGPoint(x: width, y: 25))
            }.stroke(AppTheme.ink.opacity(0.25), lineWidth: 1)
        }
        .frame(height: 25)
        .contentShape(Rectangle())
        .highPriorityGesture(scrubGesture(axis: axis, total: total))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("剪辑时间刻度")
        .accessibilityIdentifier("editor.timeline.ruler")
    }

    private func scrubGesture(axis: EditorTimeAxisGeometry, total: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("productionTimeline")).onChanged { value in
            model.isPlaying = false
            model.player.pause()
            model.seek(axis.time(at: value.location.x, total: total), followViewport: false)
        }.onEnded { _ in model.revealTimeAxisPlayhead() }
    }

    private func clipLayouts(axis: EditorTimeAxisGeometry, total: Double) -> [TimelineClipLayout] {
        var offset = 0.0
        return model.clips.map { clip in
            let start = axis.x(at: offset, total: total)
            let end = axis.x(at: offset + clip.duration, total: total)
            defer { offset += clip.duration }
            return TimelineClipLayout(clip: clip, frame: CGRect(x: start, y: 31, width: max(0, end - start), height: 57))
        }
    }

    private func insertion(for id: UUID, at point: CGPoint, layouts: [TimelineClipLayout], size: CGSize) -> TimelineInsertion? {
        guard point.x >= 0, point.x <= size.width, point.y >= 25, point.y <= 88,
              let from = layouts.firstIndex(where: { $0.id == id }),
              let target = layouts.firstIndex(where: { point.x <= $0.frame.maxX }) ?? layouts.indices.last,
              target != from else { return nil }
        // Movement direction owns the insertion side, so a neighboring clip's
        // midpoint cannot turn a visible move back into the original order.
        let boundary = target < from ? target : target + 1
        let index = boundary - (from < boundary ? 1 : 0)
        guard index != from else { return nil }
        let x: CGFloat
        if boundary == 0 { x = layouts[0].frame.minX }
        else if boundary == layouts.count { x = layouts[boundary - 1].frame.maxX }
        else { x = (layouts[boundary - 1].frame.maxX + layouts[boundary].frame.minX) / 2 }
        return TimelineInsertion(index: index, x: x)
    }

    private func reorderGesture(for id: UUID, layouts: [TimelineClipLayout], size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("productionTimeline"))
            .updating($reorderState) { value, state, _ in
                state = TimelineReorderState(clipID: id, location: value.location,
                    insertion: insertion(for: id, at: value.location, layouts: layouts, size: size))
            }
            .onChanged { _ in
                model.isPlaying = false
                model.player.pause()
                if model.selectedClipID != id || model.editingSelectionTarget != .clip { model.select(id) }
            }
            .onEnded { value in
                guard let insertion = insertion(for: id, at: value.location, layouts: layouts, size: size) else { return }
                let remaining = model.clips.filter { $0.id != id }
                if insertion.index < remaining.count {
                    model.moveClip(id: id, before: remaining[insertion.index].id)
                } else { model.moveClipToEnd(id: id) }
            }
    }

    private func clipCell(_ clip: DemoClip, width: CGFloat, axis: EditorTimeAxisGeometry, total: Double,
                          layouts: [TimelineClipLayout], size: CGSize, stripStart: Double, stripDuration: Double,
                          showStart: Bool, showEnd: Bool) -> some View {
        let selected = model.editingSelectionTarget == .clip && model.selectedClipID == clip.id
        return ZStack {
            ClipFrameStrip(source: model.sourceURL, start: stripStart, duration: stripDuration)
            if !selected { Color.black.opacity(0.22) }
        }
        .frame(width: max(0, width - 3), height: 51)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? AppTheme.accent : AppTheme.line, lineWidth: selected ? 2 : 1))
        .frame(width: width, height: 57)
        .contentShape(Rectangle())
        .onTapGesture {
            model.isPlaying = false
            model.player.pause()
            model.select(clip.id)
        }
        .gesture(reorderGesture(for: clip.id, layouts: layouts, size: size))
        .opacity(reorderState?.clipID == clip.id ? 0.45 : 1)
        .overlay(alignment: .leading) { if selected && showStart { trimHandle(clip, edge: 0, width: width, axis: axis, total: total) } }
        .overlay(alignment: .trailing) { if selected && showEnd { trimHandle(clip, edge: 1, width: width, axis: axis, total: total) } }
        .help("点击选择；拖动调整顺序；拖动两端裁剪")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频片段，\(appTime(clip.duration))")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("editor.clip.\(clip.id.uuidString)")
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("分割片段") { model.select(clip.id); model.split() }
            Button("删除片段") { model.select(clip.id); model.deleteSelected() }.disabled(model.clips.count < 2)
            Button("移到最后") { model.moveClipToEnd(id: clip.id) }
        }
    }

    private func trimHandle(_ clip: DemoClip, edge: Int, width: CGFloat, axis: EditorTimeAxisGeometry, total: Double) -> some View {
        HStack(spacing: 2) {
            Capsule().fill(AppTheme.background).frame(width: 1.5, height: 14)
            Capsule().fill(AppTheme.background).frame(width: 1.5, height: 14)
        }
        .frame(width: 12, height: 57)
        .background(AppTheme.accent)
        .contentShape(Rectangle())
        .offset(x: trimID == clip.id && trimEdge == edge ? trimDelta : 0)
        .highPriorityGesture(DragGesture(minimumDistance: 3).onChanged { value in
            trimID = clip.id
            trimEdge = edge
            trimDelta = edge == 0 ? max(0, min(width - 10, value.translation.width)) : min(0, max(-width + 10, value.translation.width))
        }.onEnded { _ in
            let change = axis.timeDelta(for: trimDelta, total: total)
            model.select(clip.id)
            if edge == 0 { model.trimSelected(start: change, end: clip.duration) }
            else { model.trimSelected(start: 0, end: clip.duration + change) }
            trimID = nil
            trimDelta = 0
        })
        .help(edge == 0 ? "裁剪开头" : "裁剪结尾")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(edge == 0 ? "裁剪开头" : "裁剪结尾")
        .accessibilityIdentifier("editor.clip.\(clip.id.uuidString).trim.\(edge == 0 ? "start" : "end")")
    }
}

private struct ClipFrameStrip: View {
    let source: URL?
    let start: Double
    let duration: Double
    @AppState<[NSImage]> private var images = []

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                if images.isEmpty { AppTheme.paper }
                else {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: max(1, (geo.size.width - CGFloat(images.count - 1)) / CGFloat(images.count)), height: geo.size.height)
                            .clipped()
                    }
                }
            }
        }
        .task(id: "\(source?.path ?? "")|\(start)|\(duration)") {
            guard let source else { images = []; return }
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            let extraction = Task.detached(priority: .utility) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 135)
                let tolerance = min(0.2, max(1.0 / 120, duration / 32))
                generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
                return (0..<8).compactMap { index -> NSImage? in
                    guard !Task.isCancelled else { return nil }
                    let seconds = start + max(0, duration - min(0.04, duration * 0.1)) * (Double(index) + 0.5) / 8
                    guard let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) else { return nil }
                    return NSImage(cgImage: image, size: .zero)
                }
            }
            let result = await withTaskCancellationHandler(operation: { await extraction.value }, onCancel: { extraction.cancel() })
            guard !Task.isCancelled else { return }
            images = result
        }
    }
}

private struct CurveLocation: Identifiable {
    let clip: DemoClip
    let zoom: ZoomSegment
    let offset: Double
    var id: String { "\(clip.id.uuidString):\(zoom.id.uuidString)" }
}

private struct ProductionZoomGraph: View {
    @ObservedObject var model: EditorModel
    @AppState<CurveNodeDrag?> private var nodeDrag: CurveNodeDrag? = nil
    @AppState<CGRect?> private var marqueeRect: CGRect? = nil
    @AppState<CGPoint?> private var marqueeStart: CGPoint? = nil
    @AppState<Set<UUID>> private var marqueeSeed = []
    @AppState<Double?> private var snapGuideScale: Double? = nil

    private struct CurveNodeDrag {
        let base: ZoomSegment
        let ids: Set<UUID>
        var isEditing = false
    }

    private var locations: [CurveLocation] {
        var offset = 0.0
        return model.clips.flatMap { clip -> [CurveLocation] in
            defer { offset += clip.duration }
            return clip.canonicalZooms().filter { $0.end > 0 && $0.start < clip.duration }
                .map { CurveLocation(clip: clip, zoom: $0, offset: offset) }
        }
    }

    private var maximum: Double { 3.05 }
    private var selectedCameraIDs: Set<UUID> { model.selectedCameraAnchorIDs }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                graph(size: geo.size)
                VStack(spacing: 3) {
                    EditorIcon(symbol: "viewfinder", help: "显示取景框（暂停后可拖动）",
                               selected: model.showsFramingOverlay, controlHeight: 26, action: model.toggleFramingOverlay)
                        .accessibilityIdentifier("editor.framing.toggle")
                        .accessibilityValue(model.showsFramingOverlay ? "已开启" : "已关闭")
                        .disabled(model.clips.isEmpty)
                    EditorIcon(symbol: "plus.diamond", help: "在当前时刻添加取景锚点", controlHeight: 26) { model.addFramingAnchor() }
                        .accessibilityIdentifier("editor.framing.addAnchor")
                        .disabled(!model.canAddFramingAnchor)
                    EditorIcon(symbol: "plus", help: "在播放头添加放大", controlHeight: 26) { model.addZoom() }
                        .accessibilityIdentifier("editor.zoom.add")
                    EditorIcon(symbol: "minus", help: "移除所选放大段（可撤销）", controlHeight: 26) { model.resetZoom() }
                        .accessibilityIdentifier("editor.zoom.reset")
                        .disabled(model.selectedZoom == nil)
                }
                .frame(width: EditorTimeAxisGeometry.toolColumnWidth)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("动画编辑工具")
                .accessibilityIdentifier("editor.zoomGraph.tools")
            }
        }
    }

    private func graph(size: CGSize) -> some View {
        let axis = EditorTimeAxisGeometry(containerWidth: size.width, viewport: model.timeViewport)
        let left = axis.minX
        let top: CGFloat = 16
        let bottom: CGFloat = 18
        let width = axis.width
        let height = max(1, size.height - top - bottom)
        let total = max(0.001, model.totalDuration)
        let range = max(0.1, maximum - 1)
        let point: (Double, Double) -> CGPoint = { time, scale in
            CGPoint(x: axis.x(at: time, total: total), y: top + CGFloat((maximum - scale) / range) * height)
        }
        return ZStack(alignment: .topLeading) {
            EditorAxisDrawing(kind: .canvas, identifier: "editor.zoomGraph.canvas")
                .frame(width: axis.canvasWidth, height: size.height)
                .position(x: (axis.canvasMinX + axis.canvasMaxX) / 2, y: size.height / 2)
            EditorScaleLabels(maximum: maximum, top: top, bottom: bottom)
                .frame(width: EditorTimeAxisGeometry.scaleLabelWidth, height: size.height)
                .position(x: EditorTimeAxisGeometry.scaleLabelWidth / 2, y: size.height / 2)
            ZStack(alignment: .topLeading) {
                EditorAxisDrawing(kind: .grid, identifier: "editor.zoomGraph.dataFrame", maximum: maximum)
                    .frame(width: axis.width, height: height)
                    .position(x: (axis.minX + axis.maxX) / 2, y: top + height / 2)
                effectiveCurve(width: width, total: total, point: point)
                    .stroke(AppTheme.accent.opacity(0.38),
                            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                if let selected = locations.first(where: isSelected) {
                    zoomFill(selected, point: point).fill(AppTheme.accent.opacity(0.045))
                    zoomCurve(selected, point: point)
                        .stroke(AppTheme.accent,
                                style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                }
                ForEach(locations) { item in
                    if isSelected(item) {
                        ForEach(item.zoom.cameraControlPoints) { control in
                            if control.time >= 0 && control.time <= item.clip.duration,
                               axis.x(at: item.offset + control.time, total: total) >= axis.minX - 0.5,
                               axis.x(at: item.offset + control.time, total: total) <= axis.maxX + 0.5 {
                                cameraNode(control, item: item, axis: axis, height: height,
                                           total: total, range: range, point: point)
                            }
                        }
                    }
                }
                if let scale = snapGuideScale {
                    Path { path in
                        path.move(to: point(0, scale))
                        path.addLine(to: point(total, scale))
                    }
                    .stroke(AppTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
                    .accessibilityLabel("倍率水平吸附线")
                    .accessibilityIdentifier("editor.zoomGraph.snapGuide")
                }
                if let rect = marqueeRect, !rect.isNull {
                    Rectangle().fill(AppTheme.accent.opacity(0.10))
                        .overlay(Rectangle().strokeBorder(AppTheme.accent.opacity(0.85), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .accessibilityLabel("框选倍率控制点")
                        .accessibilityIdentifier("editor.zoomGraph.marquee")
                }
            }
            .frame(width: size.width, height: size.height)
            .mask(Rectangle().frame(width: axis.canvasWidth, height: size.height)
                .position(x: (axis.canvasMinX + axis.canvasMaxX) / 2, y: size.height / 2))
            .contentShape(Path(CGRect(x: axis.canvasMinX, y: 0, width: axis.canvasWidth, height: size.height)))
        }
        .overlay(alignment: .topTrailing) {
            if hasOverlappingZooms {
                Text("重叠放大").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    .padding(.horizontal, 10).padding(.top, 5)
                    .padding(.trailing, EditorTimeAxisGeometry.toolColumnWidth + EditorTimeAxisGeometry.toolSpacing)
            }
        }
        .coordinateSpace(name: "productionZoom")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.zoomGraph")
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("productionZoom")).onChanged { value in
            guard nodeDrag == nil else { return }
            if marqueeStart == nil {
                marqueeStart = value.startLocation
                marqueeSeed = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? selectedCameraIDs : []
            }
            guard hypot(value.translation.width, value.translation.height) > 4 else { return }
            let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                              y: min(value.startLocation.y, value.location.y),
                              width: abs(value.translation.width), height: abs(value.translation.height))
                .intersection(CGRect(x: left, y: top - 7, width: width, height: height + 14))
            marqueeRect = rect
            guard let item = locations.first(where: isSelected), !rect.isNull else { return }
            let controls = item.zoom.cameraControlPoints
            let captured = controls.filter { control in
                control.time >= 0 && control.time <= item.clip.duration &&
                    rect.insetBy(dx: -3, dy: -3).contains(point(item.offset + control.time, control.scale))
            }.map(\.id)
            model.selectCameraAnchors(marqueeSeed.union(captured), in: item.clip.id, zoomID: item.zoom.id)
        }.onEnded { value in
            defer { marqueeRect = nil; marqueeStart = nil; marqueeSeed = [] }
            guard marqueeRect == nil, nodeDrag == nil else { return }
            model.clearCameraAnchorSelection()
            let time = axis.time(at: value.location.x, total: total)
            if let item = locations.first(where: { time >= $0.offset + max(0, $0.zoom.start) && time <= $0.offset + min($0.clip.duration, $0.zoom.end) }) {
                model.selectZoom(item.zoom.id)
            }
            model.seek(time)
            model.isPlaying = false
            model.player.pause()
        })
        .contextMenu {
            Button("删除所选节点") { _ = model.deleteSelected() }
                .disabled(model.editingSelectionTarget != .cameraAnchors || !model.canDeleteSelection)
            Button("清除控制点选择") { model.clearCameraAnchorSelection() }.disabled(selectedCameraIDs.isEmpty)
            Button("添加取景锚点") { model.addFramingAnchor() }.disabled(!model.canAddFramingAnchor)
            Button("添加放大") { model.addZoom() }
            Button("移除所选放大段") { model.resetZoom() }.disabled(model.selectedZoom == nil)
        }
    }

    private func cameraNode(_ control: CameraKeyframe, item: CurveLocation,
                            axis: EditorTimeAxisGeometry, height: CGFloat,
                            total: Double, range: Double, point: @escaping (Double, Double) -> CGPoint) -> some View {
        let selected = model.editingSelectionTarget == .cameraAnchors && model.selectedClipID == item.clip.id &&
            model.selectedZoomID == item.zoom.id && selectedCameraIDs.contains(control.id)
        let controls = item.zoom.cameraControlPoints
        let index = controls.firstIndex(where: { $0.id == control.id }) ?? 0
        let endpoint = index == 0 || index == controls.count - 1
        return Circle().fill(selected ? AppTheme.accent : AppTheme.ink).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(AppTheme.accent, lineWidth: 2.5))
            .overlay {
                if selected { Circle().stroke(AppTheme.accent.opacity(0.65), lineWidth: 1).padding(-4) }
            }
            .frame(width: 28, height: 28).contentShape(Circle())
            .position(point(item.offset + control.time, control.scale))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("productionZoom"))
                .onChanged { value in
                    if nodeDrag == nil {
                        var selection = model.selectedClipID == item.clip.id && model.selectedZoomID == item.zoom.id
                            && model.editingSelectionTarget == .cameraAnchors ? selectedCameraIDs : []
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            selection.insert(control.id)
                        } else if !selection.contains(control.id) {
                            selection = [control.id]
                        }
                        model.selectCameraAnchors(selection, in: item.clip.id, zoomID: item.zoom.id)
                        nodeDrag = CurveNodeDrag(base: item.zoom, ids: selection)
                    }
                    guard hypot(value.translation.width, value.translation.height) > 2, var drag = nodeDrag else { return }
                    if !drag.isEditing {
                        model.beginEditing()
                        model.selectZoom(item.zoom.id)
                        drag.isEditing = true
                        nodeDrag = drag
                    }
                    model.isPlaying = false
                    let tolerance = NSApp.currentEvent?.modifierFlags.contains(.option) == true ? 0 : 6 * range / Double(height)
                    snapGuideScale = model.dragCameraAnchors(from: drag.base, ids: drag.ids,
                        timeDelta: axis.timeDelta(for: value.translation.width, total: total),
                        scaleDelta: -Double(value.translation.height / height) * range, snapTolerance: tolerance)
                }.onEnded { _ in
                    if nodeDrag?.isEditing == true { model.endEditing() }
                    else {
                        model.isPlaying = false
                        model.selectZoom(item.zoom.id)
                        model.seek(item.offset + control.time)
                    }
                    nodeDrag = nil
                    snapGuideScale = nil
                })
            .help(endpoint ? "全景端点：左右调整时间，倍率固定为 1×" :
                  "左右调整时间，上下调整倍率；空白处框选")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(endpoint ? "全景端点" : "倍率控制点")
            .accessibilityValue(String(format: "时间 %.6f，倍率 %.6f，%@", item.offset + control.time, control.scale, selected ? "已选择" : "未选择"))
            .accessibilityIdentifier(item.zoom.cameraKeyframes == nil
                ? "editor.zoom.\(item.zoom.id.uuidString).node.\(index)"
                : "editor.zoom.\(item.zoom.id.uuidString).anchor.\(control.id.uuidString)")
            .contextMenu {
                Button("删除此节点") {
                    model.selectCameraAnchors([control.id], in: item.clip.id, zoomID: item.zoom.id)
                    _ = model.deleteSelected()
                }.disabled(endpoint || model.isExporting)
            }
    }

    private func isSelected(_ item: CurveLocation) -> Bool {
        item.clip.id == model.selectedClipID && item.zoom.id == model.selectedZoomID
    }

    private func neighborBounds(for zoom: ZoomSegment, in clip: DemoClip) -> (left: Double, right: Double) {
        let others = clip.canonicalZooms().filter { $0.id != zoom.id }
        let left = others.filter { $0.start <= zoom.start }.map(\.end).max() ?? -.infinity
        let right = others.filter { $0.end >= zoom.end }.map(\.start).min() ?? .infinity
        // Existing overlap remains editable without jumping an imported edge.
        // Only outward expansion into a neighboring zoom is prevented.
        return (min(zoom.start, left), max(zoom.end, right))
    }

    private var hasOverlappingZooms: Bool {
        for clip in model.clips {
            var end = 0.0
            for zoom in clip.canonicalZooms().sorted(by: { $0.start < $1.start }) {
                let lower = max(0, zoom.start), upper = min(clip.duration, zoom.end)
                guard upper > lower else { continue }
                if lower < end { return true }
                end = max(end, upper)
            }
        }
        return false
    }

    private func effectiveCurve(width: CGFloat, total: Double, point: (Double, Double) -> CGPoint) -> Path {
        Path { path in
            var offset = 0.0
            for clip in model.clips {
                let clipOffset = offset
                offset += clip.duration
                let lower = max(0, model.timeViewport.start * total - clipOffset)
                let upper = min(clip.duration, (model.timeViewport.start + 1 / model.timeViewport.scale) * total - clipOffset)
                guard upper >= lower else { continue }
                let samples = max(24, Int(Double(width) * (upper - lower) / (total / model.timeViewport.scale)) * 2)
                var times = (0...samples).map { lower + (upper - lower) * Double($0) / Double(samples) }
                times.append(contentsOf: clip.canonicalZooms().flatMap { $0.cameraControlPoints.map(\.time) }
                    .filter { $0 > lower && $0 < upper })
                for time in Set(times).sorted() {
                    let position = point(clipOffset + time, clip.scale(at: time))
                    if path.isEmpty { path.move(to: position) }
                    else { path.addLine(to: position) }
                }
            }
        }
    }

    private func visibleBounds(_ item: CurveLocation) -> (Double, Double) {
        let duration = max(0.001, model.totalDuration)
        return (max(0, item.zoom.start, model.timeViewport.start * duration - item.offset),
                min(item.clip.duration, item.zoom.end, (model.timeViewport.start + 1 / model.timeViewport.scale) * duration - item.offset))
    }

    private func zoomCurve(_ item: CurveLocation, point: (Double, Double) -> CGPoint) -> Path {
        Path { path in
            let (lower, upper) = visibleBounds(item)
            guard upper > lower else { return }
            if item.zoom.cameraKeyframes != nil {
                let count = max(64, Int((upper - lower) / max(0.001, model.totalDuration / model.timeViewport.scale) * 2000))
                var times = (0...count).map { lower + (upper - lower) * Double($0) / Double(count) }
                times.append(contentsOf: item.zoom.cameraControlPoints.map(\.time).filter { $0 > lower && $0 < upper })
                for time in Set(times).sorted() {
                    let value = point(item.offset + time, item.zoom.scale(at: time))
                    if path.isEmpty { path.move(to: value) } else { path.addLine(to: value) }
                }
                return
            }
            var boundaries = [lower, upper]
            boundaries.append(contentsOf: [item.zoom.start, item.zoom.riseEnd, item.zoom.fallStart, item.zoom.end]
                .filter { $0 > lower && $0 < upper })
            boundaries = Array(Set(boundaries)).sorted()
            path.move(to: point(item.offset + lower, item.zoom.scale(at: lower)))
            for index in 0..<(boundaries.count - 1) {
                let a = boundaries[index], b = boundaries[index + 1]
                let middle = (a + b) / 2
                let phase = middle > item.zoom.start && middle < item.zoom.riseEnd ? 1
                    : middle > item.zoom.fallStart && middle < item.zoom.end ? 3 : 0
                if phase == 0 {
                    path.addLine(to: point(item.offset + b, item.zoom.scale(at: b)))
                } else {
                    let start = curveValue(item.zoom, at: a, phase: phase)
                    let end = curveValue(item.zoom, at: b, phase: phase)
                    let step = (b - a) / 3
                    path.addCurve(to: point(item.offset + b, end.value),
                                  control1: point(item.offset + a + step, start.value + start.slope * step),
                                  control2: point(item.offset + b - step, end.value - end.slope * step))
                }
            }
        }
    }

    private func zoomFill(_ item: CurveLocation, point: (Double, Double) -> CGPoint) -> Path {
        var path = zoomCurve(item, point: point)
        let (lower, upper) = visibleBounds(item)
        guard upper > lower else { return path }
        path.addLine(to: point(item.offset + upper, 1))
        path.addLine(to: point(item.offset + lower, 1))
        path.closeSubpath()
        return path
    }

    private func curveValue(_ zoom: ZoomSegment, at time: Double, phase: Int) -> (value: Double, slope: Double) {
        let a = phase == 1 ? zoom.start : zoom.fallStart
        let b = phase == 1 ? zoom.riseEnd : zoom.end
        let from = phase == 1 ? 1.0 : zoom.peak
        let to = phase == 1 ? zoom.peak : 1.0
        let span = max(0.000001, b - a)
        let t = min(1, max(0, (time - a) / span))
        return (from + (to - from) * t * t * (3 - 2 * t),
                (to - from) * 6 * t * (1 - t) / span)
    }

    private func nodeTime(_ zoom: ZoomSegment, index: Int) -> Double {
        switch index {
        case 0: return zoom.start
        case 1: return zoom.riseEnd
        case 2: return zoom.fallStart
        default: return zoom.end
        }
    }
}

private struct EditorIcon: View {
    let symbol: String
    let help: String
    var compact = false
    var selected = false
    var controlHeight: CGFloat = 30
    let action: () -> Void
    @AppState<Bool> private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 16 : 18, weight: .regular))
                .foregroundStyle(selected ? AppTheme.accent : AppTheme.ink)
                .shadow(color: compact ? .black.opacity(0.65) : .clear, radius: 1, y: 1)
                .frame(width: compact ? 24 : 32, height: controlHeight)
                .background(selected ? AppTheme.accent.opacity(0.16) : hovered ? AppTheme.ink.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovered = $0 }
    }
}
