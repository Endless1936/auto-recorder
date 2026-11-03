import AVFoundation
import CoreMedia

struct CaptureAudioOptions {
    var systemAudio: Bool
    var microphone: Bool
    init(systemAudio: Bool = true, microphone: Bool = false) {
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
    var enabled: Bool { systemAudio || microphone }
}

enum CaptureAudioSource: Hashable { case system, microphone }

/// Timestamp-aligned, bounded PCM mixing. Called only on the writer's serial queue.
/// A half-second window lets independently delivered device callbacks catch up;
/// a silent or disconnected source never stalls the recording.
final class AudioMixer {
    private final class Chunk {
        var samples = [Float](repeating: 0, count: 1_024 * 2)
    }
    private final class Conversion {
        let format: AVAudioFormat
        let converter: AVAudioConverter
        var nextOutputFrame: Int64?
        var nextInputFrame: Int64?
        init(format: AVAudioFormat, converter: AVAudioConverter) {
            self.format = format
            self.converter = converter
        }
    }
    private let options: CaptureAudioOptions
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var conversions: [CaptureAudioSource: Conversion] = [:]
    private var chunks: [Int64: Chunk] = [:]
    private var nextFrame: Int64 = 0
    private var latestFrame: Int64 = 0
    private var origin = CMTime.invalid
    private let window: Int64 = 24_000
    private let chunkSize: Int64 = 1_024

    init(options: CaptureAudioOptions) { self.options = options }

    func append(_ sample: CMSampleBuffer, source: CaptureAudioSource, origin: CMTime) throws -> [CMSampleBuffer] {
        guard (source == .system ? options.systemAudio : options.microphone),
              let description = CMSampleBufferGetFormatDescription(sample) else { return [] }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.isNumeric else { return [] }
        if !self.origin.isValid { self.origin = origin }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count <= 192_000,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw RecorderError.message("音频样本格式无效。")
        }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                           into: input.mutableAudioBufferList) == noErr else {
            throw RecorderError.message("无法读取电脑声音或麦克风样本。")
        }
        if conversions[source]?.format != inputFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw RecorderError.message("当前音频输入设备的采样格式不受支持。")
            }
            converter.primeMethod = .none
            conversions[source] = Conversion(format: inputFormat, converter: converter)
        }
        let conversion = conversions[source]!
        let converter = conversion.converter
        let rawPosition = CMTimeConvertScale(CMTimeSubtract(pts, self.origin), timescale: 48_000,
                                             method: .roundHalfAwayFromZero).value
        let expectedLength = Int64((Double(count) * 48_000 / inputFormat.sampleRate).rounded())
        let position: Int64
        if let expected = conversion.nextInputFrame,
           abs(Double(rawPosition) - Double(expected)) < 96,
           let next = conversion.nextOutputFrame {
            // Carry the resampler's output position through fractional frame rounding and
            // its internal filter delay; do not restart the output clock per callback.
            position = next
        } else {
            converter.reset()
            position = rawPosition
        }
        conversion.nextInputFrame = rawPosition + expectedLength
        let capacity = AVAudioFrameCount(ceil(Double(count) * 48_000 / inputFormat.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecorderError.message("无法分配混音缓冲区。")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else { throw error ?? RecorderError.message("音频格式转换失败。") }
        guard let channels = output.floatChannelData, output.frameLength > 0 else { return [] }
        let length = Int64(output.frameLength)
        conversion.nextOutputFrame = position + length
        // A source may first become audible minutes later. Sparse chunks preserve that
        // timestamp gap without allocating silence, while ignoring already emitted data.
        guard position + length > nextFrame else { return [] }
        let gain: Float = options.systemAudio && options.microphone ? 0.5 : 1
        var offset = max(0, nextFrame - position)
        while offset < length {
            let frame = position + offset
            let key = frame / chunkSize
            let local = Int(frame % chunkSize)
            let amount = min(Int(length - offset), Int(chunkSize) - local)
            let chunk = chunks[key] ?? Chunk()
            chunks[key] = chunk
            for i in 0..<amount {
                chunk.samples[(local + i) * 2] += channels[0][Int(offset) + i] * gain
                chunk.samples[(local + i) * 2 + 1] += channels[1][Int(offset) + i] * gain
            }
            offset += Int64(amount)
        }
        latestFrame = max(latestFrame, position + length)
        return try drain(until: max(0, latestFrame - window), final: false)
    }

    func finish(until end: CMTime) throws -> [CMSampleBuffer] {
        guard origin.isValid else { return [] }
        let endFrame = CMTimeConvertScale(CMTimeSubtract(end, origin), timescale: 48_000,
                                          method: .roundHalfAwayFromZero).value
        return try drain(until: min(latestFrame, max(0, endFrame)), final: true)
    }

    private func drain(until limit: Int64, final: Bool) throws -> [CMSampleBuffer] {
        var result: [CMSampleBuffer] = []
        while nextFrame < limit {
            if chunks[nextFrame / chunkSize] == nil {
                if let key = chunks.keys.filter({ $0 * chunkSize >= nextFrame }).min(), key * chunkSize < limit {
                    nextFrame = key * chunkSize
                } else {
                    nextFrame = limit / chunkSize * chunkSize
                    break
                }
            }
            let amount = min(chunkSize, limit - nextFrame)
            if !final && amount < chunkSize { break }
            let key = nextFrame / chunkSize
            let chunk = chunks.removeValue(forKey: key)
            var values = chunk?.samples ?? [Float](repeating: 0, count: Int(chunkSize) * 2)
            if amount < chunkSize { values.removeLast(Int(chunkSize - amount) * 2) }
            // Keep pathological floating-point or input overloads out of encoded output.
            for i in values.indices { values[i] = values[i].isFinite ? max(-1, min(1, values[i])) : 0 }
            let pts = CMTimeAdd(origin, CMTime(value: nextFrame, timescale: 48_000))
            result.append(try Self.sample(values, pts: pts))
            nextFrame += amount
        }
        return result
    }

    static func sample(_ values: [Float], pts: CMTime, sampleRate: Double = 48_000,
                       channels: UInt32 = 2) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        var block: CMBlockBuffer?
        let length = values.count * MemoryLayout<Float>.size
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format,
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw RecorderError.message("混音缓冲区创建失败。") }
        let copyStatus = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                       presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard copyStatus == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: values.count / Int(channels),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &result) == noErr, let result else {
            throw RecorderError.message("混音样本创建失败。")
        }
        return result
    }
}
