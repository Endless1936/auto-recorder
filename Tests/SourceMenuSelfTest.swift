import AppKit
import SwiftUI

@MainActor
enum SourceMenuSelfTest {
    private final class MenuProbe: NSObject, NSMenuDelegate {
        var opened = false
        var sawFreshItems = false
        func menuWillOpen(_ menu: NSMenu) {
            opened = true
            sawFreshItems = menu.items.contains { $0.toolTip == "新窗口" }
            DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
        }
    }

    static func run() async throws {
        var calls = 0
        var losesSelection = false
        var chosen: UInt32?
        let initial = [CaptureSourceItem(id: 7, name: "原窗口")]
        let view = NSHostingView(rootView: SourcePopUpField(items: initial, selection: 7, onOpen: {
            calls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return ([CaptureSourceItem(id: 7, name: "更新后的窗口"), CaptureSourceItem(id: 9, name: "新窗口")], losesSelection ? 0 : 7)
        }, onSelect: { chosen = $0 }).frame(width: 360, height: 34))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 60_000_000)
        func find(_ view: NSView) -> PreparedSourcePopUpButton? {
            (view as? PreparedSourcePopUpButton) ?? view.subviews.compactMap { find($0) }.first
        }
        guard let button = find(view) else { throw RecorderError.message("来源菜单缺少原生控件。") }
        try check(button.numberOfItems == 1 && button.selectedItem?.toolTip == "原窗口", "初始来源显示错误")
        let first = Task { @MainActor in await button.prepareForOpening() }
        while calls == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let duplicate = await button.prepareForOpening()
        let opened = await first.value
        try check(!duplicate && opened && calls == 1, "重复打开导致多次刷新或丢失菜单")
        try check(button.numberOfItems == 2 && button.selectedItem?.toolTip == "更新后的窗口", "自动刷新没有保留选定窗口")
        try check(!button.itemArray.contains { $0.isSeparatorItem || $0.title.contains("刷新") }, "来源菜单仍有刷新项")
        button.selectItem(at: 1)
        button.sendAction(button.action, to: button.target)
        try check(chosen == 9, "刷新后菜单选择映射到旧来源")

        losesSelection = true
        try check(await button.prepareForOpening(), "不能再次打开菜单")
        try check(button.selectedItem?.isEnabled == false && button.selectedItem?.title == "选择来源",
                  "来源失效后静默选中了其他窗口")
        losesSelection = false
        let probe = MenuProbe()
        button.menu?.delegate = probe
        button.performClick(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !probe.opened, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(probe.opened && probe.sawFreshItems && calls == 3,
                  "原生菜单没有在完成刷新后才展开")
        print("PASS source menu: refresh before native opening, one pending request, stable selection, fresh ID mapping, missing-source placeholder and no refresh entry")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message(message) }
    }
}
