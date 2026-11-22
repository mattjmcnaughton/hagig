import AppKit
import Carbon.HIToolbox
import HagigPresentation

enum ShortcutName: UInt32 { case record = 1, cancel = 2 }

/// "Hgig": marks this app's hot keys in Carbon events.
private let hotKeySignature: OSType = 0x4867_6967

/// The record and cancel shortcuts, through Carbon's hot-key API. It needs no
/// Accessibility or Input Monitoring permission, sees only these two chords,
/// and reports both press and release to this app; it never reads other keys.
@MainActor
final class GlobalShortcuts {
    private var refs: [ShortcutName: EventHotKeyRef] = [:]
    private var current: [ShortcutName: Shortcut] = [:]
    private var handler: EventHandlerRef?
    private let received: (ShortcutName, _ pressed: Bool) -> Void

    init(received: @escaping (ShortcutName, _ pressed: Bool) -> Void) {
        self.received = received
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The app's event target delivers on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == OSStatus(noErr), id.signature == hotKeySignature,
                  let name = ShortcutName(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcuts.received(name, pressed) }
            return OSStatus(noErr)
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Registers both, replacing the previous pair. Returns the ones that could
    /// not be registered (another app holds the chord).
    func register(record: Shortcut, cancel: Shortcut) -> [Shortcut] {
        let wanted: [ShortcutName: Shortcut] = [.record: record, .cancel: cancel]
        if wanted == current, refs.count == wanted.count { return [] }
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        current = wanted
        var failed: [Shortcut] = []
        for name in [ShortcutName.record, .cancel] {
            guard let shortcut = wanted[name] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: hotKeySignature, id: name.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == OSStatus(noErr), let ref { refs[name] = ref } else { failed.append(shortcut) }
        }
        return failed
    }
}

/// A nonactivating panel that can still become key, so review takes typing
/// while the user's application stays frontmost. Ordered with
/// `orderFrontRegardless` it shows without becoming key at all.
final class ShortcutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
