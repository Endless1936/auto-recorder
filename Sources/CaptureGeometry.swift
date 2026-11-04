import Foundation

enum CaptureMode: Int { case entireDisplay, region, window }

struct CaptureArea {
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

struct RememberedRegion: Codable {
    let displayID: UInt32
    let displaySize: CGSize
    let scale: CGFloat
    let rect: CGRect

    func restored(displayID: UInt32, displaySize: CGSize, scale: CGFloat) -> CGRect? {
        guard self.displayID == displayID, self.displaySize == displaySize, self.scale == scale,
              rect.width >= SelectionGeometry.minimum, rect.height >= SelectionGeometry.minimum,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              CGRect(origin: .zero, size: displaySize).contains(rect),
              let area = try? CaptureGeometry.area(region: rect, displaySize: displaySize, scale: scale) else { return nil }
        return area.sourceRect
    }
}

enum RegionMemory {
    private static let key = "lastCaptureRegion"
    static func load(from defaults: UserDefaults = .standard) -> RememberedRegion? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedRegion.self, from: data)
    }
    static func save(_ region: RememberedRegion, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(region) else { return }
        defaults.set(data, forKey: key)
    }
}

enum CaptureGeometry {
    /// Rectangles are display-local points, with the origin at the top left.
    static func area(region: CGRect?, displaySize: CGSize, scale: CGFloat) throws -> CaptureArea {
        guard scale.isFinite, scale > 0, displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else {
            throw RecorderError.message("屏幕尺寸无效，请重新选择显示器。")
        }
        let bounds = CGRect(origin: .zero, size: displaySize)
        let request = region ?? bounds
        guard [request.minX, request.minY, request.width, request.height].allSatisfy(\.isFinite),
              request.width > 0, request.height > 0 else {
            throw RecorderError.message("录制区域无效，请重新框选。")
        }
        let crop = request.intersection(bounds)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else {
            throw RecorderError.message("录制区域位于屏幕之外，请重新框选。")
        }
        let x = floor(crop.minX * scale)
        let y = floor(crop.minY * scale)
        let right = min(floor(displaySize.width * scale), ceil(crop.maxX * scale))
        let bottom = min(floor(displaySize.height * scale), ceil(crop.maxY * scale))
        let width = Int(right - x) / 2 * 2
        let height = Int(bottom - y) / 2 * 2
        guard width >= 2, height >= 2 else {
            throw RecorderError.message("录制区域太小，请重新框选。")
        }
        return CaptureArea(sourceRect: CGRect(x: x / scale, y: y / scale,
            width: CGFloat(width) / scale, height: CGFloat(height) / scale),
            pixelWidth: width, pixelHeight: height)
    }
}

struct SelectionEdges: OptionSet {
    let rawValue: Int
    static let left = SelectionEdges(rawValue: 1)
    static let right = SelectionEdges(rawValue: 2)
    static let top = SelectionEdges(rawValue: 4)
    static let bottom = SelectionEdges(rawValue: 8)
}

enum SelectionGeometry {
    static let minimum: CGFloat = 32
    static let redrawThreshold: CGFloat = 6
    /// Generous invisible hit targets; corners win over straight edges.
    static func hitEdges(_ point: CGPoint, rect: CGRect) -> SelectionEdges? {
        let corners: [(CGPoint, SelectionEdges)] = [
            (CGPoint(x: rect.minX, y: rect.minY), [.left, .top]),
            (CGPoint(x: rect.maxX, y: rect.minY), [.right, .top]),
            (CGPoint(x: rect.minX, y: rect.maxY), [.left, .bottom]),
            (CGPoint(x: rect.maxX, y: rect.maxY), [.right, .bottom])]
        if let nearest = corners.min(by: { hypot(point.x - $0.0.x, point.y - $0.0.y) < hypot(point.x - $1.0.x, point.y - $1.0.y) }),
           abs(point.x - nearest.0.x) <= 16, abs(point.y - nearest.0.y) <= 16 { return nearest.1 }
        if point.y >= rect.minY - 12 && point.y <= rect.maxY + 12 {
            if abs(point.x - rect.minX) <= 12 { return .left }
            if abs(point.x - rect.maxX) <= 12 { return .right }
        }
        if point.x >= rect.minX - 12 && point.x <= rect.maxX + 12 {
            if abs(point.y - rect.minY) <= 12 { return .top }
            if abs(point.y - rect.maxY) <= 12 { return .bottom }
        }
        return nil
    }
    static func clamp(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: max(0, min(size.width, point.x)), y: max(0, min(size.height, point.y)))
    }
    static func draw(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect {
        let a = clamp(start, size: size), b = clamp(end, size: size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    static func move(_ rect: CGRect, delta: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: max(0, min(size.width - rect.width, rect.minX + delta.x)),
               y: max(0, min(size.height - rect.height, rect.minY + delta.y)),
               width: rect.width, height: rect.height)
    }
    static func resize(_ rect: CGRect, edges: SelectionEdges, delta: CGPoint, size: CGSize) -> CGRect {
        var x1 = rect.minX, x2 = rect.maxX, y1 = rect.minY, y2 = rect.maxY
        if edges.contains(.left) { x1 = max(0, min(x2 - minimum, x1 + delta.x)) }
        if edges.contains(.right) { x2 = min(size.width, max(x1 + minimum, x2 + delta.x)) }
        if edges.contains(.top) { y1 = max(0, min(y2 - minimum, y1 + delta.y)) }
        if edges.contains(.bottom) { y2 = min(size.height, max(y1 + minimum, y2 + delta.y)) }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
