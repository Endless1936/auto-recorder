import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let recorder = Recorder()
    private let settings = RecorderSettings()
    private let levels = AudioLevelMonitor()
    private let selector = RegionSelector()
    private var window: RecorderWindow!
    private var editorWindow: EditorWindow?
    private var editor: EditorModel?
    private var exportPanel: NSPanel?
    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var shortcuts: GlobalShortcuts?
    private var lastLayout: [CaptureDisplayLayout] = []
    private var screenObserver: NSObjectProtocol?
    private var selectedRegion: CGRect?
    private var selecting = false
    private var sourceGeneration = 0
    private var monitorGeneration = 0
    private var windowSources: [SCWindow] = []
    private var activeFolder: URL?
    private var activeFPS: Int32 = 60
    private var activeQuality: RecordingQuality = .hevc
    private var activeAutoZoom = true
    private var openingProject = false
    private var quitAfterSave = false
    private var quitAfterExport = false
    private var integrationDirectory: URL?
    private var subscriptions = Set<AnyCancellable>()
    private var captureFixture: WindowCaptureFixture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--window-capture-fixture"), CommandLine.arguments.count > index + 1 {
            do { captureFixture = try WindowCaptureFixture(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
            catch { NSLog("Window fixture: %@", error.localizedDescription); NSApp.terminate(nil) }
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        window = RecorderWindow(settings: settings,
            onMode: { [weak self] in self?.changeMode($0) },
            onSource: { [weak self] in self?.sourceChanged() },
            onRefresh: { [weak self] in await self?.refreshSources() },
            onAudio: { [weak self] in self?.audioChanged() },
            onStart: { [weak self] in self?.toggleRecording() },
            onOpen: { [weak self] in self?.openProject() },
            onDirectory: { [weak self] in self?.chooseDirectory() },
            onRegion: { [weak self] in self?.chooseRegion() },
            onPermissions: { [weak self] in self?.openPermissions() })
        window.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lastLayout = captureDisplayLayout()
        refreshDisplays()
        refreshMicrophones()
        recorder.onChange = { [weak self] in self?.updateState() }
        recorder.onPrepareWindow = { [weak self] in
            self?.window.orderOut(nil); self?.editorWindow?.orderOut(nil)
        }
        recorder.onLevels = { [weak self] system, mic in
            self?.applyLevels(system: system, microphone: mic)
        }
        recorder.onFinished = { [weak self] url, _, error in
            guard let self else { return }
            self.openingProject = true
            Task { await self.finishProject(rawURL: url, captureError: error) }
        }
        recorder.onError = { [weak self] in self?.captureFailed($0) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let layout = captureDisplayLayout()
                guard layout != self.lastLayout else { return }
                self.lastLayout = layout; self.selector.cancel(); self.selectedRegion = nil
                if self.recorder.state == .recording || self.recorder.state == .paused || self.recorder.state == .starting {
                    await self.recorder.stop(captureError: RecorderError.message("显示器布局已改变，录制已停止并保存。"))
                } else { self.refreshDisplays() }
            }
        }
        shortcuts = GlobalShortcuts(onRecord: { [weak self] in self?.toggleRecording() },
                                    onPause: { [weak self] in self?.togglePause() })
        updateState()
        showWindow()

        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--render-previews"), arguments.count > i + 1 {
            let directory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            Task { @MainActor [self] in
                do {
                    monitorGeneration += 1
                    await levels.stop()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    try await WindowSnapshots.save(window, to: directory.appendingPathComponent("recorder.png"))
                    settings.advanced = true
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    try await WindowSnapshots.save(window, to: directory.appendingPathComponent("recorder-expanded.png"))
                    settings.advanced = false
                    if arguments.contains("--recorder-qa") {
                        settings.mode = .region
                        settings.regionTitle = "640 × 360"
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        try await WindowSnapshots.save(window, to: directory.appendingPathComponent("recorder-region.png"))
                        settings.microphones = [MicrophoneItem(id: "qa-long-name", name: "外接 USB 音频接口 · 超长名称麦克风设备")]
                        settings.microphoneID = "qa-long-name"
                        settings.directory = URL(fileURLWithPath: "/Users/Shared/很长的项目保存目录/AI 工具操作演示和教程录屏")
                        settings.error = "所选窗口已关闭，请重新选择录制来源；你原来的工程和保存位置不会受到影响。"
                        settings.advanced = true
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        try await WindowSnapshots.save(window, to: directory.appendingPathComponent("recorder-long-content.png"))
                        NSLog("Recorder constraints: frame=%@ min=%@ max=%@ resizable=%@", NSStringFromRect(window.frame), NSStringFromSize(window.minSize), NSStringFromSize(window.maxSize), window.styleMask.contains(.resizable) ? "YES" : "NO")
                    }
                    if let projectIndex = arguments.firstIndex(of: "--preview-project"), arguments.count > projectIndex + 1 {
                        await loadProject(URL(fileURLWithPath: arguments[projectIndex + 1], isDirectory: true))
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        if let editorWindow {
                            try await WindowSnapshots.save(editorWindow, to: directory.appendingPathComponent("editor.png"))
                            if arguments.contains("--framing-qa"), let editor,
                               let clip = editor.clips.first(where: { !$0.zooms.isEmpty }),
                               let zoom = clip.zooms.first {
                                editor.isPlaying = false
                                editor.selectZoom(zoom.id)
                                editor.seek(editor.startTime(of: clip.id) + min(clip.duration, max(0, (zoom.riseEnd + zoom.fallStart) / 2)))
                                editor.setShowsFramingOverlay(true)
                                for _ in 0..<100 {
                                    if editor.isFramingPreviewReady { break }
                                    try await Task.sleep(nanoseconds: 30_000_000)
                                }
                                guard editor.isFramingPreviewReady else { throw RecorderError.message("取景预览未就绪。") }
                                try await Task.sleep(nanoseconds: 250_000_000)
                                try await WindowSnapshots.save(editorWindow, to: directory.appendingPathComponent("editor-framing.png"))
                            }
                            var frame = editorWindow.frame
                            frame.size = NSSize(width: 980, height: 730)
                            editorWindow.setFrame(frame, display: true)
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            try await WindowSnapshots.save(editorWindow, to: directory.appendingPathComponent("editor-minimum.png"))
                            if let screen = editorWindow.screen {
                                editorWindow.setFrame(screen.visibleFrame, display: true)
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                try await WindowSnapshots.save(editorWindow, to: directory.appendingPathComponent("editor-large.png"))
                            }
                        }
                    }
                } catch { NSLog("Preview: %@", error.localizedDescription) }
                NSApp.terminate(nil)
            }
        } else if let i = arguments.firstIndex(of: "--editor-ui-test"), arguments.count > i + 1 {
            let directory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            integrationDirectory = directory
            Task { @MainActor [self] in
                do {
                    monitorGeneration += 1
                    await levels.stop()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard let projectIndex = arguments.firstIndex(of: "--open-project"), arguments.count > projectIndex + 1 else {
                        throw RecorderError.message("交互验证需要指定工程副本。")
                    }
                    await loadProject(URL(fileURLWithPath: arguments[projectIndex + 1], isDirectory: true))
                    guard let editorWindow, let editor, editor.hasProject else {
                        throw RecorderError.message("交互验证未能打开工程副本。")
                    }
                    try await EditorUISelfTest.run(window: editorWindow, model: editor, directory: directory)
                    integrationReport("COMPLETED: editor UI regression")
                } catch { integrationReport("FAILED: \(error.localizedDescription)") }
            }
        } else if let i = arguments.firstIndex(of: "--integration-test"), arguments.count > i + 1 {
            integrationDirectory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            Task { await self.integrationTest() }
        } else if let i = arguments.firstIndex(of: "--open-project"), arguments.count > i + 1 {
            Task { await self.loadProject(URL(fileURLWithPath: arguments[i + 1], isDirectory: true)) }
        } else { restartLevels() }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appRoot = NSMenuItem(); main.addItem(appRoot)
        let app = NSMenu(); appRoot.submenu = app
        item("关于Auto Recorder", #selector(about), in: app)
        item("录屏权限…", #selector(openPermissions), in: app)
        app.addItem(.separator())
        item("退出Auto Recorder", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp, in: app)
        let fileRoot = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); main.addItem(fileRoot)
        let file = NSMenu(title: "文件"); fileRoot.submenu = file
        item("返回录制", #selector(showWindow), key: "n", in: file)
        item("打开工程…", #selector(openProject), key: "o", in: file)
        item("导出视频…", #selector(exportVideo), key: "e", in: file)
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); main.addItem(editRoot)
        let edit = NSMenu(title: "编辑"); editRoot.submenu = edit
        item("撤销", #selector(undoEdit), key: "z", in: edit)
        item("分割片段", #selector(splitEdit), key: "b", in: edit)
        item("删除所选内容", #selector(deleteEdit), key: String(UnicodeScalar(NSDeleteCharacter)!), in: edit)
        let captureRoot = NSMenuItem(title: "录制", action: nil, keyEquivalent: ""); main.addItem(captureRoot)
        let capture = NSMenu(title: "录制"); captureRoot.submenu = capture
        let record = item("开始／停止录制", #selector(toggleRecording), key: "r", in: capture)
        record.keyEquivalentModifierMask = [.command, .shift]
        let pause = item("暂停／继续", #selector(togglePause), key: "p", in: capture)
        pause.keyEquivalentModifierMask = [.command, .shift]
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(exportVideo): return editorWindow?.isVisible == true && editor?.isExporting != true && !openingProject
        case #selector(undoEdit): return editorWindow?.isKeyWindow == true && editor?.canUndo == true
        case #selector(splitEdit): return editorWindow?.isKeyWindow == true && editor?.isExporting != true
        case #selector(deleteEdit):
            menuItem.title = editor?.editingSelectionTarget == .cameraAnchors ? "删除所选节点" : "删除所选片段"
            return editorWindow?.canDeleteSelection == true
        case #selector(openProject): return recorder.state == .idle && !openingProject && editor?.isExporting != true
        case #selector(togglePause): return recorder.state == .recording || recorder.state == .paused
        default: return true
        }
    }

    @discardableResult
    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil, in menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self; menu.addItem(entry); return entry
    }

    private func refreshMicrophones() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName
        settings.microphones = [MicrophoneItem(id: "", name: defaultName.map { "默认 · \($0)" } ?? "系统默认")] + devices.map { MicrophoneItem(id: $0.uniqueID, name: $0.localizedName) }
        if !settings.microphones.contains(where: { $0.id == settings.microphoneID }) { settings.microphoneID = "" }
    }
    private func refreshDisplays() {
        guard settings.mode != .window else { Task { await refreshWindows(selectFirst: true) }; return }
        settings.sources = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return CaptureSourceItem(id: id, name: screen.localizedName)
        }
        if !settings.sources.contains(where: { $0.id == settings.sourceID }) { settings.sourceID = settings.sources.first?.id ?? 0 }
        settings.loadingSources = false
    }
    private func refreshWindows(selectFirst: Bool = false) async {
        guard recorder.state == .idle, !settings.busy, !selecting, settings.mode == .window else { return }
        sourceGeneration += 1
        let generation = sourceGeneration
        settings.loadingSources = true
            do {
                if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() { throw RecorderError.screenAuthorization }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard sourceGeneration == generation, settings.mode == .window,
                      recorder.state == .idle, !settings.busy else { return }
                windowSources = content.windows.filter {
                    $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                    $0.frame.width > 80 && $0.frame.height > 60 && $0.windowLayer == 0
                }
                settings.sources = windowSources.map {
                    let application = $0.owningApplication?.applicationName ?? "窗口"
                    let name = ($0.title?.isEmpty == false) ? "\(application) · \($0.title!)" : application
                    return CaptureSourceItem(id: $0.windowID, name: name)
                }
                if !settings.sources.contains(where: { $0.id == settings.sourceID }) {
                    settings.sourceID = selectFirst ? settings.sources.first?.id ?? 0 : 0
                }
                settings.error = settings.sources.isEmpty ? "没有可用窗口，请先打开要录制的应用。" :
                    settings.sourceID == 0 ? "请选择要录制的窗口。" : ""
            } catch {
                if sourceGeneration == generation { settings.error = "请允许录屏后重新打开窗口列表。" }
            }
            if sourceGeneration == generation { settings.loadingSources = false }
    }

    private func changeMode(_ mode: CaptureMode) {
        guard recorder.state == .idle, !settings.busy, !selecting else { return }
        guard settings.mode != mode else { return }
        sourceGeneration += 1
        settings.mode = mode; settings.sourceID = 0; selectedRegion = nil; settings.regionTitle = "选择区域"
        settings.error = ""; refreshDisplays()
    }
    private func refreshSources() async {
        guard recorder.state == .idle, !selecting else { return }
        let previousID = settings.sourceID
        if settings.mode == .window { await refreshWindows() }
        else { refreshDisplays() }
        if settings.mode != .window, settings.sourceID != previousID {
            selectedRegion = nil; settings.regionTitle = "选择区域"
        }
    }
    private func sourceChanged() {
        guard recorder.state == .idle else { return }
        selectedRegion = nil; settings.regionTitle = "选择区域"; refreshDisplays()
    }
    private var displayID: CGDirectDisplayID {
        settings.mode == .window ? CGMainDisplayID() : settings.sourceID
    }
    private var selectedScreen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }
    private func chooseRegion(startAfter: Bool = false) {
        guard recorder.state == .idle, !selecting, let screen = selectedScreen else { return }
        selecting = true; window.orderOut(nil)
        selector.begin(screen: screen, initial: selectedRegion) { [weak self] area in
            guard let self else { return }
            self.selecting = false
            if let area {
                self.selectedRegion = area
                self.settings.regionTitle = "\(Int(area.width)) × \(Int(area.height))"
            }
            self.showWindow()
            if startAfter, area != nil { self.toggleRecording() }
        }
    }

    private func audioChanged() {
        settings.save(); refreshMicrophones()
        Task {
            if settings.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            restartLevels()
        }
    }
    private func applyLevels(system: Double, microphone: Double) {
        func value(_ rms: Double, previous: Double, enabled: Bool) -> Double {
            guard enabled else { return 0 }
            let target = rms > 0.00001 ? min(1, max(0, (20 * log10(rms) + 55) / 50)) : 0
            return previous + (target - previous) * (target > previous ? 0.65 : 0.25)
        }
        settings.systemLevel = value(system, previous: settings.systemLevel, enabled: settings.systemAudio)
        settings.microphoneLevel = value(microphone, previous: settings.microphoneLevel, enabled: settings.microphone)
    }
    private func restartLevels() {
        monitorGeneration += 1
        let generation = monitorGeneration
        Task { [self] in
            await levels.stop()
            guard generation == monitorGeneration, recorder.state == .idle, window.isVisible else { return }
            await levels.start(system: settings.systemAudio, microphone: settings.microphone,
                               microphoneID: settings.microphoneID.isEmpty ? nil : settings.microphoneID) { [weak self] system, mic in
                guard let self, self.recorder.state == .idle else { return }
                self.applyLevels(system: system, microphone: mic)
            }
        }
    }
    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择录制保存位置"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = settings.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.directory = url; self?.settings.save()
        }
    }

    @objc private func toggleRecording() {
        if recorder.state == .recording || recorder.state == .paused { stopRecording(); return }
        guard recorder.state == .idle, !selecting, !settings.busy, !openingProject,
              editor?.isExporting != true, exportPanel == nil else { return }
        if settings.mode == .region, selectedRegion == nil { chooseRegion(startAfter: true); return }
        if settings.sourceID == 0 { settings.error = "请先选择录制来源。"; return }
        guard prepareToLeaveEditor() else { return }
        settings.save(); settings.error = ""; settings.busy = true
        sourceGeneration += 1
        Task {
            do {
                monitorGeneration += 1; await levels.stop()
                let directory = try ProjectStore.createFolder(in: settings.directory)
                activeFolder = directory
                let raw = directory.appendingPathComponent(directory.lastPathComponent + ".mov")
                activeFPS = settings.fps == 30 ? 30 : 60
                activeQuality = RecordingQuality(rawValue: settings.quality) ?? .hevc
                activeAutoZoom = settings.autoZoom
                await recorder.start(displayID: displayID, url: raw, fps: activeFPS, quality: activeQuality,
                    region: settings.mode == .region ? selectedRegion : nil,
                    audioOptions: CaptureAudioOptions(systemAudio: settings.systemAudio, microphone: settings.microphone),
                    autoZoom: settings.autoZoom, windowID: settings.mode == .window ? settings.sourceID : nil,
                    microphoneID: settings.microphoneID.isEmpty ? nil : settings.microphoneID)
            } catch { settings.busy = false; showError(error) }
        }
    }
    @objc private func stopRecording() { Task { await recorder.stop() } }
    @objc private func togglePause() {
        if recorder.state == .recording { recorder.pause() }
        else if recorder.state == .paused { recorder.resume() }
    }
    private func updateState() {
        settings.recording = recorder.state == .recording || recorder.state == .paused
        settings.paused = recorder.state == .paused
        settings.busy = recorder.state == .starting || recorder.state == .saving || recorder.state == .processing
        if settings.recording { window.orderOut(nil); editorWindow?.orderOut(nil) }
        if settings.recording, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
        }
        if !settings.recording { ticker?.invalidate(); ticker = nil }
        updateStatus()
    }
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let active = settings.recording
        let symbol = active ? (settings.paused ? "pause.circle.fill" : "record.circle.fill") : "record.circle"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Auto Recorder")?
            .withSymbolConfiguration(.init(paletteColors: [active ? NSColor(AppTheme.accent) : .labelColor]))
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: active ? " \(appTime(recorder.elapsedDuration))" : "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        statusItem.menu = statusMenu(recording: active, paused: settings.paused)
    }

    func statusMenu(recording: Bool, paused: Bool) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        if recording {
            item(paused ? "继续录制" : "暂停录制", #selector(togglePause), in: menu)
            item("停止并编辑", #selector(stopRecording), in: menu)
            menu.addItem(.separator())
        }
        item("录制面板", #selector(showWindow), in: menu)
        menu.addItem(.separator())
        item("退出Auto Recorder", #selector(NSApplication.terminate(_:)), target: NSApp, in: menu)
        return menu
    }
    private func captureFailed(_ error: Error) {
        quitAfterSave = false
        if RecorderError.isScreenAuthorization(error) {
            settings.error = "请完成系统的录屏授权，然后退出并重新打开Auto Recorder。"
            if integrationDirectory != nil { integrationReport("BLOCKED: \(error.localizedDescription)") }
            return
        }
        if integrationDirectory != nil { integrationReport("FAILED: \(error.localizedDescription)"); return }
        showWindow(); showError(error); restartLevels()
    }
    private func finishProject(rawURL: URL, captureError: Error?) async {
        openingProject = true
        do {
            let asset = AVURLAsset(url: rawURL)
            let duration = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecorderError.message("原片缺少视频轨道。")
            }
            let pixelSize = try await video.load(.naturalSize)
            let folder = activeFolder ?? rawURL.deletingLastPathComponent()
            _ = try ProjectStore.create(directory: folder, rawURL: rawURL, trace: recorder.lastTrace ?? CursorTrace(samples: []),
                fps: activeFPS, quality: activeQuality, duration: duration, pixelSize: pixelSize,
                autoZoomEnabled: activeAutoZoom)
            if integrationDirectory == nil { UserDefaults.standard.set(folder, forKey: "lastProject") }
            if integrationDirectory != nil {
                openingProject = false; integrationReport("COMPLETED: \(folder.path)")
            } else {
                openingProject = false
                await loadProject(folder)
                if let captureError { showError(captureError) }
            }
        } catch { showError(error); showWindow() }
        openingProject = false
        if quitAfterSave { NSApp.terminate(nil) }
    }

    @objc private func openProject() {
        guard recorder.state == .idle, !openingProject, editor?.isExporting != true else { return }
        let panel = NSOpenPanel()
        panel.title = "打开录屏工程"; panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.directoryURL = settings.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadProject(url.hasDirectoryPath ? url : url.deletingLastPathComponent()) }
    }
    private func loadProject(_ folder: URL) async {
        guard recorder.state == .idle, !openingProject, editor?.isExporting != true else { return }
        openingProject = true
        defer { openingProject = false }
        guard prepareToLeaveEditor() else { return }
        do {
            let model = EditorModel()
            model.onError = { [weak self] error in self?.showError(error) }
            try await model.loadProject(folder: folder)
            editorWindow?.delegate = nil
            editorWindow?.close()
            editor = model
            editorWindow = EditorWindow(model: model,
                onBack: { [weak self] in self?.returnToRecorder() },
                onOpen: { [weak self] in self?.openProject() },
                onExport: { [weak self] in self?.exportVideo() })
            window.orderOut(nil); monitorGeneration += 1; await levels.stop()
            editorWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if !CommandLine.arguments.contains("--editor-ui-test"), !CommandLine.arguments.contains("--render-previews") {
                UserDefaults.standard.set(folder, forKey: "lastProject")
            }
        } catch { showError(error) }
    }
    private func returnToRecorder() {
        guard prepareToLeaveEditor() else { return }
        editor?.isPlaying = false; editorWindow?.orderOut(nil); showWindow()
    }
    private func prepareToLeaveEditor() -> Bool {
        guard let editor else { return true }
        editor.isPlaying = false
        do {
            try editor.autosave()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "工程无法保存"
            alert.informativeText = "\(error.localizedDescription)\n请恢复工程文件夹后重试，或放弃未保存的修改。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "放弃修改并继续")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            editor.onError = nil
            editorWindow?.delegate = nil
            editorWindow?.close()
            editorWindow = nil
            self.editor = nil
            return true
        }
    }
    @objc private func exportVideo() {
        guard let editor, !editor.isExporting else { return }
        editor.isPlaying = false
        let panel = NSSavePanel()
        panel.title = "导出视频"; panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = (editor.projectURL?.lastPathComponent ?? "录屏") + ".mov"
        panel.directoryURL = editor.projectURL?.deletingLastPathComponent()
        guard let window = editorWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    try editor.autosave()
                    self.presentExportProgress(editor)
                    try await editor.export(to: destination)
                    self.dismissExportProgress()
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    self.dismissExportProgress()
                    if !(error is CancellationError) { self.showError(error) }
                }
                if self.quitAfterExport { NSApp.terminate(nil) }
            }
        }
    }
    private func presentExportProgress(_ model: EditorModel) {
        guard let window = editorWindow else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 135),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "导出视频"; panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: ExportProgressView(model: model))
        exportPanel = panel; window.beginSheet(panel)
    }
    private func dismissExportProgress() {
        if let panel = exportPanel { editorWindow?.endSheet(panel); panel.orderOut(nil) }
        exportPanel = nil
    }
    @objc private func undoEdit() { editor?.undo() }
    @objc private func splitEdit() { _ = editor?.split() }
    @objc private func deleteEdit() { editorWindow?.deleteSelection() }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let automated = CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--render-previews") || CommandLine.arguments.contains("--editor-ui-test")
        if recorder.state == .idle, !automated { restartLevels() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window?.isVisible == true, recorder.state == .idle, !selecting,
              integrationDirectory == nil, !CommandLine.arguments.contains("--editor-ui-test"),
              !CommandLine.arguments.contains("--render-previews") else { return }
        refreshMicrophones()
        Task { await refreshSources() }
    }
    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Auto Recorder",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .credits: NSAttributedString(string: "GPL-3.0-only · 可修改和再分发 · 不提供担保\nhttps://github.com/Endless1936/auto-recorder")
        ])
    }
    private func showError(_ error: Error) {
        if integrationDirectory != nil { integrationReport("FAILED: \(error.localizedDescription)"); return }
        NSAlert(error: error).runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }; return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let path = filenames.first else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
        Task { await loadProject(isDirectory.boolValue ? url : url.deletingLastPathComponent()) }
        sender.reply(toOpenOrPrint: .success)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === editorWindow {
            editor?.isPlaying = false
            do { try editor?.autosave() } catch { showError(error) }
        }
        if let closing = notification.object as? NSWindow, closing === window {
            monitorGeneration += 1; Task { await levels.stop() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if selecting { selector.cancel(); return .terminateCancel }
        if recorder.state == .recording || recorder.state == .paused {
            let alert = NSAlert(); alert.messageText = "保存当前录制并退出？"
            alert.addButton(withTitle: "保存并退出"); alert.addButton(withTitle: "继续录制")
            if alert.runModal() == .alertFirstButtonReturn { quitAfterSave = true; stopRecording() }
            return .terminateCancel
        }
        if recorder.state != .idle || openingProject { return .terminateCancel }
        if editor?.isExporting == true {
            let alert = NSAlert(); alert.messageText = "取消导出并退出？"
            alert.addButton(withTitle: "取消导出并退出"); alert.addButton(withTitle: "继续导出")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            quitAfterExport = true
            editor?.cancelExport()
            return .terminateCancel
        }
        guard prepareToLeaveEditor() else { return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate(); shortcuts = nil
    }

    private func integrationTest() async {
        guard let directory = integrationDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard CGPreflightScreenCaptureAccess() else { integrationReport("BLOCKED: screen capture authorization"); return }
            monitorGeneration += 1
            await levels.stop()
            activeFolder = directory; activeFPS = 60; activeQuality = .hevc
            let arguments = CommandLine.arguments
            activeAutoZoom = arguments.contains("--auto-zoom")
            let region = arguments.contains("--test-region") ? CGRect(x: 100, y: 100, width: 640, height: 360) : nil
            var targetWindow: CGWindowID?
            if arguments.contains("--test-window") {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let available = content.windows.filter {
                    $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                    $0.windowLayer == 0 && $0.frame.width >= 640 && $0.frame.height >= 360 &&
                    $0.owningApplication != nil && $0.title?.isEmpty == false
                }
                let preferred = ["com.microsoft.edgemac", "com.apple.TextEdit", "com.openai.codex", "com.apple.finder"]
                let requestedID = arguments.firstIndex(of: "--test-window-id").flatMap { index in
                    arguments.indices.contains(index + 1) ? UInt32(arguments[index + 1]) : nil
                }
                let selected = requestedID.map { id in available.first { $0.windowID == id } }
                    ?? preferred.lazy.compactMap { bundle in available.first { $0.owningApplication?.bundleIdentifier == bundle } }.first
                    ?? available.first
                targetWindow = selected?.windowID
                if let selected {
                    try? "\(selected.windowID) \(selected.owningApplication?.applicationName ?? "") \(selected.title ?? "") \(selected.frame)".write(to: directory.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
                }
                guard targetWindow != nil else { throw RecorderError.message("没有可测试的窗口。") }
            }
            await recorder.start(displayID: CGMainDisplayID(), url: directory.appendingPathComponent("原片.mov"),
                fps: 60, quality: .hevc, region: region,
                audioOptions: CaptureAudioOptions(systemAudio: !arguments.contains("--no-system-audio"), microphone: arguments.contains("--with-microphone")),
                autoZoom: arguments.contains("--auto-zoom"), windowID: targetWindow)
            guard recorder.state == .recording else { return }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if arguments.contains("--test-pause") {
                recorder.pause()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                recorder.resume()
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await recorder.stop()
        } catch { integrationReport("FAILED: \(error.localizedDescription)") }
    }
    private func integrationReport(_ text: String) {
        guard let directory = integrationDirectory else { return }
        try? text.write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

private struct ExportProgressView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: model.exportProgress).tint(AppTheme.accent)
            HStack {
                Text("\(Int(model.exportProgress * 100))%").monospacedDigit()
                Spacer()
                Button("取消") { model.cancelExport() }
            }
        }.padding(24).foregroundStyle(AppTheme.ink).background(AppTheme.background)
    }
}
