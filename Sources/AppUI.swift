import AppKit
import Combine
import SwiftUI

typealias AppState<Value> = SwiftUI.State<Value>

enum AppTheme {
    static let background = Color(red: 0.125, green: 0.138, blue: 0.151)
    static let paper = Color(red: 0.169, green: 0.181, blue: 0.192)
    static let ink = Color(red: 0.94, green: 0.95, blue: 0.95)
    static let secondary = Color(red: 0.64, green: 0.67, blue: 0.68)
    static let line = Color(red: 0.27, green: 0.29, blue: 0.30)
    static let accent = Color(red: 0.65, green: 0.92, blue: 0.77)
    static let nsBackground = NSColor(srgbRed: 0.125, green: 0.138, blue: 0.151, alpha: 1)
}

func appTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds.isFinite ? seconds : 0))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

struct CaptureSourceItem: Identifiable, Equatable { let id: UInt32; let name: String }
struct MicrophoneItem: Identifiable, Equatable { let id: String; let name: String }

@MainActor
final class RecorderSettings: ObservableObject {
    @Published var mode: CaptureMode = .entireDisplay
    @Published var sourceID: UInt32 = 0
    @Published var sources: [CaptureSourceItem] = []
    @Published var microphones: [MicrophoneItem] = []
    @Published var microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
    @Published var systemAudio = UserDefaults.standard.object(forKey: "systemAudioEnabled") as? Bool ?? true
    @Published var microphone = UserDefaults.standard.object(forKey: "microphoneEnabled") as? Bool ?? false
    @Published var autoZoom = UserDefaults.standard.object(forKey: "autoZoomEnabled") as? Bool ?? true
    @Published var quality = UserDefaults.standard.integer(forKey: "quality")
    @Published var fps = UserDefaults.standard.object(forKey: "recordingFPS") as? Int ?? 60
    @Published var directory = UserDefaults.standard.url(forKey: "projectDirectory") ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("Auto Recorder", isDirectory: true)
    @Published var systemLevel: Double = 0
    @Published var microphoneLevel: Double = 0
    @Published var busy = false
    @Published var recording = false
    @Published var paused = false
    @Published var loadingSources = false
    @Published var advanced = false
    @Published var regionTitle = "选择区域"
    @Published var error = ""
    func save() {
        let d = UserDefaults.standard
        d.set(systemAudio, forKey: "systemAudioEnabled"); d.set(microphone, forKey: "microphoneEnabled")
        d.set(microphoneID, forKey: "microphoneID"); d.set(autoZoom, forKey: "autoZoomEnabled")
        d.set(quality, forKey: "quality"); d.set(fps, forKey: "recordingFPS"); d.set(directory, forKey: "projectDirectory")
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 0.08, green: 0.15, blue: 0.12))
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(AppTheme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct AudioMeterIcon: View {
    let microphone: Bool
    let level: Double
    let enabled: Bool
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let fill = enabled ? min(1, max(0, level)) : 0
            var inner = Path()
            if microphone {
                inner.addRoundedRect(in: CGRect(x: w * 0.33, y: h * 0.06, width: w * 0.34, height: h * 0.61), cornerSize: CGSize(width: w * 0.17, height: w * 0.17))
            } else {
                inner.move(to: CGPoint(x: w * 0.08, y: h * 0.36)); inner.addLine(to: CGPoint(x: w * 0.30, y: h * 0.36))
                inner.addLine(to: CGPoint(x: w * 0.64, y: h * 0.13)); inner.addLine(to: CGPoint(x: w * 0.64, y: h * 0.87))
                inner.addLine(to: CGPoint(x: w * 0.30, y: h * 0.64)); inner.addLine(to: CGPoint(x: w * 0.08, y: h * 0.64)); inner.closeSubpath()
            }
            let bounds = inner.boundingRect
            var clipped = context; clipped.clip(to: inner)
            clipped.fill(Path(CGRect(x: bounds.minX, y: bounds.maxY - bounds.height * fill, width: bounds.width, height: bounds.height * fill)), with: .color(AppTheme.accent))
            context.stroke(inner, with: .color(enabled ? AppTheme.ink : AppTheme.secondary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            var details = Path()
            if microphone {
                details.move(to: CGPoint(x: w * 0.20, y: h * 0.43))
                details.addCurve(to: CGPoint(x: w * 0.80, y: h * 0.43), control1: CGPoint(x: w * 0.20, y: h * 0.94), control2: CGPoint(x: w * 0.80, y: h * 0.94))
                details.move(to: CGPoint(x: w * 0.50, y: h * 0.81)); details.addLine(to: CGPoint(x: w * 0.50, y: h * 0.96))
                details.move(to: CGPoint(x: w * 0.34, y: h * 0.96)); details.addLine(to: CGPoint(x: w * 0.66, y: h * 0.96))
            } else {
                details.move(to: CGPoint(x: w * 0.80, y: h * 0.32)); details.addQuadCurve(to: CGPoint(x: w * 0.80, y: h * 0.68), control: CGPoint(x: w * 1.01, y: h * 0.50))
            }
            context.stroke(details, with: .color(enabled ? AppTheme.ink : AppTheme.secondary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }.frame(width: 25, height: 27).accessibilityLabel(microphone ? "麦克风音量" : "电脑音频音量")
            .accessibilityValue(enabled ? "\(Int(level * 100))%" : "已关闭")
    }
}
