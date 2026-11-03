import AVFoundation
import CoreImage

@MainActor
final class AutoZoomExporter {
    private var session: AVAssetExportSession?
    private var copyTask: Task<Void, Error>?
    private var encodingJob: HEVCEffectEncodingJob?
    private(set) var cancelled = false

    func cancel() {
        cancelled = true
        session?.cancelExport()
        copyTask?.cancel()
        encodingJob?.cancel()
    }

    func export(source: URL, destination: URL, trace: CursorTrace, fps: Int32,
                quality: RecordingQuality, progress: @MainActor @escaping (Double) -> Void) async throws {
        cancelled = false
        if !trace.hasClicks {
            let copy = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: destination)
                try Task.checkCancellation()
            }
            copyTask = copy
            defer { copyTask = nil }
            try await copy.value
            if cancelled { throw CancellationError() }
            progress(1)
            return
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("原片缺少视频轨道。")
        }
        let size = try await track.load(.naturalSize)
        let composition = try await Self.composition(asset: asset, size: size, trace: trace,
                                                     duration: duration, fps: fps)
        if cancelled { throw CancellationError() }
        if quality == .hevc {
            let sourceRate = Double(try await track.load(.estimatedDataRate))
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var audio: [(AVAssetTrack, CMFormatDescription?)] = []
            for track in audioTracks {
                audio.append((track, try await track.load(.formatDescriptions).first))
            }
            let job = try HEVCEffectEncodingJob(asset: asset, track: track, audio: audio,
                composition: composition, destination: destination, size: size,
                duration: duration, fps: fps, bitrate: Self.targetBitrate(size: size, fps: fps, sourceRate: sourceRate))
            encodingJob = job
            defer { encodingJob = nil }
            if cancelled { job.cancel(); throw CancellationError() }
            try await Task.detached(priority: .userInitiated) {
                try await job.run { value in await MainActor.run { progress(value) } }
            }.value
            if cancelled { throw CancellationError() }
            progress(1)
            return
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleProRes422LPCM) else {
            throw RecorderError.message("此设备无法导出自动放大视频。")
        }
        self.session = session
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = false
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { monitor.cancel(); self.session = nil }
        if cancelled { throw CancellationError() }
        try await session.export(to: destination, as: .mov)
        if cancelled { throw CancellationError() }
        progress(1)
    }

    /// Allow extra bits for zoom motion, with a resolution-aware clarity floor.
    /// An almost-static source is too small to use as a hard file-size budget.
    static func targetBitrate(size: CGSize, fps: Int32, sourceRate: Double) -> Int {
        let pixelsPerSecond = size.width * size.height * Double(fps)
        let floor = max(1_500_000, pixelsPerSecond * 0.04)
        let ceiling = max(floor, pixelsPerSecond * 0.08)
        let preferred = sourceRate.isFinite && sourceRate > 0 ? sourceRate * 1.15 : floor
        return Int(min(ceiling, max(floor, preferred)))
    }

    static func composition(asset: AVAsset, size: CGSize, trace: CursorTrace,
                            duration: CMTime, fps: Int32) async throws -> AVVideoComposition {
        let plan = AutoZoomPlan(trace: trace, duration: duration.seconds, fps: Int(fps))
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                let image = request.sourceImage
                let bounds = image.extent
                let pose = plan.pose(at: request.compositionTime.seconds)
                let transform = CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale,
                    tx: bounds.midX - pose.scale * (bounds.minX + pose.x * bounds.width),
                    ty: bounds.midY - pose.scale * (bounds.minY + (1 - pose.y) * bounds.height))
                request.finish(with: image.transformed(by: transform).cropped(to: bounds), context: context)
            }, completionHandler: { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else { continuation.resume(throwing: error ?? RecorderError.message("无法创建缩放合成器。")) }
            })
        }
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: fps)
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }
}

/// Reader and writer are confined to one detached task. Only cancellation crosses
/// executors, guarded by the lock; no encoding or backpressure loop runs on the UI.
final class HEVCEffectEncodingJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)]
    private let duration: CMTime

    init(asset: AVAsset, track: AVAssetTrack, audio: [(AVAssetTrack, CMFormatDescription?)],
         composition: AVVideoComposition, destination: URL, size: CGSize,
         duration: CMTime, fps: Int32, bitrate: Int) throws {
        self.duration = duration
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw RecorderError.message("无法配置效果视频编码器。")
        }
        reader.add(videoOutput); writer.add(videoInput)
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (track, format) in audio {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw RecorderError.message("无法保留效果视频的音轨。")
            }
            reader.add(output); writer.add(input)
            pairs.append((output, input))
        }
        audioPairs = pairs
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }

    func run(progress: @Sendable (Double) async -> Void) async throws {
        do {
            try checkCancellation()
            guard writer.startWriting() else { throw failure("无法开始写入效果视频。") }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw failure("无法读取原片。") }
            var videoDone = false
            var audioDone = Array(repeating: false, count: audioPairs.count)
            var lastProgress = 0.0
            while !videoDone || audioDone.contains(false) {
                try checkCancellation()
                if reader.status == .failed || writer.status == .failed { throw failure("效果视频编码失败。") }
                var advanced = false
                if !videoDone, videoInput.isReadyForMoreMediaData {
                    if let sample = autoreleasepool(invoking: { videoOutput.copyNextSampleBuffer() }) {
                        guard videoInput.append(sample) else { throw failure("效果视频画面写入失败。") }
                        let value = min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration.seconds))
                        if value - lastProgress >= 0.02 {
                            lastProgress = value
                            await progress(value)
                        }
                    } else {
                        videoDone = true
                        videoInput.markAsFinished()
                    }
                    advanced = true
                }
                for index in audioPairs.indices where !audioDone[index] {
                    let (output, input) = audioPairs[index]
                    if input.isReadyForMoreMediaData {
                        if let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
                            // Preserve the original shared timestamps, including silence.
                            guard input.append(sample) else { throw failure("效果视频音轨写入失败。") }
                        } else {
                            audioDone[index] = true
                            input.markAsFinished()
                        }
                        advanced = true
                    }
                }
                if !advanced { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            guard reader.status == .completed else { throw failure("原片读取未完成。") }
            try checkCancellation()
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            try checkCancellation()
            guard writer.status == .completed else { throw failure("效果视频保存失败。") }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    private func failure(_ message: String) -> Error {
        writer.error ?? reader.error ?? RecorderError.message(message)
    }
}
