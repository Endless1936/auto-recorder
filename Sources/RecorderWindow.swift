import AppKit
import SwiftUI

@MainActor
final class RecorderWindow: NSWindow {
    private static let panelWidth: CGFloat = 600
    private let settings: RecorderSettings
    private var collapsedFrameHeight: CGFloat = 0
    private var fixedFrameSize: NSSize?

    // SwiftUI updates the hosting window's sizing defaults during layout.
    // Keep the recorder panel constrained across those updates.
    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { super.styleMask = newValue.subtracting(.resizable) }
    }
    override var minSize: NSSize {
        get { fixedFrameSize ?? super.minSize }
        set { super.minSize = fixedFrameSize ?? newValue }
    }
    override var maxSize: NSSize {
        get { fixedFrameSize ?? super.maxSize }
        set { super.maxSize = fixedFrameSize ?? newValue }
    }
    init(settings: RecorderSettings, onMode: @escaping (CaptureMode) -> Void, onSource: @escaping () -> Void,
         onRefresh: @escaping () -> Void,
         onAudio: @escaping () -> Void, onStart: @escaping () -> Void, onOpen: @escaping () -> Void,
         onDirectory: @escaping () -> Void, onRegion: @escaping () -> Void, onPermissions: @escaping () -> Void) {
        self.settings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 480), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Auto Recorder"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = AppTheme.nsBackground
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: RecorderPanel(settings: settings, onMode: onMode, onSource: onSource, onRefresh: onRefresh,
            onAudio: onAudio, onStart: onStart, onOpen: onOpen, onDirectory: onDirectory, onRegion: onRegion,
            onPermissions: onPermissions, onExpanded: { [weak self] in self?.setExpanded($0) }).ignoresSafeArea())
        hosting.sizingOptions = []
        contentView = hosting
        collapsedFrameHeight = frame.height
        fixedFrameSize = frame.size
        minSize = frame.size
        maxSize = frame.size
        standardWindowButton(.zoomButton)?.isEnabled = false
        collectionBehavior.insert(.fullScreenNone)
        center()
    }
    private func setExpanded(_ expanded: Bool) {
        let errorHeight = settings.error.isEmpty ? 0 : ceil((settings.error as NSString).boundingRect(
            with: NSSize(width: Self.panelWidth - 48, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]).height) + 10
        let height = collapsedFrameHeight + (expanded ? 62 : 0) + errorHeight
        let next = NSRect(x: frame.minX, y: frame.maxY - height, width: Self.panelWidth, height: height)
        fixedFrameSize = next.size
        minSize = next.size
        maxSize = next.size
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().setFrame(next, display: true)
        }
    }
    func savePreview(to url: URL) throws {
        displayIfNeeded()
        guard let view = contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: url) }
    }
}

private struct RecorderPanel: View {
    @ObservedObject var settings: RecorderSettings
    let onMode: (CaptureMode) -> Void
    let onSource: () -> Void
    let onRefresh: () -> Void
    let onAudio: () -> Void
    let onStart: () -> Void
    let onOpen: () -> Void
    let onDirectory: () -> Void
    let onRegion: () -> Void
    let onPermissions: () -> Void
    let onExpanded: (Bool) -> Void
    private var expanded: Bool { settings.advanced }
    private var locked: Bool { settings.busy || settings.recording }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "video").font(.system(size: 16, weight: .regular))
                Text("Auto Recorder").font(.system(size: 16, weight: .semibold))
            }.frame(maxWidth: .infinity).frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line.opacity(0.6)).frame(height: 0.6) }
            panel
        }.foregroundStyle(AppTheme.ink).tint(AppTheme.accent).background(AppTheme.background)
            .onChange(of: settings.advanced) { _, value in onExpanded(value) }
            .onChange(of: settings.error) { _, _ in onExpanded(expanded) }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                modeButton(.entireDisplay, title: "整个屏幕", symbol: "display")
                modeButton(.window, title: "单个窗口", symbol: "macwindow")
                modeButton(.region, title: "选定区域", symbol: "viewfinder")
            }.frame(height: 104).padding(.bottom, 18).disabled(locked)
            HStack(spacing: 12) {
                Text("录制来源").frame(width: 72, alignment: .leading)
                if settings.loadingSources { ProgressView().controlSize(.small); Spacer() }
                else {
                    SourcePopUpField(items: settings.sources, selection: settings.sourceID, onRefresh: onRefresh) { id in
                        settings.sourceID = id; onSource()
                    }.frame(maxWidth: .infinity).frame(height: 34)
                }
            }.frame(height: 36).padding(.bottom, 8).disabled(locked)
            HStack(spacing: 12) {
                Text("保存位置").frame(width: 72, alignment: .leading)
                Button(action: onDirectory) {
                    HStack(spacing: 9) {
                        Image(systemName: "folder").foregroundStyle(AppTheme.secondary)
                        Text(settings.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 5)
                        Image(systemName: "ellipsis").foregroundStyle(AppTheme.secondary)
                    }.padding(.horizontal, 12).frame(height: 34)
                        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help(settings.directory.path)
            }.padding(.bottom, 14).disabled(locked)
            separator
            HStack(spacing: 16) {
                HStack(spacing: 9) {
                    AudioMeterIcon(microphone: false, level: settings.systemLevel, enabled: settings.systemAudio)
                    Text("电脑音频").fixedSize()
                    Spacer(minLength: 2)
                    Toggle("电脑音频", isOn: Binding(get: { settings.systemAudio }, set: {
                        settings.systemAudio = $0; onAudio()
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.frame(maxWidth: .infinity)
                Rectangle().fill(AppTheme.line).frame(width: 1, height: 26)
                HStack(spacing: 9) {
                    AudioMeterIcon(microphone: true, level: settings.microphoneLevel, enabled: settings.microphone)
                    MicrophonePopUpField(items: settings.microphones, selection: settings.microphoneID) { id in
                        settings.microphoneID = id; onAudio()
                    }.frame(minWidth: 0, maxWidth: .infinity).frame(height: 34)
                        .accessibilityLabel("麦克风设备")
                    Toggle("麦克风", isOn: Binding(get: { settings.microphone }, set: {
                        settings.microphone = $0; onAudio()
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.frame(maxWidth: .infinity)
            }.frame(height: 56).disabled(locked)
            separator
            HStack(spacing: 16) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { settings.advanced.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .medium)).frame(width: 25)
                        Text("高级设置")
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).frame(maxWidth: .infinity)
                Rectangle().fill(AppTheme.line).frame(width: 1, height: 24)
                HStack(spacing: 9) {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 20, weight: .regular)).frame(width: 25)
                    Text("自动放大")
                    Spacer(minLength: 2)
                    Toggle("自动放大", isOn: $settings.autoZoom).labelsHidden()
                        .toggleStyle(.switch).controlSize(.small)
                        .onChange(of: settings.autoZoom) { _, _ in settings.save() }
                }.frame(maxWidth: .infinity)
            }.frame(height: 48).disabled(locked)
            if expanded {
                HStack(spacing: 24) {
                    HStack(spacing: 10) {
                        Text("画质").fixedSize()
                        SourcePopUpField(items: [CaptureSourceItem(id: 0, name: "HEVC"), CaptureSourceItem(id: 1, name: "ProRes 422")], selection: UInt32(settings.quality)) { settings.quality = Int($0); settings.save() }
                    }
                    HStack(spacing: 10) {
                        Text("帧率").fixedSize()
                        SourcePopUpField(items: [CaptureSourceItem(id: 30, name: "30 fps"), CaptureSourceItem(id: 60, name: "60 fps")], selection: UInt32(settings.fps)) { settings.fps = Int($0); settings.save() }
                    }
                }.frame(height: 34).padding(.horizontal, 14).frame(height: 52)
                    .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .top))).disabled(locked)
                    .onChange(of: settings.quality) { _, _ in settings.save() }
                    .onChange(of: settings.fps) { _, _ in settings.save() }
            }
            Spacer(minLength: 14)
            HStack {
                Button(action: onOpen) { Label("打开工程", systemImage: "folder") }
                    .buttonStyle(.plain).font(.system(size: 14)).frame(width: 108, alignment: .leading).help("打开录屏工程文件夹…")
                Spacer(minLength: 12)
                Button(action: onStart) {
                    Text(settings.busy ? "正在保存…" : settings.recording ? "停止录制" : "开始录制")
                }.buttonStyle(AppPrimaryButtonStyle()).frame(width: 200).disabled(settings.busy)
                Spacer(minLength: 12)
                Button(action: onPermissions) { Label("权限设置", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.system(size: 14)).frame(width: 108, alignment: .trailing).help("打开系统录屏权限设置…")
            }.padding(.top, 8)
            if !settings.error.isEmpty {
                Text(settings.error).font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                    .padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 18).font(.system(size: 15))
    }

    private var separator: some View { Rectangle().fill(AppTheme.line).frame(height: 1) }
    private func modeButton(_ mode: CaptureMode, title: String, symbol: String) -> some View {
        let selected = settings.mode == mode
        let regionAction = selected && mode == .region
        return Button {
            if regionAction { onRegion() } else { onMode(mode) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 29, weight: .light)).frame(height: 34)
                Text(title).font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(regionAction ? Color(red: 0.08, green: 0.15, blue: 0.12) : AppTheme.ink)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(regionAction ? AppTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.frame(maxWidth: .infinity).frame(height: 104)
                .background(selected ? AppTheme.accent.opacity(0.045) : AppTheme.paper.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                    selected ? AppTheme.accent : AppTheme.line, lineWidth: selected ? 1.5 : 0.8))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                            .foregroundStyle(AppTheme.accent).padding(10)
                    }
                }.contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .help(regionAction ? "点击选择或重新选择录制区域\n当前：\(settings.regionTitle)" : title)
    }
}
