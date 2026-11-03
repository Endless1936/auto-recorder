import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreAudio
import AudioToolbox

/// Queue-confined meter. Values are measured linear RMS, never synthesized motion.
final class AudioLevelMeter {
    private var readings: [CaptureAudioSource: (Double, Double)] = [:]

    func update(sample: CMSampleBuffer, source: CaptureAudioSource) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count <= 192_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
            into: buffer.mutableAudioBufferList) == noErr else { return }
        update(level: Self.rms(buffer), source: source)
    }

    func update(level: Double, source: CaptureAudioSource) {
        readings[source] = (max(0, min(1, level.isFinite ? level : 0)), ProcessInfo.processInfo.systemUptime)
    }

    func values() -> (Double, Double) {
        let now = ProcessInfo.processInfo.systemUptime
        func value(_ source: CaptureAudioSource) -> Double {
            guard let reading = readings[source], now - reading.1 < 0.25 else { return 0 }
            return reading.0
        }
        return (value(.system), value(.microphone))
    }

    func reset() { readings.removeAll() }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        var square = 0.0
        var count = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            func accumulate<T>(_ type: T.Type, scale: Double, convert: (T) -> Double) {
                let length = Int(audioBuffer.mDataByteSize) / MemoryLayout<T>.stride
                let values = data.assumingMemoryBound(to: T.self)
                for index in 0..<length {
                    let sample = convert(values[index]) / scale
                    if sample.isFinite { square += sample * sample; count += 1 }
                }
            }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: accumulate(Float.self, scale: 1) { Double($0) }
            case .pcmFormatFloat64: accumulate(Double.self, scale: 1) { $0 }
            case .pcmFormatInt16: accumulate(Int16.self, scale: 32_768) { Double($0) }
            case .pcmFormatInt32: accumulate(Int32.self, scale: 2_147_483_648) { Double($0) }
            default: break
            }
        }
        return count > 0 ? min(1, sqrt(square / Double(count))) : 0
    }
}

private final class AudioLevelSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.recorder.level-preview", qos: .utility)
    private let meter = AudioLevelMeter()
    private var timer: DispatchSourceTimer?
    private var callback: (@MainActor (Double, Double) -> Void)?

    init(callback: @escaping @MainActor (Double, Double) -> Void) {
        self.callback = callback
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, let callback = self.callback else { return }
            let levels = self.meter.values()
            Task { @MainActor in callback(levels.0, levels.1) }
        }
        self.timer = timer
        timer.resume()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, type == .audio else { return }
        meter.update(sample: sampleBuffer, source: .system)
    }

    func microphone(_ buffer: AVAudioPCMBuffer) {
        let level = AudioLevelMeter.rms(buffer)
        queue.async { [weak self] in self?.meter.update(level: level, source: .microphone) }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            meter.reset()
            callback = nil
        }
    }

    deinit { timer?.cancel() }
}

/// Hardware calls can block inside CoreAudio. Never wait for this queue on the UI actor.
final class AudioMicrophoneWorker: @unchecked Sendable {
    enum InitializationEvent { case preparing, cancelled, initializing }

    private final class State {
        var engine: AVAudioEngine?
        var input: AVAudioInputNode?

        func stop() {
            input?.removeTap(onBus: 0)
            engine?.stop()
            input = nil; engine = nil
        }
    }

    private let queue = DispatchQueue(label: "local.recorder.microphone-preview", qos: .utility)
    private let state = State()
    private let lock = NSLock()
    private var generation = 0
    private let initializationEvent: (@Sendable (InitializationEvent) -> Void)?

    // The optional observer lets the regression test suspend a hardware request before it starts.
    init(initializationEvent: (@Sendable (InitializationEvent) -> Void)? = nil) {
        self.initializationEvent = initializationEvent
    }

    func start(id: String?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let token = advanceGeneration()
        queue.async { [self] in
            state.stop()
            guard isCurrent(token) else { return }
            initializationEvent?(.preparing)
            guard isCurrent(token) else {
                initializationEvent?(.cancelled)
                return
            }
            initializationEvent?(.initializing)
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            guard isCurrent(token),
                  id.map({ selected in devices.contains { $0.uniqueID == selected } }) ?? (AVCaptureDevice.default(for: .audio) != nil) else { return }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            guard isCurrent(token) else { return }
            if let id {
                guard let device = Self.audioDevice(uid: id), let unit = input.audioUnit,
                      isCurrent(token) else { return }
                var deviceID = device
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                    0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return }
            }
            let format = input.outputFormat(forBus: 0)
            guard isCurrent(token), format.channelCount > 0, format.sampleRate > 0 else { return }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard self?.isCurrent(token) == true else { return }
                onBuffer(buffer)
            }
            state.engine = engine; state.input = input
            guard isCurrent(token) else { state.stop(); return }
            do {
                try engine.start()
                if !isCurrent(token) { state.stop() }
            } catch { state.stop() }
        }
    }

    func stop() {
        _ = advanceGeneration()
        queue.async { [state] in state.stop() }
    }

    private func advanceGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    private static func audioDevice(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &property, 0, nil, &valueSize, &value) == noErr,
               let value, value.takeRetainedValue() as String == uid { return device }
        }
        return nil
    }

    deinit {
        let state = state
        queue.async { state.stop() }
    }
}

/// An audio-only preview: no movie, video output, files or network requests.
/// Preview never prompts for permissions; recording owns the authorization flow.
@MainActor
final class AudioLevelMonitor {
    private var stream: SCStream?
    private let microphoneWorker: AudioMicrophoneWorker
    private var sink: AudioLevelSink?
    private var callback: (@MainActor (Double, Double) -> Void)?
    private var generation = 0

    init(microphoneWorker: AudioMicrophoneWorker = AudioMicrophoneWorker()) {
        self.microphoneWorker = microphoneWorker
    }

    func start(system: Bool, microphone: Bool, microphoneID: String?,
               onLevels: @escaping @MainActor (Double, Double) -> Void) async {
        generation += 1
        let token = generation
        await releaseResources()
        guard token == generation else { return }
        callback = onLevels
        let sink = AudioLevelSink { [weak self] system, microphone in
            guard let self, self.generation == token else { return }
            onLevels(system, microphone)
        }
        self.sink = sink
        if microphone {
            microphoneWorker.start(id: microphoneID) { [weak sink] buffer in sink?.microphone(buffer) }
        }
        guard system, CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard token == generation, let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 60)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.showsCursor = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            self.stream = stream
            try await stream.startCapture()
            if token != generation { try? await stream.stopCapture() }
        } catch {
            // A denied or unavailable system source must not disable a permitted mic.
            if token == generation {
                let failed = stream
                stream = nil
                try? await failed?.stopCapture()
            }
        }
    }

    func stop() async {
        generation += 1
        await releaseResources()
    }

    private func releaseResources() async {
        let oldStream = stream
        let oldSink = sink
        let oldCallback = callback
        stream = nil; sink = nil; callback = nil
        microphoneWorker.stop()
        oldSink?.stop()
        oldCallback?(0, 0)
        try? await oldStream?.stopCapture()
    }
}
