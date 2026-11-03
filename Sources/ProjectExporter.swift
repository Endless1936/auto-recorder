import AVFoundation
import CoreImage

struct ProjectTimeline {
    let asset: AVMutableComposition
    let videoComposition: AVVideoComposition
    let size: CGSize
    let duration: CMTime
}

private struct ProjectRenderRange: Sendable {
    let start: Double
    let clip: DemoClip
}

@MainActor
final class ProjectExporter {
    private var session: AVAssetExportSession?
    private var encodingJob: HEVCEffectEncodingJob?
    private var copyTask: Task<Void, Error>?
    private(set) var cancelled = false

    func cancel() {
        cancelled = true
        session?.cancelExport()
        encodingJob?.cancel()
        copyTask?.cancel()
    }

    func export(project: RecordingProject, destination: URL,
                progress: @MainActor @escaping (Double) -> Void) async throws {
        try ProjectStore.validate(project)
        try checkCancellation()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard target != project.sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
              target != project.jsonURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw RecorderError.message("导出位置不能覆盖工程原片或参数文件。")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".导出中-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress(0)
        try checkCancellation()

        let matchingCodec = try await Self.sourceMatchesQuality(project)
        try checkCancellation()
        if Self.isUnchanged(project) && matchingCodec {
            let source = project.sourceURL
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: temporary)
                try Task.checkCancellation()
            }
            copyTask = task
            defer { copyTask = nil }
            try await task.value
        } else {
            let timeline = try await Self.buildTimeline(project: project)
            try checkCancellation()
            if project.quality == .hevc {
                guard let track = try await timeline.asset.loadTracks(withMediaType: .video).first else {
                    throw RecorderError.message("剪辑工程缺少视频轨道。")
                }
                let source = AVURLAsset(url: project.sourceURL)
                let sourceTrack = try await source.loadTracks(withMediaType: .video).first
                let sourceRate = Double(try await sourceTrack?.load(.estimatedDataRate) ?? 0)
                var audio: [(AVAssetTrack, CMFormatDescription?)] = []
                for audioTrack in try await timeline.asset.loadTracks(withMediaType: .audio) {
                    audio.append((audioTrack, try await audioTrack.load(.formatDescriptions).first))
                }
                let job = try HEVCEffectEncodingJob(asset: timeline.asset, track: track,
                    audio: audio, composition: timeline.videoComposition, destination: temporary,
                    size: timeline.size, duration: timeline.duration, fps: project.fps,
                    bitrate: AutoZoomExporter.targetBitrate(size: timeline.size, fps: project.fps,
                                                            sourceRate: sourceRate))
                encodingJob = job
                defer { encodingJob = nil }
                try checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try await job.run { value in
                        await MainActor.run { progress(min(0.99, value)) }
                    }
                }.value
            } else {
                guard let session = AVAssetExportSession(asset: timeline.asset,
                    presetName: AVAssetExportPresetAppleProRes422LPCM) else {
                    throw RecorderError.message("此设备无法导出 ProRes 视频。")
                }
                self.session = session
                session.videoComposition = timeline.videoComposition
                session.shouldOptimizeForNetworkUse = false
                let monitor = Task { @MainActor in
                    while !Task.isCancelled {
                        progress(min(0.99, Double(session.progress)))
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                }
                defer { monitor.cancel(); self.session = nil }
                try checkCancellation()
                do {
                    try await session.export(to: temporary, as: .mov)
                } catch {
                    if cancelled || Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
        }
        try checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
    }

    static func isUnchanged(_ project: RecordingProject) -> Bool {
        guard project.clips.count == 1, let clip = project.clips.first else { return false }
        return abs(clip.sourceStart) < 0.000001 &&
            abs(clip.duration - project.sourceDuration) < 0.000001 &&
            clip.zooms.allSatisfy { !$0.isEnabled }
    }

    private static func sourceMatchesQuality(_ project: RecordingProject) async throws -> Bool {
        let asset = AVURLAsset(url: project.sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else { return false }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        return project.quality == .hevc ? subtype == kCMVideoCodecType_HEVC : subtype == kCMVideoCodecType_AppleProRes422
    }

    /// The framing preview keeps the edited timeline and skips only the camera.
    /// Export always uses the default camera-enabled composition.
    static func buildTimeline(project: RecordingProject,
                              cameraEffectsEnabled: Bool = true) async throws -> ProjectTimeline {
        try ProjectStore.validate(project)
        let source = AVURLAsset(url: project.sourceURL)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("原片缺少视频轨道。")
        }
        let size = try await sourceVideo.load(.naturalSize)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.message("无法创建剪辑视频轨道。")
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var sourceAudio: [(AVAssetTrack, AVMutableCompositionTrack, CMTimeRange)] = []
        for track in try await source.loadTracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            guard project.clips.contains(where: {
                CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: Self.time($0.sourceStart),
                    duration: Self.time($0.duration))).duration.seconds > 0
            }) else { continue }
            guard let output = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecorderError.message("无法创建剪辑音轨。")
            }
            sourceAudio.append((track, output, range))
        }

        var insertion = CMTime.zero
        var ranges: [ProjectRenderRange] = []
        for clip in project.clips {
            try Task.checkCancellation()
            let input = CMTimeRange(start: Self.time(clip.sourceStart), duration: Self.time(clip.duration))
            try video.insertTimeRange(input, of: sourceVideo, at: insertion)
            for (track, output, available) in sourceAudio {
                let intersection = CMTimeRangeGetIntersection(input, otherRange: available)
                if intersection.isValid, intersection.duration.seconds > 0 {
                    let offset = CMTimeSubtract(intersection.start, input.start)
                    try output.insertTimeRange(intersection, of: track, at: CMTimeAdd(insertion, offset))
                }
            }
            ranges.append(ProjectRenderRange(start: insertion.seconds, clip: clip))
            insertion = CMTimeAdd(insertion, input.duration)
        }
        let renderRanges = ranges
        let context = CIContext(options: [.cacheIntermediates: false])
        let videoComposition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { request in
                let time = request.compositionTime.seconds
                let range = renderRanges.last(where: { $0.start <= time }) ?? renderRanges[0]
                let pose = cameraEffectsEnabled
                    ? range.clip.pose(at: min(range.clip.duration, max(0, time - range.start)))
                    : DemoZoomPose()
                let image = request.sourceImage
                let bounds = image.extent
                let transform = CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale,
                    tx: bounds.midX - pose.scale * (bounds.minX + pose.x * bounds.width),
                    ty: bounds.midY - pose.scale * (bounds.minY + (1 - pose.y) * bounds.height))
                request.finish(with: image.transformed(by: transform).cropped(to: bounds), context: context)
            }, completionHandler: { result, error in
                if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: error ?? RecorderError.message("无法建立剪辑预览。")) }
            })
        }
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: project.fps)
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return ProjectTimeline(asset: composition, videoComposition: videoComposition,
                               size: size, duration: insertion)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private func checkCancellation() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }
}
