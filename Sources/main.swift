import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--audio-monitor-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    _ = NSApplication.shared
    Task { @MainActor in
        do { try await AudioMonitorSelfTest.run(directory: output); exit(0) }
        catch { fputs("AUDIO MONITOR TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--window-capture-self-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    _ = NSApplication.shared
    Task { @MainActor in
        do { try await WindowCaptureSelfTest.run(directory: output); exit(0) }
        catch { fputs("WINDOW CAPTURE TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--project-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { @MainActor in
        do { try await ProjectSelfTest.run(directory: output); exit(0) }
        catch { fputs("PROJECT TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--pause-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { @MainActor in
        do { try await PauseSelfTest.run(directory: output); exit(0) }
        catch { fputs("PAUSE TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--export-size-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { @MainActor in
        do { try await ExportSizeSelfTest.run(directory: output); exit(0) }
        catch { fputs("EXPORT SIZE TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--permission-test") {
    do { try PermissionSelfTest.run() }
    catch { fputs("PERMISSION TEST FAILED: \(error)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--zoom-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { @MainActor in
        do { try await AutoZoomSelfTest.run(directory: output); exit(0) }
        catch { fputs("ZOOM TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--selection-test") {
    _ = NSApplication.shared
    Task { @MainActor in
        do {
            try SelectionInteractionSelfTest.run()
            try await SelectionInteractionSelfTest.checkUnchangedDisplayNotification()
            try await SourceMenuSelfTest.run()
            exit(0)
        }
        catch { fputs("SELECTION TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--geometry-test") {
    do { try GeometrySelfTest.run() }
    catch { fputs("GEOMETRY TEST FAILED: \(error)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > index + 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task {
        do {
            try await MediaSelfTest.run(directory: output)
            exit(0)
        } catch {
            fputs("SELF-TEST FAILED: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
