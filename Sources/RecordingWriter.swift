import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum RecordingQuality: Int, CaseIterable {
    case hevc, proRes
    var title: String { self == .hevc ? "HEVC · 高画质，较小文件" : "ProRes 422 · 更高保真，大文件" }
    var codec: AVVideoCodecType { self == .hevc ? .hevc : .proRes422 }
}

struct RecordingStats {
    var videoFrames = 0
    var audioBuffers = 0
    var droppedFrames = 0
    var droppedAudio = 0
    var microphoneBuffers = 0
}

enum RecorderError: LocalizedError {
    case message(String)
    case screenAuthorization
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .screenAuthorization: return "屏幕录制授权尚未获系统确认。请先完成系统授权提示；已在设置中允许时，请完全退出并重新打开Auto Recorder。"
        }
    }

    static func isScreenAuthorization(_ error: Error) -> Bool {
        if case .screenAuthorization? = error as? RecorderError { return true }
        var current = error as NSError
        for _ in 0..<4 {
            if current.domain == SCStreamErrorDomain && current.code == SCStreamError.Code.userDeclined.rawValue { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return false
    }
}

/// Capture timestamps and host time share CoreMedia's host clock. Keep every pause
/// interval so callbacks delivered after resume cannot reintroduce paused media.
struct RecordingTimeline {
    private(set) var intervals: [(start: CMTime, end: CMTime)] = []
    private(set) var pauseStart: CMTime?
    var isPaused: Bool { pauseStart != nil }

    mutating func pause(at time: CMTime) {
        guard pauseStart == nil, time.isNumeric else { return }
        pauseStart = time
    }

    mutating func resume(at time: CMTime) {
        guard let start = pauseStart, CMTimeCompare(time, start) >= 0 else { return }
        intervals.append((start, time))
        pauseStart = nil
    }

    func activeTime(at time: CMTime) -> CMTime {
        var result = time
        for interval in intervals where CMTimeCompare(time, interval.start) > 0 {
            result = CMTimeSubtract(result, CMTimeSubtract(CMTimeMinimum(time, interval.end), interval.start))
        }
        if let start = pauseStart, CMTimeCompare(time, start) > 0 {
            result = CMTimeSubtract(result, CMTimeSubtract(time, start))
        }
        return result
    }

    func mediaTime(for time: CMTime) -> CMTime? {
        guard time.isNumeric else { return nil }
        if let start = pauseStart, CMTimeCompare(time, start) >= 0 { return nil }
        guard !intervals.contains(where: { CMTimeCompare(time, $0.start) >= 0 && CMTimeCompare(time, $0.end) < 0 }) else { return nil }
        return activeTime(at: time)
    }

    func activeRanges(from start: CMTime, to end: CMTime) -> [(CMTime, CMTime)] {
        var cursor = start
        var result: [(CMTime, CMTime)] = []
        let pauses = intervals + (pauseStart.map { [($0, end)] } ?? [])
        for pause in pauses {
            if CMTimeCompare(pause.1, cursor) <= 0 { continue }
            if CMTimeCompare(pause.0, end) >= 0 { break }
            if CMTimeCompare(pause.0, cursor) > 0 { result.append((cursor, CMTimeMinimum(pause.0, end))) }
            cursor = CMTimeMaximum(cursor, pause.1)
            if CMTimeCompare(cursor, end) >= 0 { break }
        }
        if CMTimeCompare(cursor, end) < 0 { result.append((cursor, end)) }
        return result
    }
}

/// All mutable encoder state is confined to `queue` after construction.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.recorder.encoding", qos: .userInitiated)
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var mixer: AudioMixer?
    private let audioOptions: CaptureAudioOptions
    private var pendingAudio: [CMSampleBuffer] = []
    private var audioEnd = CMTime.invalid
    private let fps: Int32
    private var started = false
    private var finishing = false
    private var firstPTS = CMTime.invalid
    private var lastVideo: CMSampleBuffer?
    private var lastVideoHost = CMTime.zero
    private var stats = RecordingStats()
    private var failure: Error?
    private var timeline = RecordingTimeline()
    private let clock: () -> CMTime
    private var finalDuration: Double?
    private let levels = AudioLevelMeter()
    private var levelTimer: DispatchSourceTimer?
    private var screenCallbacks = 0
    private var invalidScreenCallbacks = 0
    private var missingFrameAttachments = 0
    private var missingFrameStatus = 0
    private var screenImages = 0
    private var frameStatuses: [Int: Int] = [:]
    private let logCaptureDiagnostics = ProcessInfo.processInfo.environment["LOCAL_RECORDER_CAPTURE_DIAGNOSTICS"] == "1"
    var onFailure: ((Error) -> Void)?
    var onLevels: ((Double, Double) -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int32, quality: RecordingQuality, audioOptions: CaptureAudioOptions = .init(), clock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) throws {
        self.url = url
        self.fps = fps
        self.audioOptions = audioOptions
        self.clock = clock
        mixer = audioOptions.enabled ? AudioMixer(options: audioOptions) : nil
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        if quality == .hevc {
            // Keep native pixel dimensions; ~50 Mbps for 4K60, scaling with resolution.
            let bitrate = max(20_000_000, Int(Double(width) * Double(height) * Double(fps) * 0.10))
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.message("当前设备不支持所选分辨率和编码，请尝试其他画质。")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audioSettings: [String: Any]
        if quality == .proRes {
            audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                             AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                             AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                             AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        } else {
            audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                             AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                             AVEncoderBitRateKey: 256_000]
        }
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.message("无法创建视频轨道。") }
        writer.add(video)
        if audioOptions.enabled {
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw RecorderError.message("音频编码不可用。")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.message("无法创建音频轨道。") }
            writer.add(input)
            audio = input
        } else { audio = nil }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("无法写入所选文件。")
        }
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finishing else { return }
            let pair = self.timeline.isPaused ? (0.0, 0.0) : self.levels.values()
            self.onLevels?(pair.0, pair.1)
        }
        levelTimer = timer
        timer.resume()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            screenCallbacks += 1
            guard sampleBuffer.isValid else {
                invalidScreenCallbacks += 1
                logFrame("invalid sample")
                return
            }
            let hasImage = CMSampleBufferGetImageBuffer(sampleBuffer) != nil
            if hasImage { screenImages += 1 }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                    createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let attachment = attachments.first else {
                missingFrameAttachments += 1
                logFrame("missing frame attachments; image=\(hasImage)")
                return
            }
            guard let raw = attachment[.status] as? Int else {
                missingFrameStatus += 1
                logFrame("missing frame status; image=\(hasImage); keys=\(attachment.keys.map(\.rawValue).sorted())")
                return
            }
            frameStatuses[raw, default: 0] += 1
            if screenCallbacks <= 8 || frameStatuses[raw] == 1 {
                logFrame("status=\(Self.frameStatusName(raw)); image=\(hasImage); ready=\(CMSampleBufferDataIsReady(sampleBuffer)); pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
            }
            // A started frame may be the only image of a stationary window. Marker
            // buffers without images still fail appendVideo's image/PTS checks.
            guard SCFrameStatus(rawValue: raw) == .complete ||
                (SCFrameStatus(rawValue: raw) == .started && hasImage && CMSampleBufferDataIsReady(sampleBuffer)) else { return }
            appendVideo(sampleBuffer)
        case .audio:
            guard sampleBuffer.isValid else { return }
            appendAudio(sampleBuffer)
        case .microphone:
            guard sampleBuffer.isValid else { return }
            appendAudio(sampleBuffer, source: .microphone)
        @unknown default: break
        }
    }

    // Also used by the offline media checks, always on `queue`.
    func appendVideo(_ sample: CMSampleBuffer) {
        guard !finishing, failure == nil, !timeline.isPaused,
              CMSampleBufferGetImageBuffer(sample) != nil,
              let pts = timeline.mediaTime(for: CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        let adjusted: CMSampleBuffer
        do { adjusted = try Self.retime(sample, to: pts) }
        catch { recordFailure(error); return }
        if !started {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            audioEnd = pts
            started = true
        }
        if let lastVideo, CMTimeCompare(pts, CMSampleBufferGetPresentationTimeStamp(lastVideo)) <= 0 { return }
        guard video.isReadyForMoreMediaData else { stats.droppedFrames += 1; checkFailure(); return }
        if video.append(adjusted) {
            lastVideo = adjusted
            lastVideoHost = clock()
            stats.videoFrames += 1
        } else { recordFailure(writer.error ?? RecorderError.message("视频写入失败。")) }
    }

    func appendAudio(_ sample: CMSampleBuffer, source: CaptureAudioSource = .system) {
        guard !finishing, failure == nil, !timeline.isPaused else { return }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let rate = asbd.pointee.mSampleRate
        let count = CMSampleBufferGetNumSamples(sample)
        let end = CMTimeAdd(pts, CMTime(seconds: Double(count) / rate, preferredTimescale: 1_000_000_000))
        do {
            for range in timeline.activeRanges(from: pts, to: end) {
                let lower = CMTimeCompare(range.0, pts) == 0 ? 0 : max(0, Int(((range.0 - pts).seconds * rate - 0.000001).rounded(.up)))
                let upper = CMTimeCompare(range.1, end) == 0 ? count : min(count, Int(((range.1 - pts).seconds * rate + 0.000001).rounded(.down)))
                guard upper > lower else { continue }
                let clipped = try Self.audioSlice(sample, offset: lower, count: upper - lower)
                guard let mapped = timeline.mediaTime(for: CMSampleBufferGetPresentationTimeStamp(clipped)) else { continue }
                let adjusted = try Self.retime(clipped, to: mapped)
                levels.update(sample: clipped, source: source)
                guard started, let mixer else { continue }
                pendingAudio += try mixer.append(adjusted, source: source, origin: firstPTS)
                if source == .microphone { stats.microphoneBuffers += 1 }
            }
            drainAudio()
            // Four seconds is an encoding failure, not an unbounded memory backlog.
            if pendingAudio.count > 188 { recordFailure(RecorderError.message("音频编码跟不上录制，请检查磁盘空间后重试。")) }
        } catch { recordFailure(error) }
    }

    private func drainAudio() {
        guard let audio else { return }
        while !pendingAudio.isEmpty, audio.isReadyForMoreMediaData, failure == nil {
            let next = pendingAudio[0]
            let pts = CMSampleBufferGetPresentationTimeStamp(next)
            let gap = CMTimeConvertScale(CMTimeSubtract(pts, audioEnd), timescale: 48_000,
                                         method: .roundHalfAwayFromZero).value
            let sample: CMSampleBuffer
            if gap > 0 {
                // AAC ignores discontinuous input timestamps. Supply silence lazily so a
                // long silent interval preserves synchronization with bounded memory.
                let frames = min(gap, 48_000)
                do {
                    sample = try AudioMixer.sample([Float](repeating: 0, count: Int(frames) * 2), pts: audioEnd)
                } catch { recordFailure(error); break }
            } else {
                let next = pendingAudio.removeFirst()
                if gap < 0 {
                    let trim = min(CMSampleBufferGetNumSamples(next), Int(-gap))
                    if trim == CMSampleBufferGetNumSamples(next) { continue }
                    do { sample = try Self.audioSlice(next, offset: trim, count: CMSampleBufferGetNumSamples(next) - trim) }
                    catch { recordFailure(error); break }
                } else { sample = next }
            }
            if audio.append(sample) {
                stats.audioBuffers += 1
                audioEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample),
                                    CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: 48_000))
            } else { recordFailure(writer.error ?? RecorderError.message("音频写入失败。")) }
        }
        checkFailure()
    }

    private func checkFailure() {
        if writer.status == .failed { recordFailure(writer.error ?? RecorderError.message("编码失败。")) }
    }

    private func recordFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }

    func snapshot() -> RecordingStats { queue.sync { stats } }
    var firstVideoTime: CMTime { queue.sync { firstPTS } }
    var currentFailure: Error? { queue.sync { failure } }
    var actualDuration: Double { queue.sync { finalDuration ?? liveDuration(at: clock()) } }
    var captureDiagnosticSummary: String { queue.sync { diagnosticSummary() } }

    private static func frameStatusName(_ raw: Int) -> String {
        switch SCFrameStatus(rawValue: raw) {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        default: return "unknown(\(raw))"
        }
    }

    private func diagnosticSummary() -> String {
        let statuses = frameStatuses.keys.sorted().map { "\(Self.frameStatusName($0)):\(frameStatuses[$0]!)" }.joined(separator: ",")
        return "screen=\(screenCallbacks) invalid=\(invalidScreenCallbacks) image=\(screenImages) missingAttachments=\(missingFrameAttachments) missingStatus=\(missingFrameStatus) statuses=[\(statuses)] written=\(stats.videoFrames) dropped=\(stats.droppedFrames)"
    }

    private func logFrame(_ message: String) {
        if logCaptureDiagnostics { NSLog("[CaptureSample] %@", message) }
    }

    func adjustedTime(for time: CMTime) -> CMTime? { queue.sync { timeline.mediaTime(for: time) } }

    func pause(at time: CMTime? = nil) {
        queue.sync {
            guard !finishing, !timeline.isPaused else { return }
            let boundary = time ?? clock()
            let mapped = timeline.activeTime(at: boundary)
            timeline.pause(at: boundary)
            do {
                pendingAudio += try mixer?.finish(until: mapped) ?? []
                mixer = audioOptions.enabled ? AudioMixer(options: audioOptions) : nil
                drainAudio()
            } catch { recordFailure(error) }
            levels.reset()
            onLevels?(0, 0)
        }
    }

    func resume(at time: CMTime? = nil) {
        queue.sync {
            guard !finishing else { return }
            timeline.resume(at: time ?? clock())
        }
    }

    private func liveDuration(at time: CMTime) -> Double {
        guard started, let lastVideo else { return 0 }
        let elapsed = max(0, (timeline.activeTime(at: time) - timeline.activeTime(at: lastVideoHost)).seconds)
        return max(0, (CMSampleBufferGetPresentationTimeStamp(lastVideo) - firstPTS).seconds + max(1 / Double(fps), elapsed))
    }

    static func audioSlice(_ sample: CMSampleBuffer, offset: Int, count: Int) throws -> CMSampleBuffer {
        if offset == 0, count == CMSampleBufferGetNumSamples(sample) { return sample }
        // CoreMedia's range-copy API cannot slice non-interleaved capture audio.
        // Copy PCM frames explicitly, retaining the source rate/channel layout.
        guard offset >= 0, count > 0, offset + count <= CMSampleBufferGetNumSamples(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else { throw RecorderError.message("音频裁切范围无效。") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw RecorderError.message("音频裁切内存分配失败。") }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset), frameCount: Int32(count),
            into: buffer.mutableAudioBufferList) == noErr else { throw RecorderError.message("无法读取音频裁切范围。") }
        let channels = Int(format.channelCount)
        var values = [Float](repeating: 0, count: count * channels)
        for frame in 0..<count {
            for channel in 0..<channels {
                let plane = format.isInterleaved ? 0 : channel
                let index = format.isInterleaved ? frame * channels + channel : frame
                let value: Float
                switch format.commonFormat {
                case .pcmFormatFloat32: value = buffer.floatChannelData![plane][index]
                case .pcmFormatFloat64:
                    let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    value = Float(buffers[plane].mData!.assumingMemoryBound(to: Double.self)[index])
                case .pcmFormatInt16: value = Float(buffer.int16ChannelData![plane][index]) / 32_768
                case .pcmFormatInt32: value = Float(Double(buffer.int32ChannelData![plane][index]) / 2_147_483_648)
                default: throw RecorderError.message("音频裁切格式不受支持。")
                }
                values[frame * channels + channel] = value
            }
        }
        let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(seconds: Double(offset) / format.sampleRate, preferredTimescale: 1_000_000_000))
        return try AudioMixer.sample(values, pts: pts, sampleRate: format.sampleRate, channels: format.channelCount)
    }

    static func retime(_ sample: CMSampleBuffer, to pts: CMTime) throws -> CMSampleBuffer {
        let offset = CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(sample))
        if CMTimeCompare(offset, .zero) == 0 { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
            entriesNeededOut: &count) == noErr, count > 0 else { throw RecorderError.message("媒体时间戳无效。") }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing,
            entriesNeededOut: &count) == noErr else { throw RecorderError.message("媒体时间戳读取失败。") }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset) }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result) == noErr,
            let result else { throw RecorderError.message("媒体暂停时间对齐失败。") }
        return result
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishing = true
                self.logFrame(self.diagnosticSummary())
                self.levelTimer?.cancel(); self.levelTimer = nil
                self.onLevels?(0, 0)
                self.writer.cancelWriting(); continuation.resume()
            }
        }
    }

    /// After capture has stopped, drain callbacks then finish the movie atomically.
    func finish(extendToNow: Bool = true) async throws -> RecordingStats {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finishing else {
                    continuation.resume(throwing: RecorderError.message("文件正在保存。")); return
                }
                self.finishing = true
                self.logFrame(self.diagnosticSummary())
                self.levelTimer?.cancel(); self.levelTimer = nil
                self.onLevels?(0, 0)
                if let failure = self.failure {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: failure); return
                }
                guard self.started, let last = self.lastVideo else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: RecorderError.message("没有收到屏幕画面，请检查录屏权限后重试。")); return
                }
                var end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(last), CMTime(value: 1, timescale: self.fps))
                if extendToNow {
                    let now = self.clock()
                    let elapsed = CMTimeSubtract(self.timeline.activeTime(at: now), self.timeline.activeTime(at: self.lastVideoHost))
                    if elapsed.seconds > 1.0 / Double(self.fps) {
                        end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(last), elapsed)
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: self.fps),
                            presentationTimeStamp: CMTimeSubtract(end, CMTime(value: 1, timescale: self.fps)),
                            decodeTimeStamp: .invalid)
                        var tail: CMSampleBuffer?
                        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                            sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                            sampleBufferOut: &tail)
                        // endSession also preserves elapsed duration if the encoder is temporarily full.
                        if status == noErr, let tail, self.video.isReadyForMoreMediaData {
                            if !self.video.append(tail) {
                                self.writer.cancelWriting()
                                continuation.resume(throwing: self.writer.error ?? RecorderError.message("最后一帧保存失败。")); return
                            }
                        }
                    }
                }
                self.finalDuration = max(0, CMTimeSubtract(end, self.firstPTS).seconds)
                do { self.pendingAudio += try self.mixer?.finish(until: end) ?? [] }
                catch {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: error); return
                }
                self.video.markAsFinished()
                self.lastVideo = nil
                let complete = {
                    if let failure = self.failure {
                        self.writer.cancelWriting()
                        continuation.resume(throwing: failure); return
                    }
                    self.writer.endSession(atSourceTime: end)
                    self.audio?.markAsFinished()
                    let result = self.stats
                    self.writer.finishWriting {
                        if self.writer.status == .completed { continuation.resume(returning: result) }
                        else { continuation.resume(throwing: self.writer.error ?? RecorderError.message("文件保存未完成。")) }
                    }
                }
                self.drainAudio()
                if self.pendingAudio.isEmpty || self.failure != nil { complete() }
                else if let audio = self.audio {
                    // Preserve the buffered mix tail even when the encoder applies backpressure.
                    var completed = false
                    audio.requestMediaDataWhenReady(on: self.queue) {
                        guard !completed else { return }
                        self.drainAudio()
                        if self.pendingAudio.isEmpty || self.failure != nil {
                            completed = true
                            complete()
                        }
                    }
                }
            }
        }
    }
}
