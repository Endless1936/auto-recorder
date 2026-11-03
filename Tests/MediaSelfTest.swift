import Foundation
import AVFoundation
import CoreVideo
import AudioToolbox
import CoreMedia

enum MediaSelfTest {
    private static let width = 1920
    private static let height = 1080
    static func run(directory: URL) async throws {
        try GeometrySelfTest.run()
        try testMixer()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for quality in RecordingQuality.allCases {
            let url = directory.appendingPathComponent(quality == .hevc ? "hevc.mov" : "prores.mov")
            let writer = try RecordingWriter(url: url, width: width, height: height, fps: 60, quality: quality)
            for frame in 0..<120 {
                let video = try videoSample(frame: frame)
                let audio = try audioSample(frame: frame)
                writer.queue.sync {
                    writer.appendVideo(video)
                    writer.appendAudio(audio)
                }
                try await Task.sleep(nanoseconds: 16_666_667)
            }
            let stats = try await writer.finish(extendToNow: false)
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard let track = videoTracks.first, audioTracks.count == 1,
                  duration.seconds >= 1.95, duration.seconds <= 2.1,
                  stats.videoFrames == 120, stats.droppedAudio == 0 else {
                throw RecorderError.message("\(quality.title) 测试失败：轨道、时长或丢帧异常。")
            }
            let size = try await track.load(.naturalSize)
            guard size == CGSize(width: width, height: height) else { throw RecorderError.message("分辨率测试失败。") }
            print("PASS \(quality.title): \(stats.videoFrames) frames, \(stats.audioBuffers) audio buffers, \(duration.seconds)s, \(Int(size.width))x\(Int(size.height))")
        }
        try await testAudioModes(directory: directory)
        try await testAudioGaps(directory: directory)
        // A static desktop may not deliver fresh frames. Its movie must still keep elapsed time.
        let url = directory.appendingPathComponent("static-tail.mov")
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: 60, quality: .hevc)
        let sample = try videoSample(frame: 0)
        writer.queue.sync { writer.appendVideo(sample) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration)
        guard duration.seconds > 1.15, duration.seconds < 2 else { throw RecorderError.message("静止画面时长测试失败。") }
        print("PASS static desktop tail: \(duration.seconds)s")

        let emptyURL = directory.appendingPathComponent("empty.mov")
        let empty = try RecordingWriter(url: emptyURL, width: width, height: height, fps: 60, quality: .hevc)
        do {
            _ = try await empty.finish()
            throw RecorderError.message("空录制应返回错误。")
        } catch RecorderError.message(let message) where message.contains("没有收到") {
            print("PASS empty recording rejected")
        }
    }

    private static func tone(rate: Double, channels: UInt32, frequency: Double,
                             tick: Int, delay: Double = 0) throws -> CMSampleBuffer {
        let count = Int(rate / 100)
        var samples = [Float](repeating: 0, count: count * Int(channels))
        for i in 0..<count {
            let value = Float(sin(2 * Double.pi * frequency * Double(tick * count + i) / rate) * 0.25)
            for channel in 0..<Int(channels) { samples[i * Int(channels) + channel] = value }
        }
        return try AudioMixer.sample(samples, pts: CMTime(seconds: Double(tick) / 100 + delay,
                                                         preferredTimescale: 48_000),
                                     sampleRate: rate, channels: channels)
    }

    private static func pcm(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw RecorderError.message("测试音频缺少格式。")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw RecorderError.message("测试音频内存分配失败。")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
            into: buffer.mutableAudioBufferList) == noErr, let channels = buffer.floatChannelData else {
            throw RecorderError.message("测试音频读取失败。")
        }
        if format.isInterleaved { return Array(UnsafeBufferPointer(start: channels[0], count: count * Int(format.channelCount))) }
        return (0..<count).flatMap { i in (0..<Int(format.channelCount)).map { channels[$0][i] } }
    }

    private static func amplitude(_ samples: [Float], frequency: Double,
                                  start: Double = 0.3, end: Double = 0.8) -> Double {
        let first = Int(start * 48_000)
        let last = min(samples.count / 2, Int(end * 48_000))
        guard last > first else { return 0 }
        var real = 0.0, imaginary = 0.0
        for i in first..<last {
            let phase = 2 * Double.pi * frequency * Double(i) / 48_000
            real += Double(samples[i * 2]) * cos(phase)
            imaginary += Double(samples[i * 2]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(last - first)
    }

    private static func testMixer() throws {
        let mixer = AudioMixer(options: .init(systemAudio: true, microphone: true))
        var outputs: [CMSampleBuffer] = []
        for tick in 0..<200 {
            outputs += try mixer.append(tone(rate: 48_000, channels: 2, frequency: 440, tick: tick),
                                        source: .system, origin: .zero)
            outputs += try mixer.append(tone(rate: 44_100, channels: 1, frequency: 880, tick: tick, delay: 0.1),
                                        source: .microphone, origin: .zero)
        }
        outputs += try mixer.finish(until: CMTime(seconds: 2, preferredTimescale: 48_000))
        let samples = try outputs.flatMap { try pcm($0) }
        guard samples.count == 192_000,
              amplitude(samples, frequency: 440) > 0.10,
              amplitude(samples, frequency: 880) > 0.10,
              amplitude(samples, frequency: 880, start: 0, end: 0.08) < 0.01,
              zip(stride(from: 0, to: samples.count, by: 2), stride(from: 1, to: samples.count, by: 2))
                .allSatisfy({ abs(samples[$0.0] - samples[$0.1]) < 0.0001 }) else {
            throw RecorderError.message("混音测试失败：不同采样率、声道或时间戳未正确合并。")
        }
        let silentMic = AudioMixer(options: .init(systemAudio: true, microphone: true))
        var emitted = 0
        for tick in 0..<100 {
            emitted += try silentMic.append(tone(rate: 48_000, channels: 2, frequency: 440, tick: tick),
                                            source: .system, origin: .zero).count
        }
        guard emitted > 0 else { throw RecorderError.message("静音麦克风阻塞混音。") }
        print("PASS mixer: 48 kHz stereo + delayed 44.1 kHz mono, both tones, timing, stereo mapping, absent-source progress")
    }

    static func runAudioGapChecks(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try testMixer()
        try await testAudioGaps(directory: directory)
    }

    private static func testAudioGaps(directory: URL) async throws {
        for lateFirst in [false, true] {
            let url = directory.appendingPathComponent(lateFirst ? "audio-late-first.mov" : "audio-resumed.mov")
            let writer = try RecordingWriter(url: url, width: width, height: height, fps: 60, quality: .hevc)
            let sample = try videoSample(frame: 0)
            writer.queue.sync { writer.appendVideo(sample) }
            let mixer = AudioMixer(options: .init())
            var mixed: [CMSampleBuffer] = []
            for tick in (lateFirst ? [] : Array(0..<30)) + Array(2_000..<2_030) {
                let audio = try tone(rate: 48_000, channels: 2, frequency: 440, tick: tick)
                mixed += try mixer.append(audio, source: .system, origin: .zero)
                writer.queue.sync { writer.appendAudio(audio) }
            }
            let end = CMTime(seconds: 20.3, preferredTimescale: 48_000)
            mixed += try mixer.finish(until: end)
            var previous = CMTime.invalid
            var frames = 0
            for buffer in mixed {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                guard !previous.isValid || CMTimeCompare(pts, previous) > 0 else {
                    throw RecorderError.message("静音后音频时间戳不递增。")
                }
                previous = pts
                frames += CMSampleBufferGetNumSamples(buffer)
            }
            guard frames < 48_000, let last = mixed.last,
                  CMSampleBufferGetPresentationTimeStamp(last).seconds > 20 else {
                throw RecorderError.message("静音间隔被错误缓冲或后续音频丢失。")
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                           presentationTimeStamp: end, decodeTimeStamp: .invalid)
            var tail: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &tail) == noErr, let tail else { throw RecorderError.message("测试尾帧创建失败。") }
            try await Task.sleep(nanoseconds: 50_000_000)
            writer.queue.sync { writer.appendVideo(tail) }
            _ = try await writer.finish(extendToNow: false)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw RecorderError.message("静音间隔测试音轨丢失。") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RecorderError.message("静音间隔测试无法解码。") }
            var hasResumedTone = false
            while let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                if pts >= 20.05 && pts < 20.25 {
                    let values = try pcm(buffer)
                    if values.contains(where: { abs($0) > 0.10 }) { hasResumedTone = true }
                }
            }
            guard reader.status == .completed, hasResumedTone else {
                throw reader.error ?? RecorderError.message("20 秒静音后的声音时间轴或解码错误。")
            }
            print("PASS audio \(lateFirst ? "late first" : "resumed"): 20-second silent gap, bounded sparse buffer, monotonic timestamps, decoded tone at 20 seconds")
        }
    }

    private static func testAudioModes(directory: URL) async throws {
        for options in [CaptureAudioOptions(systemAudio: false, microphone: false),
                        .init(systemAudio: true, microphone: false),
                        .init(systemAudio: false, microphone: true),
                        .init(systemAudio: true, microphone: true)] {
            let label = "audio-\(options.systemAudio ? 1 : 0)-\(options.microphone ? 1 : 0)"
            let url = directory.appendingPathComponent(label + ".mov")
            let writer = try RecordingWriter(url: url, width: width, height: height,
                                            fps: 60, quality: .hevc, audioOptions: options)
            for tick in 0..<100 {
                let video = try videoSample(frame: tick * 60 / 100)
                let system = try tone(rate: 48_000, channels: 2, frequency: 440, tick: tick)
                let mic = try tone(rate: 44_100, channels: 1, frequency: 880, tick: tick)
                writer.queue.sync {
                    writer.appendVideo(video)
                    if options.systemAudio { writer.appendAudio(system) }
                    if options.microphone { writer.appendAudio(mic, source: .microphone) }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let stats = try await writer.finish(extendToNow: false)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == (options.enabled ? 1 : 0), stats.droppedAudio == 0 else {
                throw RecorderError.message("\(label) 音轨数量错误或丢失音频。")
            }
            if let track = tracks.first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
                ])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? RecorderError.message("测试音频无法解码。") }
                var samples: [Float] = []
                while let sample = output.copyNextSampleBuffer() { samples += try pcm(sample) }
                guard reader.status == .completed else { throw reader.error ?? RecorderError.message("测试音频解码失败。") }
                let systemAmplitude = amplitude(samples, frequency: 440)
                let micAmplitude = amplitude(samples, frequency: 880)
                guard (options.systemAudio ? systemAmplitude > 0.09 : systemAmplitude < 0.01),
                      (options.microphone ? micAmplitude > 0.09 : micAmplitude < 0.01) else {
                    throw RecorderError.message("\(label) 普通播放音轨未包含正确音源。")
                }
            }
            print("PASS \(label): \(tracks.count) audio track, both source switches verified by decoded tone spectrum")
        }
    }

    private static func videoSample(frame: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw RecorderError.message("测试像素缓冲区创建失败。") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * row + x * 4
                let stripe = (x + frame * 4) % 160 < 80
                base[i] = UInt8(y * 255 / (height - 1))
                base[i + 1] = stripe ? 190 : 30
                base[i + 2] = UInt8(x * 255 / (width - 1))
                base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { throw RecorderError.message("测试视频样本创建失败。") }
        return sample
    }

    private static func audioSample(frame: Int) throws -> CMSampleBuffer {
        let count = 800
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let position = Double(frame * count + i) / 48_000
            let value = Float(sin(2 * Double.pi * 440 * position) * 0.25)
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { throw RecorderError.message("测试音频格式创建失败。") }
        var block: CMBlockBuffer?
        let length = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw RecorderError.message("测试音频缓冲区创建失败。") }
        let copyStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard copyStatus == noErr,
              CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample) == noErr,
              let sample else { throw RecorderError.message("测试音频样本创建失败。") }
        return sample
    }
}
