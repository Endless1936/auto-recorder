import AppKit
import SwiftUI

struct SourcePopUpField: View {
    let items: [CaptureSourceItem]
    let selection: UInt32
    var onRefresh: (() -> Void)? = nil
    let onSelect: (UInt32) -> Void

    var body: some View {
        NativePopUpField(items: items.map { PopUpItem(id: $0.id, name: $0.name) },
                         selection: selection, placeholder: "选择来源", onRefresh: onRefresh, onSelect: onSelect)
    }
}

struct MicrophonePopUpField: View {
    let items: [MicrophoneItem]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        NativePopUpField(items: items.map { PopUpItem(id: $0.id, name: $0.name) },
                         selection: selection, placeholder: "系统默认", onRefresh: nil, onSelect: onSelect)
    }
}

private struct PopUpItem<ID: Hashable>: Equatable {
    let id: ID
    let name: String
}

private struct NativePopUpField<ID: Hashable>: NSViewRepresentable {
    let items: [PopUpItem<ID>]
    let selection: ID
    let placeholder: String
    let onRefresh: (() -> Void)?
    let onSelect: (ID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> PopUpContainer {
        let view = PopUpContainer()
        view.button.target = context.coordinator
        view.button.action = #selector(Coordinator.changed(_:))
        return view
    }

    func updateNSView(_ view: PopUpContainer, context: Context) {
        let coordinator = context.coordinator
        view.button.isEnabled = context.environment.isEnabled
        coordinator.onSelect = onSelect
        coordinator.onRefresh = onRefresh
        coordinator.selection = selection
        if coordinator.items != items || coordinator.hasRefresh != (onRefresh != nil) || view.button.numberOfItems == 0 {
            coordinator.items = items
            coordinator.hasRefresh = onRefresh != nil
            view.setItems(items.map(\.name), placeholder: placeholder, hasRefresh: onRefresh != nil)
        }
        coordinator.restoreSelection(view.button)
    }

    final class Coordinator: NSObject {
        var items: [PopUpItem<ID>] = []
        var selection: ID?
        var hasRefresh = false
        var onRefresh: (() -> Void)?
        var onSelect: (ID) -> Void

        init(onSelect: @escaping (ID) -> Void) { self.onSelect = onSelect }

        func restoreSelection(_ button: NSPopUpButton) {
            let index = items.firstIndex { $0.id == selection } ?? 0
            button.selectItem(at: index)
            button.toolTip = button.selectedItem?.toolTip
        }

        @objc func changed(_ button: NSPopUpButton) {
            if let index = button.selectedItem?.representedObject as? Int, items.indices.contains(index) {
                let item = items[index]
                selection = item.id
                button.toolTip = item.name
                onSelect(item.id)
            } else {
                restoreSelection(button)
                onRefresh?()
            }
        }
    }
}

private final class PopUpContainer: NSView, NSMenuDelegate {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    private var titles: [(item: NSMenuItem, title: String)] = []
    private let menuFont = NSFont.systemFont(ofSize: 14)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(AppTheme.paper).cgColor
        layer?.cornerRadius = 7
        button.isBordered = false
        button.font = menuFont
        button.contentTintColor = NSColor(AppTheme.ink)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.cell?.usesSingleLineMode = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.autoresizingMask = [.width, .height]
        button.menu?.autoenablesItems = false
        button.menu?.delegate = self
        button.menu?.font = menuFont
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    func setItems(_ names: [String], placeholder: String, hasRefresh: Bool) {
        button.removeAllItems()
        titles = []
        if names.isEmpty {
            let item = addItem(placeholder)
            item.isEnabled = false
        }
        for (index, name) in names.enumerated() {
            addItem(name).representedObject = index
        }
        if hasRefresh {
            button.menu?.addItem(.separator())
            addItem("刷新来源")
        }
        updateTitles()
    }

    @discardableResult
    private func addItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.toolTip = title
        button.menu?.addItem(item)
        titles.append((item, title))
        return item
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 10, y: 2, width: max(0, bounds.width - 20), height: max(0, bounds.height - 4))
        updateTitles()
    }

    func menuWillOpen(_ menu: NSMenu) { updateTitles() }

    private func updateTitles() {
        let width = max(0, button.bounds.width - 48)
        button.menu?.minimumWidth = button.bounds.width
        for (item, title) in titles {
            let displayTitle = truncated(title, width: width)
            if item.title != displayTitle { item.title = displayTitle }
        }
    }

    private func truncated(_ title: String, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: menuFont]
        if (title as NSString).size(withAttributes: attributes).width <= width { return title }
        let characters = Array(title)
        var lower = 0
        var upper = characters.count
        while lower < upper {
            let count = (lower + upper + 1) / 2
            let candidate = String(characters.prefix((count + 1) / 2)) + "…" + String(characters.suffix(count / 2))
            if (candidate as NSString).size(withAttributes: attributes).width <= width { lower = count }
            else { upper = count - 1 }
        }
        return String(characters.prefix((lower + 1) / 2)) + "…" + String(characters.suffix(lower / 2))
    }
}
