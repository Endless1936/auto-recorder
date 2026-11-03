import AppKit

struct CaptureDisplayLayout: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let pixelSize: CGSize
}

@MainActor
func captureDisplayLayout() -> [CaptureDisplayLayout] {
    NSScreen.screens.compactMap { screen in
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
        let mode = CGDisplayCopyDisplayMode(id)
        return CaptureDisplayLayout(id: id, frame: screen.frame, scale: screen.backingScaleFactor,
            pixelSize: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0))
    }.sorted { $0.id < $1.id }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class RegionSelector {
    private var panel: SelectionPanel?
    private var completion: ((CGRect?) -> Void)?
    private var screenObserver: NSObjectProtocol?

    func begin(screen: NSScreen, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        guard panel == nil else { return }
        self.completion = completion
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        let defaultRegion = CGRect(x: screen.frame.width * 0.2, y: screen.frame.height * 0.2,
            width: screen.frame.width * 0.6, height: screen.frame.height * 0.6)
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                       scale: screen.backingScaleFactor, initial: initial ?? defaultRegion)
        view.onComplete = { [weak self] rect in self?.finish(rect) }
        panel.contentView = view
        self.panel = panel
        let initialLayout = captureDisplayLayout()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if captureDisplayLayout() != initialLayout { self?.finish(nil) }
                }
            }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let callback = completion
        completion = nil
        callback?(rect)
    }
}

@MainActor
final class RegionSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onComplete: ((CGRect?) -> Void)?
    private(set) var selection: CGRect?
    private let scale: CGFloat
    private var anchor = CGPoint.zero
    private var original: CGRect?
    private enum Drag { case pendingDrawing, drawing, moving, resizing(SelectionEdges) }
    private var drag: Drag?
    private var hoverEdges: SelectionEdges?
    private let sizeLabel = NSTextField(labelWithString: "拖拽选择录制区域")
    private let confirm = NSButton(title: "使用此区域", target: nil, action: nil)
    private var tracking: NSTrackingArea?

    init(frame: CGRect, scale: CGFloat, initial: CGRect?) {
        self.scale = scale
        self.selection = initial?.intersection(CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        setAccessibilityLabel("录制区域选择器；内部拖动移动，边角调整大小；方向键移动 1 点，Shift 10 点，Option 调整大小；回车确认，Esc 取消")
        let help = NSTextField(labelWithString: "内部拖动移动  ·  边角调整大小  ·  方向键微调  ·  回车确认")
        help.font = .systemFont(ofSize: 13, weight: .medium)
        help.textColor = .white
        help.toolTip = "方向键每次移动 1 点，按住 Shift 每次 10 点；按住 Option 调整右边与下边。Retina 屏幕 1 点通常对应 2 像素。拖动时 Esc 恢复原选区；再次 Esc 退出。"
        let helpHUD = hud(views: [help], spacing: 0)
        helpHUD.translatesAutoresizingMaskIntoConstraints = false
        addSubview(helpHUD)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .center
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        confirm.target = self
        confirm.action = #selector(accept)
        confirm.bezelStyle = .rounded
        confirm.controlSize = .large
        confirm.keyEquivalent = "\r"
        confirm.toolTip = "回车确认选区；Esc 取消"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        let controls = hud(views: [cancel, sizeLabel, confirm], spacing: 18)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            helpHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            helpHUD.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -38)
        ])
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func hud(views: [NSView], spacing: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12)
        ])
        return effect
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        window?.acceptsMouseMovedEvents = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fully clear pixels can pass clicks through a borderless window.
        // Keep the interior almost transparent but able to receive drags.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        let mask = NSBezierPath(rect: bounds)
        if let selection, !selection.isEmpty { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.46).setFill()
        mask.fill()
        if let rect = selection, !rect.isEmpty {
            NSColor.white.withAlphaComponent(0.98).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()
            if let edges = hoverEdges {
                let highlight = NSBezierPath()
                if edges.contains(.left) { highlight.move(to: CGPoint(x: rect.minX, y: rect.minY)); highlight.line(to: CGPoint(x: rect.minX, y: rect.maxY)) }
                if edges.contains(.right) { highlight.move(to: CGPoint(x: rect.maxX, y: rect.minY)); highlight.line(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
                if edges.contains(.top) { highlight.move(to: CGPoint(x: rect.minX, y: rect.minY)); highlight.line(to: CGPoint(x: rect.maxX, y: rect.minY)) }
                if edges.contains(.bottom) { highlight.move(to: CGPoint(x: rect.minX, y: rect.maxY)); highlight.line(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
                NSColor.controlAccentColor.setStroke()
                highlight.lineWidth = 3
                highlight.stroke()
            }
            for (point, edges) in handles(rect) {
                let active = hoverEdges == edges
                let radius: CGFloat = active ? 6 : 4
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                (active ? NSColor.controlAccentColor : NSColor.white).setFill(); handle.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke(); handle.lineWidth = 1; handle.stroke()
            }
        }
    }

    private func handles(_ rect: CGRect) -> [(CGPoint, SelectionEdges)] {
        [(CGPoint(x: rect.minX, y: rect.minY), [.left, .top]),
         (CGPoint(x: rect.midX, y: rect.minY), .top),
         (CGPoint(x: rect.maxX, y: rect.minY), [.right, .top]),
         (CGPoint(x: rect.maxX, y: rect.midY), .right),
         (CGPoint(x: rect.maxX, y: rect.maxY), [.right, .bottom]),
         (CGPoint(x: rect.midX, y: rect.maxY), .bottom),
         (CGPoint(x: rect.minX, y: rect.maxY), [.left, .bottom]),
         (CGPoint(x: rect.minX, y: rect.midY), .left)]
    }

    private func hitEdges(_ point: CGPoint) -> SelectionEdges? {
        guard let rect = selection else { return nil }
        return SelectionGeometry.hitEdges(point, rect: rect)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = convert(event.locationInWindow, from: nil)
        original = selection
        if let edges = hitEdges(anchor) { drag = .resizing(edges) }
        else if let selection, selection.contains(anchor) {
            drag = .moving
        } else {
            // Preserve a valid selection on a stray click. Replacing it requires a real drag.
            drag = .pendingDrawing
        }
        hoverEdges = hitEdges(anchor)
        if case .moving = drag { NSCursor.closedHand.set() }
        updateSelection()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        switch drag {
        case .pendingDrawing:
            guard hypot(delta.x, delta.y) >= SelectionGeometry.redrawThreshold else { return }
            drag = .drawing
            selection = SelectionGeometry.draw(from: anchor, to: point, size: bounds.size)
        case .drawing: selection = SelectionGeometry.draw(from: anchor, to: point, size: bounds.size)
        case .moving:
            if let original { selection = SelectionGeometry.move(original, delta: delta, size: bounds.size) }
        case .resizing(let edges):
            if let original { selection = SelectionGeometry.resize(original, edges: edges, delta: delta, size: bounds.size) }
        case nil: return
        }
        updateSelection()
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if case .drawing = drag, let selection,
           selection.width < SelectionGeometry.minimum || selection.height < SelectionGeometry.minimum {
            self.selection = original
        }
        drag = nil
        original = nil
        updateSelection()
        mouseMoved(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverEdges = hitEdges(point)
        needsDisplay = true
        if let edges = hitEdges(point) {
            if edges == .left || edges == .right { NSCursor.resizeLeftRight.set() }
            else if edges == .top || edges == .bottom { NSCursor.resizeUpDown.set() }
            else if edges == [.left, .top] || edges == [.right, .bottom] {
                NSCursor.frameResize(position: .topLeft, directions: .all).set()
            } else { NSCursor.frameResize(position: .topRight, directions: .all).set() }
        } else if selection?.contains(point) == true { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }
    override func mouseExited(with event: NSEvent) {
        hoverEdges = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if drag != nil {
                selection = original
                drag = nil
                original = nil
                hoverEdges = nil
                updateSelection()
            } else { cancel() }
        case 36, 76: accept()
        case 123, 124, 125, 126:
            guard let selection else { return }
            // Selection coordinates are logical display points, including on Retina screens.
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                y: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
            if event.modifierFlags.contains(.option) {
                self.selection = SelectionGeometry.resize(selection, edges: [.right, .bottom], delta: delta, size: bounds.size)
            } else {
                self.selection = SelectionGeometry.move(selection, delta: delta, size: bounds.size)
            }
            updateSelection()
        default: super.keyDown(with: event)
        }
    }
    private func updateSelection() {
        let valid = selection.map { $0.width >= SelectionGeometry.minimum && $0.height >= SelectionGeometry.minimum } ?? false
        confirm.isEnabled = valid
        if valid, let area = try? CaptureGeometry.area(region: selection, displaySize: bounds.size, scale: scale) {
            sizeLabel.stringValue = "\(area.pixelWidth) × \(area.pixelHeight) px"
        } else { sizeLabel.stringValue = "拖拽选择录制区域" }
        needsDisplay = true
    }
    @objc private func accept() {
        guard confirm.isEnabled, let selection,
              let area = try? CaptureGeometry.area(region: selection, displaySize: bounds.size, scale: scale) else { return }
        onComplete?(area.sourceRect)
    }
    @objc private func cancel() { onComplete?(nil) }
}

private final class RecordingRegionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A local-only guide; the capture filter excludes all of this process's windows.
@MainActor
final class RecordingRegionOverlay {
    private(set) var panel: NSPanel?

    func show(screen: NSScreen, region: CGRect) {
        hide()
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let region = region.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return }
        let panel = RecordingRegionPanel(contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "正在录制的区域"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = RecordingRegionMaskView(frame: bounds, region: region)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

@MainActor
final class RecordingRegionMaskView: NSView {
    override var isFlipped: Bool { true }
    let region: CGRect

    init(frame: CGRect, region: CGRect) {
        self.region = region
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        mask.appendRect(region)
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.46).setFill()
        mask.fill()
        // Keep the line outside the capture rectangle.
        let border = NSBezierPath(rect: region.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
    }
}
