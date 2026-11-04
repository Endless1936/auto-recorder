import AppKit
import ScreenCaptureKit
import AVFoundation

final class CaptureDelegate: NSObject, SCStreamDelegate {
    var onStop: ((Error) -> Void)?
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

@MainActor
final class Recorder {
    enum State { case idle, starting, recording, paused, saving, processing }
    private(set) var state: State = .idle
    private(set) var outputURL: URL?
    private(set) var startedAt: Date?
    private(set) var pixelSize = ""
    var onChange: (() -> Void)?
    var onFinished: ((URL, RecordingStats, Error?) -> Void)?
    var onError: ((Error) -> Void)?
    var onLevels: ((Double, Double) -> Void)?
    var onPrepareWindow: (() -> Void)?
    private(set) var lastTrace: CursorTrace?
    private(set) var actualDuration: Double = 0
    private(set) var lastCaptureDiagnosticSummary = ""
    var elapsedDuration: Double { sink?.actualDuration ?? actualDuration }
    private var stream: SCStream?
    private var sink: RecordingWriter?
    private var captureDelegate: CaptureDelegate?
    private var pendingCaptureError: Error?
    private var cursorCapture: CursorCapture?
    private let regionOverlay = RecordingRegionOverlay()
    private var windowMonitor: Timer?
    private(set) var processingProgress = 0.0

    var stats: RecordingStats { sink?.snapshot() ?? RecordingStats() }

    func start(displayID: CGDirectDisplayID, url: URL, fps: Int32, quality: RecordingQuality, region: CGRect? = nil, audioOptions: CaptureAudioOptions = .init(), autoZoom: Bool = false, windowID: CGWindowID? = nil, microphoneID: String? = nil) async {
        guard state == .idle else { return }
        regionOverlay.hide()
        pendingCaptureError = nil
        lastTrace = nil
        actualDuration = 0
        lastCaptureDiagnosticSummary = ""
        processingProgress = 0
        state = .starting
        onChange?()
        var newSink: RecordingWriter?
        var newStream: SCStream?
        do {
            if audioOptions.microphone {
                let microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
                guard microphoneID.map({ id in microphones.contains { $0.uniqueID == id } }) ?? (AVCaptureDevice.default(for: .audio) != nil) else {
                    throw RecorderError.message("未找到可用的麦克风，请连接输入设备后重试。")
                }
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
                default: allowed = false
                }
                guard allowed else {
                    throw RecorderError.message("麦克风访问未获允许。请在系统设置 → 隐私与安全性 → 麦克风中允许Auto Recorder，或关闭麦克风后录制。")
                }
            }
            // Request explicitly before querying content. A pending system dialog must
            // not be covered by our own modal error alert.
            if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
                throw RecorderError.screenAuthorization
            }
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let windowID {
                onPrepareWindow?()
                content = try await Self.prepareWindow(windowID, content: content)
            }
            // Application rules also cover guide windows created after capture starts.
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter: SCContentFilter
            let selectedWindow: SCWindow?
            if let windowID {
                guard let window = content.windows.first(where: { $0.windowID == windowID }), window.isOnScreen else {
                    throw RecorderError.message("所选窗口已关闭或最小化，请重新选择窗口。")
                }
                guard window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else {
                    throw RecorderError.message("请选择Auto Recorder以外的应用窗口。")
                }
                selectedWindow = window
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else {
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw RecorderError.message("所选屏幕已断开，请重新选择录制来源。")
                }
                guard !ownApplications.isEmpty else {
                    throw RecorderError.message("无法识别本程序的录制窗口，请重新打开Auto Recorder后重试。")
                }
                selectedWindow = nil
                filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            }
            // ScreenCaptureKit describes content in points. Retina scaling must be explicit.
            let area = try CaptureGeometry.area(region: windowID == nil ? region : nil, displaySize: filter.contentRect.size,
                                                 scale: CGFloat(filter.pointPixelScale))
            let width = area.pixelWidth
            let height = area.pixelHeight
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            // Independent-window capture uses the complete window bounds. Leave its
            // source rectangle unset; only display/region capture specifies a crop.
            if windowID == nil { config.sourceRect = area.sourceRect }
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            config.queueDepth = 6
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.itur_709
            config.captureDynamicRange = .SDR
            config.showsCursor = true
            config.capturesAudio = audioOptions.systemAudio
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = audioOptions.microphone
            config.microphoneCaptureDeviceID = microphoneID
            let temporaryURL = url.deletingLastPathComponent()
                .appendingPathComponent("录制中-\(UUID().uuidString).mov")
            let sink = try RecordingWriter(url: temporaryURL, width: width, height: height, fps: fps, quality: quality, audioOptions: audioOptions)
            newSink = sink
            let delegate = CaptureDelegate()
            delegate.onStop = { [weak self] error in
                Task { @MainActor in await self?.stop(captureError: error) }
            }
            sink.onFailure = { [weak self] error in
                Task { @MainActor in await self?.stop(captureError: error) }
            }
            sink.onLevels = { [weak self] system, microphone in
                Task { @MainActor in self?.onLevels?(system, microphone) }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
            newStream = stream
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if audioOptions.systemAudio {
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            }
            if audioOptions.microphone {
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            }
            self.sink = sink
            self.stream = stream
            captureDelegate = delegate
            outputURL = url
            pixelSize = "\(width) × \(height) · \(fps) fps"
            // Preserve the trace for later editing regardless of the default zoom choice.
            // `autoZoom` is retained for call-site compatibility; it never exports here.
            _ = autoZoom
            let tracker = CursorCapture()
            let displayBounds = CGDisplayBounds(displayID)
            let cursorBounds = selectedWindow?.frame ?? area.sourceRect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
            tracker.start(bounds: cursorBounds, boundsProvider: windowID.map { id in
                { Self.windowInfo(id)?.bounds }
            }, timeMapper: { [weak sink] time in sink?.adjustedTime(for: time) })
            cursorCapture = tracker
            try await stream.startCapture()
            if let error = pendingCaptureError ?? sink.currentFailure { throw error }
            if windowID == nil, region != nil, let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }) {
                regionOverlay.show(screen: screen, region: area.sourceRect)
            }
            state = .recording
            startedAt = Date()
            if let windowID { monitorWindow(windowID) }
            onChange?()
        } catch {
            regionOverlay.hide()
            windowMonitor?.invalidate(); windowMonitor = nil
            cursorCapture?.cancel(); cursorCapture = nil
            try? await newStream?.stopCapture()
            await newSink?.cancel()
            lastCaptureDiagnosticSummary = newSink?.captureDiagnosticSummary ?? ""
            self.stream = nil
            self.sink = nil
            captureDelegate = nil
            state = .idle
            startedAt = nil
            onLevels?(0, 0)
            onChange?()
            onError?(error)
        }
    }

    func pause() {
        guard state == .recording else { return }
        sink?.pause()
        cursorCapture?.pause()
        state = .paused
        onLevels?(0, 0)
        onChange?()
    }

    func resume() {
        guard state == .paused else { return }
        sink?.resume()
        cursorCapture?.resume()
        state = .recording
        onChange?()
    }

    func stop(captureError: Error? = nil) async {
        if state == .starting, let captureError {
            pendingCaptureError = captureError
            return
        }
        guard state == .recording || state == .paused else { return }
        // Freeze the media clock at the stop action, including a static final frame.
        sink?.pause()
        cursorCapture?.pause()
        windowMonitor?.invalidate(); windowMonitor = nil
        regionOverlay.hide()
        state = .saving
        onChange?()
        var stopError = captureError
        do { try await stream?.stopCapture() }
        catch { if stopError == nil { stopError = error } }
        let trace = cursorCapture?.finish(origin: sink?.firstVideoTime ?? .invalid)
        cursorCapture = nil
        do {
            guard let sink, let outputURL else { throw RecorderError.message("录制状态丢失。") }
            let result = try await sink.finish()
            lastCaptureDiagnosticSummary = sink.captureDiagnosticSummary
            actualDuration = sink.actualDuration
            lastTrace = trace.map { CursorTrace(samples: $0.samples.filter { $0.time <= actualDuration }) }
            try Self.install(sink.url, at: outputURL)
            state = .idle
            onFinished?(outputURL, result, stopError)
        } catch {
            state = .idle
            onError?(error)
        }
        lastCaptureDiagnosticSummary = sink?.captureDiagnosticSummary ?? lastCaptureDiagnosticSummary
        stream = nil
        sink = nil
        captureDelegate = nil
        startedAt = nil
        onLevels?(0, 0)
        onChange?()
    }

    func skipAutoZoom() { }

    /// Resolve the same window again after activation; collapsed Stage Manager
    /// content must not determine the encoder size or the first recorded frames.
    private static func prepareWindow(_ id: CGWindowID, content: SCShareableContent) async throws -> SCShareableContent {
        guard let original = content.windows.first(where: { $0.windowID == id }),
              let owner = original.owningApplication,
              owner.processID != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: owner.processID) else {
            throw RecorderError.message("所选窗口已关闭或不可用，请重新选择。")
        }
        application.unhide()
        NSApp.yieldActivation(to: application)
        guard application.activate(options: []) else {
            throw RecorderError.message("无法调出所选窗口，请先将它切到前台再录制。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var stableSince = ProcessInfo.processInfo.systemUptime
        var previousFrame: CGRect?
        var previousSize: CGSize?
        var previousScale: Float?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !application.isTerminated, let window = fresh.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.message("所选窗口已关闭，请重新选择。")
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.processID
            let frontWindow = frontWindowID(for: owner.processID)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filter.contentRect.size
            if frontmost, frontWindow == id, window.isOnScreen, size.width > 0, size.height > 0 {
                if previousFrame == window.frame, previousSize == size, previousScale == filter.pointPixelScale {
                    if ProcessInfo.processInfo.systemUptime - stableSince >= 0.35 { return fresh }
                } else { stableSince = ProcessInfo.processInfo.systemUptime }
                previousFrame = window.frame; previousSize = size; previousScale = filter.pointPixelScale
            } else {
                previousFrame = nil; previousSize = nil; previousScale = nil
                stableSince = ProcessInfo.processInfo.systemUptime
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw RecorderError.message("请先将选定窗口切到前台并展开，再开始录制。")
    }

    private static func frontWindowID(for processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.01
        }).flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    private static func windowInfo(_ id: CGWindowID) -> (bounds: CGRect, onScreen: Bool)? {
        guard let items = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let item = items.first, let raw = item[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
        return (bounds, item[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    private func monitorWindow(_ id: CGWindowID) {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording || self.state == .paused else { return }
                let info = Self.windowInfo(id)
                guard let info, info.onScreen, info.bounds.width > 0, info.bounds.height > 0 else {
                    let reason = info == nil ? "录制窗口已关闭，现有录制已保存。" : "录制窗口已最小化或隐藏，现有录制已保存。"
                    Task { @MainActor in await self.stop(captureError: RecorderError.message(reason)) }
                    return
                }
            }
        }
        windowMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func install(_ temporary: URL, at destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch {
            throw RecorderError.message("视频已编码完成，但无法移到目标位置。文件保存在：\(temporary.path)\n\(error.localizedDescription)")
        }
    }
}
