import Foundation
import AppKit
import AVFoundation

/// Uses a generated tone and the real output device. It captures meter values,
/// never screen pixels, microphone audio files, or other user content.
@MainActor
enum AudioMonitorSelfTest {
    static func run(directory: URL) async throws {
        try await blockedMicrophoneInitialization()
        guard CGPreflightScreenCaptureAccess() else {
            throw RecorderError.message("电平实测需要本程序已有屏幕与系统音频录制授权；测试不会弹出新的授权请求。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = directory.appendingPathComponent("audio-monitor-440hz.wav")
        try makeTone(at: fixture)
        let monitor = AudioLevelMonitor()
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playback.arguments = ["-v", "0.04", fixture.path]
        playback.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        playback.standardError = errors

        var phase = "warmup"
        var callbacks = 0
        var playbackCallbacks = 0
        var playbackPeak = 0.0
        var lastSystem = 0.0
        var lastMicrophone = 0.0
        var tailZeroCallbacks = 0
        var invalidReading = false

        do {
            await monitor.start(system: true, microphone: false, microphoneID: nil) { system, microphone in
                callbacks += 1
                lastSystem = system; lastMicrophone = microphone
                if !system.isFinite || !microphone.isFinite || system < 0 || system > 1 || microphone < 0 || microphone > 1 {
                    invalidReading = true
                }
                if phase == "playback" {
                    playbackCallbacks += 1
                    playbackPeak = max(playbackPeak, system)
                } else if phase == "tail" {
                    tailZeroCallbacks = system == 0 ? tailZeroCallbacks + 1 : 0
                }
            }
            try await wait(timeout: 2, description: "系统音频监测没有产生电平回调") { callbacks >= 3 }
            phase = "playback"
            try playback.run()
            try await wait(timeout: 5, description: "afplay 播放测试音超时") { !playback.isRunning }
            phase = "tail"
            let tailStarted = ProcessInfo.processInfo.systemUptime
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try check(playback.terminationStatus == 0,
                      "afplay 未正常完成：\(playback.terminationStatus) \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            try await wait(timeout: 3, description: "停止测试音后系统音频电平未稳定归零。") {
                ProcessInfo.processInfo.systemUptime - tailStarted >= 0.3 && tailZeroCallbacks >= 3
            }
            print(String(format: "INFO system audio: callbacks=%d playbackCallbacks=%d playbackPeakRMS=%.9f tailRMS=%.9f tailZeroCallbacks=%d",
                         callbacks, playbackCallbacks, playbackPeak, lastSystem, tailZeroCallbacks))
            try check(!invalidReading, "系统音频监测产生了非法 RMS 值。")
            try check(playbackCallbacks > 0 && playbackPeak > 0,
                      "实际 afplay 播放期间系统 RMS 始终为 0（已授权，afplay 正常退出，播放期回调 \(playbackCallbacks) 次）；未通过真实系统音频电平验证。")
            await monitor.stop()
            try check(lastSystem == 0 && lastMicrophone == 0, "停止监测没有清零电平。")
            print("PASS system audio meter: real external 440Hz playback produces nonzero RMS and silence decays to zero")

            var disabledCallbacks = 0
            var disabledNonzero = false
            await monitor.start(system: false, microphone: false, microphoneID: nil) { system, microphone in
                disabledCallbacks += 1
                if system != 0 || microphone != 0 { disabledNonzero = true }
            }
            try await wait(timeout: 2, description: "关闭两路音源后没有电平状态回调") { disabledCallbacks >= 3 }
            await monitor.stop()
            try check(!disabledNonzero, "两路音源均关闭后仍输出非零电平。")
            print("PASS disabled audio meter: both sources remain zero and stop releases monitoring")

            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                var microphoneCallbacks = 0
                var microphonePeak = 0.0
                var microphoneInvalid = false
                var microphoneLast = 0.0
                await monitor.start(system: false, microphone: true, microphoneID: nil) { system, microphone in
                    microphoneCallbacks += 1
                    microphonePeak = max(microphonePeak, microphone)
                    microphoneLast = microphone
                    if system != 0 || !microphone.isFinite || microphone < 0 || microphone > 1 { microphoneInvalid = true }
                }
                try await wait(timeout: 2, description: "已授权麦克风监测没有电平回调") { microphoneCallbacks >= 8 }
                await monitor.stop()
                try check(!microphoneInvalid && microphoneLast == 0, "麦克风电平非法或停止后未清零。")
                print(String(format: "INFO authorized microphone: callbacks=%d peakRMS=%.9f; quiet-room zero is allowed",
                             microphoneCallbacks, microphonePeak))
                print("PASS authorized microphone callbacks: finite RMS and stop resets zero; no new permission requested")
            } else {
                print("SKIP microphone: not already authorized; no permission request made")
            }
        } catch {
            print(String(format: "INFO audio meter failure: phase=%@ callbacks=%d playbackCallbacks=%d playbackPeakRMS=%.9f latestSystemRMS=%.9f latestMicRMS=%.9f",
                         phase, callbacks, playbackCallbacks, playbackPeak, lastSystem, lastMicrophone))
            if playback.isRunning { playback.terminate() }
            await monitor.stop()
            throw error
        }
    }

    private final class BlockedInitialization: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var events: [AudioMicrophoneWorker.InitializationEvent] = []

        func observe(_ event: AudioMicrophoneWorker.InitializationEvent) {
            lock.lock(); events.append(event); lock.unlock()
            if event == .preparing { gate.wait() }
        }

        func contains(_ event: AudioMicrophoneWorker.InitializationEvent) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return events.contains(event)
        }
    }

    private static func blockedMicrophoneInitialization() async throws {
        let blocked = BlockedInitialization()
        let worker = AudioMicrophoneWorker { event in blocked.observe(event) }
        let monitor = AudioLevelMonitor(microphoneWorker: worker)
        defer { worker.stop(); blocked.gate.signal() }
        var callbacks = 0
        var lastMicrophone = -1.0
        await monitor.start(system: false, microphone: true, microphoneID: nil) { _, microphone in
            callbacks += 1
            lastMicrophone = microphone
        }
        try await wait(timeout: 1, description: "麦克风阻塞回归未进入初始化 worker") { blocked.contains(.preparing) }

        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            Task { @MainActor in ticks += 1 }
        }
        defer { timer.invalidate() }
        try await wait(timeout: 0.5, description: "硬件初始化阻塞时主线程未能处理 tick") { ticks >= 2 }
        let stopStarted = ProcessInfo.processInfo.systemUptime
        await monitor.stop()
        let stopDuration = ProcessInfo.processInfo.systemUptime - stopStarted
        try check(stopDuration < 0.25 && lastMicrophone == 0,
                  "硬件初始化阻塞时 stop 未及时返回或未清零：\(stopDuration)s")
        let callbacksAfterStop = callbacks
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(callbacks == callbacksAfterStop, "stop 后仍有过期电平回调。")
        blocked.gate.signal()
        try await wait(timeout: 1, description: "硬件请求放开后未丢弃过期 generation") { blocked.contains(.cancelled) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!blocked.contains(.initializing) && callbacks == callbacksAfterStop,
                  "过期 generation 仍初始化硬件或泄露电平回调。")
        print(String(format: "PASS blocked microphone initialization: mainTicks=%d stop=%.4fs; cancelled before hardware, no stale callbacks",
                     ticks, stopDuration))
    }

    private static func makeTone(at url: URL) throws {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(rate * 1.2)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                        channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw RecorderError.message("无法分配测试音缓冲区。")
        }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let time = Double(index) / rate
            let envelope = min(1, min(time / 0.01, (1.2 - time) / 0.01))
            let value = Float(sin(2 * Double.pi * 440 * time) * 0.1 * max(0, envelope))
            channels[0][index] = value
            channels[1][index] = value
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func wait(timeout: Double, description: String,
                             until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RecorderError.message(description)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message(message) }
    }
}
