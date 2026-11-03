import AppKit
import AVFoundation
import CoreVideo

/// Reproducible local size/quality comparison; never captures the user's desktop.
@MainActor
enum ExportSizeSelfTest {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1920, height: 1080)
        let trace = CursorTrace(samples: [
            CursorSample(time: 0.5, x: 0.2, y: 0.3, inside: true, clicked: true),
            CursorSample(time: 1.5, x: 0.35, y: 0.7, inside: true, clicked: true),
            CursorSample(time: 2, x: 0.8, y: 0.5, inside: true, clicked: true),
            CursorSample(time: 3, x: 0.6, y: 0.2, inside: true, clicked: true),
            CursorSample(time: 4, x: 0.25, y: 0.8, inside: true, clicked: true)
        ])
        for scenario in ["desktop", "text"] {
          for fps: Int32 in [30, 60] {
            let name = "\(scenario)-\(fps)"
            let original = directory.appendingPathComponent(name + "-original.mov")
            try await fixture(to: original, size: size, fps: fps, movingChart: scenario == "desktop")
            let asset = AVURLAsset(url: original)
            let duration = try await asset.load(.duration)
            let composition = try await AutoZoomExporter.composition(asset: asset, size: size,
                trace: trace, duration: duration, fps: fps)
            let baseline = directory.appendingPathComponent(name + "-old.mov")
            guard let legacy = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
                throw RecorderError.message("无法创建旧版导出对照。")
            }
            legacy.videoComposition = composition
            try await legacy.export(to: baseline, as: .mov)
            let optimized = directory.appendingPathComponent(name + "-optimized.mov")
            try await AutoZoomExporter().export(source: original, destination: optimized,
                trace: trace, fps: fps, quality: .hevc) { _ in }
            let reference = directory.appendingPathComponent(name + "-reference.mov")
            try await AutoZoomExporter().export(source: original, destination: reference,
                trace: trace, fps: fps, quality: .proRes) { _ in }
            let bytes: (URL) throws -> Int = { url in
                (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            }
            print("SIZE \(name): original=\(try bytes(original)) old=\(try bytes(baseline)) optimized=\(try bytes(optimized))")
          }
        }
    }

    private static func fixture(to url: URL, size: CGSize, fps: Int32, movingChart: Bool) async throws {
        let width = Int(size.width), height = Int(size.height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RecorderError.message("无法生成文字测试画面。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 260, height: height).fill()
        for row in 0..<48 {
            let y = CGFloat(row * 21 + 20)
            ("\(row + 1)   Auto Recorder  |  录屏画质测试  |  const fps = \(fps);  // 0123456789" as NSString)
                .draw(at: CGPoint(x: 290, y: y), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.black
                ])
        }
        for row in 0..<20 {
            ("Folder \(row)   项目文档" as NSString).draw(at: CGPoint(x: 20, y: row * 40 + 40),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let background = bitmap.cgImage else { throw RecorderError.message("文字测试背景为空。") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.message("测试编码未开始。") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(Int(fps) * 6) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? RecorderError.message("测试编码失败。") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess,
                      let pixel else { throw RecorderError.message("测试像素缓冲分配失败。") }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue) else { throw RecorderError.message("测试绘图失败。") }
                context.draw(background, in: CGRect(origin: .zero, size: size))
                // Text plus a moving detailed chart, rather than an easy flat gradient.
                let phase = Double(frame) / Double(fps)
                if movingChart {
                  context.saveGState()
                context.clip(to: CGRect(x: 1100, y: 120, width: 720, height: 800))
                for row in 0..<32 { for column in 0..<26 {
                    let x = 1080 + Double(column * 30) + sin(phase * 2) * 70
                    let y = Double(row * 30 + 100) + cos(phase * 1.7) * 40
                    let hue = Double((row * 17 + column * 13) % 100) / 100
                    context.setFillColor(CGColor(red: hue, green: 0.3 + hue * 0.4, blue: 1 - hue, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 27, height: 27))
                } }
                  context.restoreGState()
                }
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                    throw writer.error ?? RecorderError.message("测试视频写入失败。")
                }
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("测试视频未完成。") }
    }
}
