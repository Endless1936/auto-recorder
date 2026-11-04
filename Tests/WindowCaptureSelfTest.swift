import AppKit
import AVFoundation
import ScreenCaptureKit

private struct WindowFixtureInfo: Codable {
    var processID: Int32
    var windowID: CGWindowID
}

private struct WindowFixtureCommand: Codable {
    var id: UUID
    var minimize = false
}

private struct WindowFixtureReply: Codable {
    var id: UUID
    var visible: Bool
    var minimized: Bool
    var tick: Int
}

@MainActor
private final class WindowFixtureView: NSView {
    var tick = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.16, alpha: 1).setFill()
        bounds.fill()
        NSColor.systemGreen.setFill()
        let x = CGFloat((tick * 9) % max(1, Int(bounds.width - 100)))
        NSBezierPath(roundedRect: NSRect(x: x, y: 110, width: 100, height: 100), xRadius: 12, yRadius: 12).fill()
        let text = "Auto Recorder · Window Capture Fixture\nFrame \(tick)"
        text.draw(at: NSPoint(x: 24, y: 28), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.white
        ])
    }
}

/// Retained by the app delegate in the --window-capture-fixture child instance.
/// It owns only a temporary local test window; no other applications are controlled.
@MainActor
final class WindowCaptureFixture {
    let window: NSWindow
    private var timer: Timer?
    private let directory: URL
    private var lastCommand: UUID?

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = WindowFixtureView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Auto Recorder Window Capture Fixture"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.displayIfNeeded()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let view else { return }
                self?.processCommand(tick: view.tick)
                view.tick += 1
                view.needsDisplay = true
                view.displayIfNeeded()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let info = WindowFixtureInfo(processID: ProcessInfo.processInfo.processIdentifier,
                                     windowID: CGWindowID(window.windowNumber))
        try JSONEncoder().encode(info).write(to: directory.appendingPathComponent("fixture.json"), options: .atomic)
    }

    private func processCommand(tick: Int) {
        let path = directory.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: path),
              let command = try? JSONDecoder().decode(WindowFixtureCommand.self, from: data),
              command.id != lastCommand else { return }
        lastCommand = command.id
        if command.minimize { window.miniaturize(nil) }
        else {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        window.displayIfNeeded()
        let reply = WindowFixtureReply(id: command.id, visible: window.isVisible,
                                       minimized: window.isMiniaturized, tick: tick)
        try? JSONEncoder().encode(reply).write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
    }

    deinit { timer?.invalidate() }
}

private final class WindowCaptureProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingWriter
    private var stoppedErrors: [String] = []
    init(writer: RecordingWriter) { self.writer = writer }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writer.stream(stream, didOutputSampleBuffer: sampleBuffer, of: type)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writer.queue.async { [weak self] in self?.stoppedErrors.append(String(describing: error)) }
    }
    var errors: [String] { writer.queue.sync { stoppedErrors } }
}

@MainActor
enum WindowCaptureSelfTest {
    private struct Result: Codable {
        var configuration: String
        var dimensions: String
        var captureSummary: String
        var errors: [String]
        var duration: Double
        var decodedFrames: Int
        var windowState = ""
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw RecorderError.message("窗口测试必须从已签名的 Auto Recorder.app运行，不能用独立未签名程序。")
        }
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.screenAuthorization }
        let fixtureDirectory = directory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-a", Bundle.main.bundleURL.path, "--args", "--window-capture-fixture", fixtureDirectory.path]
        try launcher.run()
        let info = try await waitForFixture(in: fixtureDirectory)
        defer { NSRunningApplication(processIdentifier: info.processID)?.terminate() }
        var results: [Result] = []
        for variant in ["apple-minimal", "production-no-shadow", "production-with-shadow"] {
            let window = try await prepareFixture(info, directory: fixtureDirectory)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let width = max(2, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()) / 2 * 2)
            let height = max(2, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()) / 2 * 2)
            print("WINDOW FIXTURE \(variant): pid=\(info.processID) id=\(info.windowID) onScreen=\(window.isOnScreen) frame=\(window.frame) filter=\(filter.contentRect) scale=\(filter.pointPixelScale)")
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            if variant != "apple-minimal" {
                configuration.captureResolution = .best
                configuration.queueDepth = 6
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.itur_709
                configuration.captureDynamicRange = .SDR
                configuration.showsCursor = true
                configuration.ignoreShadowsSingleWindow = variant == "production-no-shadow"
            }
            // In every variant sourceRect remains unset, matching Apple's sample.
            let output = directory.appendingPathComponent("\(variant)-\(UUID().uuidString).mov")
            let writer = try RecordingWriter(url: output, width: width, height: height, fps: 30,
                quality: .hevc, audioOptions: .init(systemAudio: false, microphone: false))
            let probe = WindowCaptureProbe(writer: writer)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: probe)
            try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: writer.queue)
            var result = Result(configuration: variant, dimensions: "\(width)x\(height)", captureSummary: "", errors: [], duration: 0, decodedFrames: 0)
            var finished = false
            do {
                try await stream.startCapture()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await stream.stopCapture()
                _ = try await writer.finish()
                finished = true
                result.duration = writer.actualDuration
                result.decodedFrames = try await decodeFrames(url: output)
            } catch {
                result.errors.append(String(describing: error))
                try? await stream.stopCapture()
                if !finished { await writer.cancel() }
            }
            result.captureSummary = writer.captureDiagnosticSummary
            result.windowState = fixtureState(info)
            result.errors += probe.errors
            results.append(result)
            print("WINDOW \(variant): \(result.captureSummary); decoded=\(result.decodedFrames); duration=\(result.duration); errors=\(result.errors)")
        }
        for systemAudio in [false, true] {
            let variant = systemAudio ? "recorder-system-audio" : "recorder-no-audio"
            let window = try await prepareFixture(info, directory: fixtureDirectory)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(midpoint) }) ?? content.displays.first else {
                throw RecorderError.message("窗口测试未找到屏幕。")
            }
            let output = directory.appendingPathComponent("\(variant)-\(UUID().uuidString).mov")
            let recorder = Recorder()
            var captureErrors: [String] = []
            var receivedOutput: URL?
            recorder.onError = { captureErrors.append(String(describing: $0)) }
            recorder.onFinished = { url, _, error in
                receivedOutput = url
                if let error { captureErrors.append(String(describing: error)) }
            }
            let cover = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 460),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.title = "Auto Recorder · Window Activation Test"
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            cover.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                cover.close()
                throw RecorderError.message("窗口前置测试未能先激活测试录制面板。")
            }
            await recorder.start(displayID: display.displayID, url: output, fps: 30, quality: .hevc,
                audioOptions: .init(systemAudio: systemAudio, microphone: false),
                autoZoom: false, windowID: info.windowID)
            if recorder.state == .recording,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != info.processID {
                captureErrors.append("开始录制前未将目标应用带到前台。")
            }
            cover.orderOut(nil); cover.close()
            if recorder.state == .recording { try await Task.sleep(nanoseconds: 2_000_000_000) }
            await recorder.stop()
            var result = Result(configuration: variant, dimensions: recorder.pixelSize,
                captureSummary: recorder.lastCaptureDiagnosticSummary, errors: captureErrors,
                duration: recorder.actualDuration, decodedFrames: 0)
            result.windowState = fixtureState(info)
            if let receivedOutput {
                do { result.decodedFrames = try await decodeFrames(url: receivedOutput) }
                catch { result.errors.append(String(describing: error)) }
            } else if result.errors.isEmpty { result.errors.append("Recorder未回调已保存原片。") }
            results.append(result)
            print("WINDOW \(variant): \(result.captureSummary); decoded=\(result.decodedFrames); duration=\(result.duration); errors=\(result.errors)")
        }
        // A minimized target must either be restored successfully or fail before
        // creating any media. Never accept a recording of its collapsed surface.
        _ = try await prepareFixture(info, directory: fixtureDirectory)
        let minimize = WindowFixtureCommand(id: UUID(), minimize: true)
        try JSONEncoder().encode(minimize).write(to: fixtureDirectory.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: fixtureDirectory.appendingPathComponent("reply.json")),
               let reply = try? JSONDecoder().decode(WindowFixtureReply.self, from: data),
               reply.id == minimize.id, reply.minimized { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let guarded = Recorder()
        let guardedURL = directory.appendingPathComponent("minimized-guard.mov")
        var guardErrors: [Error] = []
        guarded.onError = { guardErrors.append($0) }
        await guarded.start(displayID: CGMainDisplayID(), url: guardedURL, fps: 30, quality: .hevc,
                            audioOptions: .init(systemAudio: false, microphone: false), windowID: info.windowID)
        if guarded.state == .recording {
            try await Task.sleep(nanoseconds: 1_200_000_000)
            await guarded.stop()
            guard try await decodeFrames(url: guardedURL) > 5 else { throw RecorderError.message("恢复后的窗口没有有效视频。") }
        } else {
            guard guarded.state == .idle, !guardErrors.isEmpty, !FileManager.default.fileExists(atPath: guardedURL.path) else {
                throw RecorderError.message("未能展开的窗口仍生成了录制文件。")
            }
        }
        print("PASS window preparation: inactive target activated before capture; minimized target restored or refused before media creation")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: directory.appendingPathComponent("window-capture-results.json"), options: .atomic)
        guard results.allSatisfy({ $0.errors.isEmpty && $0.decodedFrames > 5 && $0.duration > 1 }) else {
            throw RecorderError.message("窗口视频测试未全通过，SCStream原始回调与写入诊断已保存到window-capture-results.json。")
        }
        print("PASS window capture: signed-app animated fixture, 3 direct stream configurations plus Recorder without/with system audio, real encoded video and changing image content fully decoded")
    }

    private static func prepareFixture(_ info: WindowFixtureInfo, directory: URL) async throws -> SCWindow {
        guard NSRunningApplication(processIdentifier: info.processID)?.isTerminated == false else {
            throw RecorderError.message("测试窗口子进程已退出，不能把结果归因于采集配置。")
        }
        let command = WindowFixtureCommand(id: UUID())
        try JSONEncoder().encode(command).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let replyURL = directory.appendingPathComponent("reply.json")
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: replyURL),
               let reply = try? JSONDecoder().decode(WindowFixtureReply.self, from: data),
               reply.id == command.id, reply.visible, !reply.minimized {
                // Let WindowServer commit the front/restore transaction before asking
                // for a new SCWindow snapshot for this specific capture session.
                try await Task.sleep(nanoseconds: 200_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let window = content.windows.first(where: {
                    $0.windowID == info.windowID && $0.owningApplication?.processID == info.processID && $0.isOnScreen
                }) { return window }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecorderError.message("测试窗口未确认恢复可见：\(fixtureState(info))")
    }

    private static func fixtureState(_ info: WindowFixtureInfo) -> String {
        let running = NSRunningApplication(processIdentifier: info.processID)?.isTerminated == false
        let items = CGWindowListCopyWindowInfo(.optionIncludingWindow, info.windowID) as? [[String: Any]]
        let item = items?.first
        let onScreen = item?[kCGWindowIsOnscreen as String] as? Bool ?? false
        return "running=\(running) exists=\(item != nil) onScreen=\(onScreen)"
    }

    private static func waitForFixture(in directory: URL) async throws -> WindowFixtureInfo {
        let ready = directory.appendingPathComponent("fixture.json")
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: ready), let info = try? JSONDecoder().decode(WindowFixtureInfo.self, from: data) { return info }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecorderError.message("已签名的窗口测试子进程未能启动。请检查--window-capture-fixture入口。")
    }

    private static func decodeFrames(url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.message("窗口视频解码无法启动。") }
        var frames = 0
        var signatures: Set<UInt64> = []
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(image) {
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
                    let row = CVPixelBufferGetBytesPerRow(image)
                    var hash: UInt64 = 14_695_981_039_346_656_037
                    for y in stride(from: 0, to: height, by: max(1, height / 24)) {
                        for x in stride(from: 0, to: width, by: max(1, width / 24)) {
                            let offset = y * row + x * 4
                            for channel in 0..<3 { hash = (hash ^ UInt64(bytes[offset + channel])) &* 1_099_511_628_211 }
                        }
                    }
                    signatures.insert(hash)
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? RecorderError.message("窗口视频未能完整解码。") }
        guard signatures.count > 1 else { throw RecorderError.message("窗口视频虽能解码，但没有捕获到fixture的动画变化。") }
        return frames
    }
}
