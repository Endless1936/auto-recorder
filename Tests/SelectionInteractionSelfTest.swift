import AppKit

/// Exercises the app's view handlers directly. Events are never posted to the OS.
@MainActor
enum SelectionInteractionSelfTest {
    static func checkUnchangedDisplayNotification() async throws {
        guard let screen = NSScreen.screens.first else { throw RecorderError.message("测试缺少可用显示器。") }
        let selector = RegionSelector()
        var callbacks = 0
        selector.begin(screen: screen, initial: CGRect(x: 100, y: 100, width: 400, height: 300)) { _ in callbacks += 1 }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(nanoseconds: 80_000_000)
        guard callbacks == 0 else {
            throw RecorderError.message("无布局变化的屏幕通知不应取消选区。")
        }
        selector.cancel()
        guard callbacks == 1 else { throw RecorderError.message("选区取消回调异常。") }
        print("PASS unchanged display notification keeps selector open")
    }

    static func run() throws {
        let height: CGFloat = 900
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1440, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 1440, height: height), scale: 2, initial: nil)
        panel.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: height - point.y),
                modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func gesture(_ start: CGPoint, _ end: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, start))
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw RecorderError.message("选区交互测试失败：\(message)") }
        }
        gesture(CGPoint(x: 800, y: 500), CGPoint(x: 100, y: 100))
        try check(view.selection == CGRect(x: 100, y: 100, width: 700, height: 400), "拖拽创建")
        gesture(CGPoint(x: 300, y: 300), CGPoint(x: 350, y: 340))
        try check(view.selection == CGRect(x: 150, y: 140, width: 700, height: 400), "内部移动")
        gesture(CGPoint(x: 850, y: 540), CGPoint(x: 950, y: 620))
        try check(view.selection == CGRect(x: 150, y: 140, width: 800, height: 480), "右下角调整")
        var callbacks: [CGRect?] = []
        view.onComplete = { callbacks.append($0) }
        let beforeClicks = view.selection
        for clicks in [1, 2] {
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 500, y: 350), clicks: clicks))
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 500, y: 350), clicks: clicks))
        }
        try check(view.selection == beforeClicks && callbacks.isEmpty, "内部单击和双击均不确认")
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 500, y: 350), clicks: 2))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 560, y: 380)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 560, y: 380), clicks: 2))
        try check(view.selection == beforeClicks?.offsetBy(dx: 60, dy: 30) && callbacks.isEmpty,
                  "连续点击后仍可拖动且尺寸不变")
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds), let selection = view.selection {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let color = bitmap.colorAt(x: Int(selection.midX), y: Int(selection.midY))
            try check((color?.alphaComponent ?? 0) > 0, "亮色内部必须有鼠标命中底色")
        } else { throw RecorderError.message("选区绘制缓存失败。") }
        func key(_ code: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let existing = view.selection
        gesture(CGPoint(x: 1200, y: 700), CGPoint(x: 1200, y: 700))
        try check(view.selection == existing, "空白单击保留框选")
        gesture(CGPoint(x: 1200, y: 700), CGPoint(x: 1203, y: 703))
        try check(view.selection == existing, "空白点击抖动保留框选")
        gesture(CGPoint(x: 1200, y: 700), CGPoint(x: 1220, y: 710))
        try check(view.selection == existing, "无效的小重画恢复原框")
        gesture(CGPoint(x: 1200, y: 700), CGPoint(x: 1350, y: 800))
        try check(view.selection == CGRect(x: 1200, y: 700, width: 150, height: 100), "空白处有意拖动重画")
        gesture(CGPoint(x: 1365, y: 815), CGPoint(x: 1385, y: 825))
        try check(view.selection == CGRect(x: 1200, y: 700, width: 170, height: 110), "扩大角控制点命中区")
        gesture(CGPoint(x: 1381, y: 755), CGPoint(x: 1401, y: 755))
        try check(view.selection == CGRect(x: 1200, y: 700, width: 190, height: 110), "扩大整条边命中区")
        view.keyDown(with: key(123))
        try check(view.selection?.minX == 1199, "Retina 方向键移动 1 点")
        view.keyDown(with: key(126, "", .shift))
        try check(view.selection?.minY == 690, "Shift 方向键移动 10 点")
        view.keyDown(with: key(124, "", .option))
        try check(view.selection?.width == 191, "Option 方向键调整尺寸")
        for _ in 0..<200 { view.keyDown(with: key(124, "", [.shift, .option])) }
        try check(view.selection?.maxX == 1440, "键盘扩大限制在屏幕内")
        for _ in 0..<200 { view.keyDown(with: key(123, "", [.shift, .option])) }
        try check(view.selection?.width == SelectionGeometry.minimum, "键盘缩小保持最小尺寸")
        for _ in 0..<200 { view.keyDown(with: key(124, "", .shift)) }
        try check(view.selection?.maxX == 1440, "键盘移动限制在屏幕内")
        let beforeEscape = view.selection
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 500, y: 500)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 700, y: 600)))
        view.keyDown(with: key(53, "\u{1b}"))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 700, y: 600)))
        try check(view.selection == beforeEscape && callbacks.isEmpty, "拖动时 Esc 恢复原框且不关闭")
        view.keyDown(with: key(36, "\r"))
        try check(callbacks.count == 1 && callbacks[0] == view.selection, "回车确认")
        view.keyDown(with: key(53, "\u{1b}"))
        try check(callbacks.count == 2 && callbacks[1] == nil, "Esc 取消")
        print("PASS selection view: draw, fixed-size move after single/double click, interior hit surface, generous edge/corner targets, outside click retention, deliberate redraw, keyboard point/resize bounds, drag rollback, Return confirm, Esc cancel")
        panel.close()
        try checkRecordingOverlay()
    }

    private static func checkRecordingOverlay() throws {
        guard let screen = NSScreen.screens.first else { throw RecorderError.message("测试缺少可用显示器。") }
        let size = screen.frame.size
        let request = CGRect(x: size.width * 0.25, y: size.height * 0.25,
                             width: size.width * 0.5, height: size.height * 0.5)
        let area = try CaptureGeometry.area(region: request, displaySize: size, scale: screen.backingScaleFactor)
        let overlay = RecordingRegionOverlay()
        defer { overlay.hide() }
        overlay.show(screen: screen, region: area.sourceRect)
        guard let panel = overlay.panel, panel.isVisible, panel.ignoresMouseEvents,
              !panel.canBecomeKey, !panel.canBecomeMain, panel.frame == screen.frame,
              let view = panel.contentView as? RecordingRegionMaskView,
              view.isFlipped, view.region == area.sourceRect,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RecorderError.message("录制范围提示的坐标、穿透或焦点设置错误。")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let inside = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        let outside = bitmap.colorAt(x: 5, y: 5)
        guard (inside?.alphaComponent ?? 1) < 0.01, (outside?.alphaComponent ?? 0) > 0.4 else {
            throw RecorderError.message("录制范围提示应仅使选区外围变暗。")
        }
        overlay.hide()
        overlay.hide()
        guard overlay.panel == nil else { throw RecorderError.message("停止后未移除录制范围提示。") }
        print("PASS recording region guide: aligned crop, flipped points, clear interior, dim exterior, click-through, nonactivating, idempotent cleanup")
    }
}
