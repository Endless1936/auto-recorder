import Foundation

enum GeometrySelfTest {
    static func run() throws {
        let size = CGSize(width: 1920, height: 1080)
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw RecorderError.message("区域测试失败：\(message)") }
        }
        let retina = try CaptureGeometry.area(region: CGRect(x: 100, y: 60, width: 400, height: 200),
            displaySize: CGSize(width: 1440, height: 900), scale: 2)
        try check(retina.sourceRect == CGRect(x: 100, y: 60, width: 400, height: 200) &&
            retina.pixelWidth == 800 && retina.pixelHeight == 400, "Retina 坐标与原生像素")
        let odd = try CaptureGeometry.area(region: nil, displaySize: CGSize(width: 1921, height: 1081), scale: 1)
        try check(odd.pixelWidth == 1920 && odd.pixelHeight == 1080, "偶数像素对齐")
        let fractional = try CaptureGeometry.area(region: CGRect(x: 10.25, y: 20.75, width: 400.75, height: 200.25),
            displaySize: size, scale: 2)
        try check(fractional.sourceRect == CGRect(x: 10, y: 20.5, width: 401, height: 200) &&
            fractional.pixelWidth == 802 && fractional.pixelHeight == 400, "小数坐标对齐")
        let clipped = try CaptureGeometry.area(region: CGRect(x: -10, y: -20, width: 210, height: 220), displaySize: size, scale: 2)
        try check(clipped.sourceRect == CGRect(x: 0, y: 0, width: 200, height: 200), "越界区域裁剪")
        for invalid in [CGRect(x: 3000, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 1, height: 1)] {
            var rejected = false
            do { _ = try CaptureGeometry.area(region: invalid, displaySize: size, scale: 1) }
            catch { rejected = true }
            try check(rejected, "拒绝屏幕外与过小的区域")
        }
        let drawn = SelectionGeometry.draw(from: CGPoint(x: 800, y: 500), to: CGPoint(x: 100, y: 120), size: size)
        try check(drawn == CGRect(x: 100, y: 120, width: 700, height: 380), "反向拖拽")
        let moved = SelectionGeometry.move(drawn, delta: CGPoint(x: -9999, y: 9999), size: size)
        try check(moved == CGRect(x: 0, y: 700, width: 700, height: 380), "移动与边界限制")
        let tiny = SelectionGeometry.resize(drawn, edges: [.left, .top], delta: CGPoint(x: 9999, y: 9999), size: size)
        try check(tiny == CGRect(x: 768, y: 468, width: 32, height: 32), "控制点最小尺寸")
        let expanded = SelectionGeometry.resize(drawn, edges: [.right, .bottom], delta: CGPoint(x: 9999, y: 9999), size: size)
        try check(expanded == CGRect(x: 100, y: 120, width: 1820, height: 960), "控制点最大边界")
        try check(SelectionGeometry.hitEdges(CGPoint(x: 84, y: 104), rect: drawn) == [.left, .top], "角控制点 16 点命中")
        try check(SelectionGeometry.hitEdges(CGPoint(x: 88, y: 250), rect: drawn) == .left, "整条边 12 点命中")
        try check(SelectionGeometry.hitEdges(CGPoint(x: 87, y: 250), rect: drawn) == nil, "边界命中区外可重画")
        try check(SelectionGeometry.hitEdges(CGPoint(x: 300, y: 300), rect: drawn) == nil, "内部可自由移动")
        print("PASS region geometry: Retina, pixel alignment, crop bounds, reverse drag, move, resize, invalid regions")
    }
}
