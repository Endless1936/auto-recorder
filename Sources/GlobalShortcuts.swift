import AppKit
import Carbon

@MainActor
final class GlobalShortcuts {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    private let onRecord: () -> Void
    private let onPause: () -> Void
    init(onRecord: @escaping () -> Void, onPause: @escaping () -> Void) {
        self.onRecord = onRecord; self.onPause = onPause
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let instance = Unmanaged<GlobalShortcuts>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { if identifier.id == 1 { instance.onRecord() } else { instance.onPause() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (key, id) in [(UInt32(kVK_ANSI_R), UInt32(1)), (UInt32(kVK_ANSI_P), UInt32(2))] {
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4c524543, id: id), GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference { keys.append(reference) }
        }
    }
    deinit {
        for reference in keys { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
