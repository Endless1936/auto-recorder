import AppKit
import ScreenCaptureKit

/// Development-only capture of this application's own windows, including AVPlayer's video layer.
@MainActor
enum WindowSnapshots {
    static func save(_ window: NSWindow, to url: URL) async throws {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let filter = SCContentFilter(desktopIndependentWindow: source)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url); return }
            }
        }
        guard let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RecorderError.message("无法生成窗口预览。")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url) }
    }
}
