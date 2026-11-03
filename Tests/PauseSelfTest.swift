import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

enum PauseSelfTest {
    private static let width = 640, height = 360
    private final class Clock {
        var seconds = 100.0
        var time: CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkTimelineAndLevels()
        for quality in RecordingQuality.allCases {
            try await checkMedia(directory: directory, quality: quality)
        }
        try await checkCrossingAudio(directory: directory)
        try await checkStaticTail(directory: directory, resume: false)
        try await checkStaticTail(directory: directory, resume: true)
        let empty = try RecordingWriter(url: directory.appendingPathComponent("pause-empty-\(UUID().uuidString).mov"),
            width: width, height: height, fps: 30, quality: .hevc, audioOptions: .init(systemAudio: false))
        empty.pause(); empty.resume()
        do {
            _ = try await empty.finish()
            throw RecorderError.message("空录制错误地生成了成功文件。")
        } catch RecorderError.message(let message) where message.contains("没有收到") {
            print("PASS pause: zero-frame recording rejected")
        }
    }

    private static func checkTimelineAndLevels() throws {
        var timeline = RecordingTimeline()
        timeline.pause(at: CMTime(seconds: 101, preferredTimescale: 48_000))
        timeline.resume(at: CMTime(seconds: 102, preferredTimescale: 48_000))
        timeline.pause(at: CMTime(seconds: 103, preferredTimescale: 48_000))
        timeline.resume(at: CMTime(seconds: 105, preferredTimescale: 48_000))
        let input = [100.5, 101.5, 102.5, 104, 105.5]
        let mapped = input.compactMap { value -> CursorSample? in
            guard let time = timeline.mediaTime(for: CMTime(seconds: value, preferredTimescale: 48_000)) else { return nil }
            return CursorSample(time: time.seconds, x: 0.5, y: 0.5, inside: true, clicked: true)
        }
        let trace = CursorTrace.aligned(mapped, origin: 100)
        guard trace.samples.map(\.time) == [0.5, 1.5, 2.5] else {
            throw RecorderError.message("暂停后的鼠标轨迹未与媒体同钟。")
        }
        let meter = AudioLevelMeter()
        meter.update(sample: try AudioMixer.sample([Float](repeating: 0.25, count: 960), pts: .zero), source: .system)
        meter.update(sample: try AudioMixer.sample([Float](repeating: -0.5, count: 480), pts: .zero, sampleRate: 48_000, channels: 1), source: .microphone)
        let pair = meter.values()
        guard abs(pair.0 - 0.25) < 0.00001, abs(pair.1 - 0.5) < 0.00001 else {
            throw RecorderError.message("真实音量RMS或声源区分错误。")
        }
        meter.reset()
        guard meter.values() == (0, 0) else { throw RecorderError.message("暂停电平没有清零。") }
        print("PASS pause: shared media/cursor clock, repeated pauses, independent measured RMS")
    }

    private static func checkMedia(directory: URL, quality: RecordingQuality) async throws {
        let clock = Clock()
        let url = directory.appendingPathComponent("pause-\(quality.rawValue)-\(UUID().uuidString).mov")
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 30, quality: quality,
            audioOptions: .init(systemAudio: true, microphone: true), clock: { clock.time })
        for frame in 0..<90 {
            clock.seconds = 100 + Double(frame) / 30
            if frame == 30 { writer.pause(at: clock.time) }
            if frame == 60 {
                writer.resume(at: clock.time)
                // Capture callbacks may arrive late after the pause has ended.
                let stale = try video(at: CMTime(seconds: 101.5, preferredTimescale: 48_000))
                let staleAudio = try tone(at: 101.5, frequency: 1_700, frames: 1_600)
                writer.queue.sync { writer.appendVideo(stale); writer.appendAudio(staleAudio) }
            }
            let sample = try video(at: clock.time)
            let paused = (30..<60).contains(frame)
            let system = try tone(at: clock.seconds, frequency: paused ? 1_700 : (frame < 30 ? 440 : 880), frames: 1_600)
            let microphone = try tone(at: clock.seconds, frequency: paused ? 1_900 : (frame < 30 ? 220 : 660), frames: 1_470, rate: 44_100, channels: 1)
            writer.queue.sync {
                writer.appendVideo(sample)
                writer.appendAudio(system)
                writer.appendAudio(microphone, source: .microphone)
            }
            // Let the real encoder drain; timestamps remain deterministic.
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        clock.seconds = 103
        let stats = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard stats.videoFrames == 60, stats.droppedFrames == 0,
              abs(duration - 2) < 0.06, abs(writer.actualDuration - 2) < 0.002 else {
            throw RecorderError.message("暂停视频帧数/时长错误：\(stats.videoFrames)帧，\(duration)秒，实际\(writer.actualDuration)秒。")
        }
        let audio = try await decodedAudio(asset)
        guard audio.count >= 95_000,
              amplitude(audio, frequency: 440, start: 0.2, end: 0.8) > 0.10,
              amplitude(audio, frequency: 220, start: 0.2, end: 0.8) > 0.10,
              amplitude(audio, frequency: 880, start: 1.2, end: 1.8) > 0.10,
              amplitude(audio, frequency: 660, start: 1.2, end: 1.8) > 0.10,
              amplitude(audio, frequency: 1_700, start: 0.2, end: 1.8) < 0.015,
              amplitude(audio, frequency: 1_900, start: 0.2, end: 1.8) < 0.015 else {
            throw RecorderError.message("暂停音频未正确拼接、混音、去除暂停期间声音或保持音画同步。")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.message("暂停视频解码未启动。") }
        var decoded = 0
        var last = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts > last else { throw RecorderError.message("恢复后视频时间戳不递增。") }
            last = pts; decoded += 1
        }
        guard reader.status == .completed, decoded >= 60 else { throw reader.error ?? RecorderError.message("暂停视频未完整解码。") }
        print("PASS pause \(quality): 3s capture → 2s movie, 60 active frames, two resampled audio sources, paused/stale samples excluded, full decode")
    }

    private static func checkStaticTail(directory: URL, resume: Bool) async throws {
        let clock = Clock()
        let url = directory.appendingPathComponent("pause-static-\(resume)-\(UUID().uuidString).mov")
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 30, quality: .hevc,
            audioOptions: .init(systemAudio: false), clock: { clock.time })
        let sample = try video(at: clock.time)
        writer.queue.sync { writer.appendVideo(sample) }
        clock.seconds = 100.4
        writer.pause()
        clock.seconds = 105
        if resume { writer.resume(); clock.seconds = 105.6 }
        _ = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let expected = resume ? 1.0 : 0.4
        guard abs(duration - expected) < 0.04, abs(writer.actualDuration - expected) < 0.002 else {
            throw RecorderError.message("静止画面\(resume ? "恢复" : "暂停停止")尾帧时长错误：\(duration)。")
        }
        print("PASS pause static tail: \(resume ? "resume without fresh frames" : "stop while paused"), \(duration)s")
    }

    private static func checkCrossingAudio(directory: URL) async throws {
        let clock = Clock()
        let url = directory.appendingPathComponent("pause-crossing-audio-\(UUID().uuidString).mov")
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 30, quality: .hevc,
            clock: { clock.time })
        let image = try video(at: clock.time)
        writer.queue.sync { writer.appendVideo(image) }
        clock.seconds = 100.5; writer.pause()
        clock.seconds = 101.5; writer.resume()
        let values = (0..<96_000).flatMap { index -> [Float] in
            let time = Double(index) / 48_000
            let frequency = (0.5..<1.5).contains(time) ? 1_700.0 : 440.0
            let value = Float(0.3 * sin(2 * Double.pi * frequency * time))
            return [value, value]
        }
        let audio = try AudioMixer.sample(values, pts: CMTime(seconds: 100, preferredTimescale: 48_000))
        writer.queue.sync { writer.appendAudio(audio) }
        clock.seconds = 102
        _ = try await writer.finish()
        let samples = try await decodedAudio(AVURLAsset(url: url))
        guard abs(writer.actualDuration - 1) < 0.002,
              amplitude(samples, frequency: 440, start: 0.1, end: 0.9) > 0.25,
              amplitude(samples, frequency: 1_700, start: 0.1, end: 0.9) < 0.015 else {
            throw RecorderError.message("跨越暂停边界的音频缓冲区没有按样本裁切。")
        }
        print("PASS pause: delayed PCM buffer spanning both pause boundaries is sliced and joined without paused audio")
    }

    private static func video(at pts: CMTime) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess,
            let image else { throw RecorderError.message("测试画面创建失败。") }
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 100, CVPixelBufferGetBytesPerRow(image) * height) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescriptionOut: &format) == noErr, let format,
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { throw RecorderError.message("测试视频样本创建失败。") }
        return sample
    }

    private static func tone(at time: Double, frequency: Double, frames: Int, rate: Double = 48_000, channels: UInt32 = 2) throws -> CMSampleBuffer {
        let channelCount = Int(channels)
        let angularFrequency: Double = 2.0 * Double.pi * frequency
        let startOffset: Double = time - 100.0
        var values: [Float] = []
        values.reserveCapacity(frames * channelCount)
        for frame in 0..<frames {
            let sampleOffset: Double = Double(frame) / rate
            let sampleTime: Double = startOffset + sampleOffset
            let phase: Double = angularFrequency * sampleTime
            let value = Float(0.3 * sin(phase))
            for _ in 0..<channelCount { values.append(value) }
        }
        return try AudioMixer.sample(values, pts: CMTime(seconds: time, preferredTimescale: 48_000), sampleRate: rate, channels: channels)
    }

    private static func decodedAudio(_ asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw RecorderError.message("暂停录制音频轨道数量异常。") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.message("暂停音频解码未启动。") }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw RecorderError.message("暂停音频解码数据读取失败。") }
            result += stride(from: 0, to: values.count, by: 2).map { values[$0] }
        }
        guard reader.status == .completed else { throw reader.error ?? RecorderError.message("暂停音频未完整解码。") }
        return result
    }

    private static func amplitude(_ audio: [Float], frequency: Double, start: Double, end: Double) -> Double {
        let first = Int(start * 48_000), last = min(audio.count, Int(end * 48_000))
        guard last > first else { return 0 }
        var real = 0.0, imaginary = 0.0
        for index in first..<last {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(audio[index]) * cos(phase)
            imaginary += Double(audio[index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(last - first)
    }
}
