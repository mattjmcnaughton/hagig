import Carbon.HIToolbox
import Foundation

/// A global shortcut from the settings file (`[shortcuts]`), as Carbon's
/// `RegisterEventHotKey` takes it. The grammar mirrors `backend/src/hagig/config.py`
/// exactly: lowercase tokens joined by `+`, one or more distinct modifiers from
/// `cmd`, `ctrl`, `option` and `shift` in any order, and exactly one key. Keys
/// are physical positions on a US layout (macOS virtual key codes).
public struct Shortcut: Equatable, Hashable, Sendable {
    public static let defaultRecord = "ctrl+option+space"
    public static let defaultCancel = "ctrl+option+escape"

    /// The macOS virtual key code.
    public let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public let modifiers: UInt32
    /// For example `⌃⌥Space`.
    public let display: String

    /// Nil when `text` is not a valid shortcut.
    public init?(_ text: String) {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let named = tokens.filter { Self.modifierMasks[$0] != nil }
        let keys = tokens.filter { Self.modifierMasks[$0] == nil }
        guard !named.isEmpty, Set(named).count == named.count, keys.count == 1,
              let key = Self.keys[keys[0]] else { return nil }
        keyCode = UInt32(key.code)
        modifiers = named.reduce(0) { $0 | (Self.modifierMasks[$1] ?? 0) }
        // Apple's order: Control, Option, Shift, Command.
        let symbols = [("ctrl", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { named.contains($0.0) }.map { $0.1 }.joined()
        display = symbols + key.label
    }

    private static let modifierMasks: [String: UInt32] = [
        "cmd": UInt32(cmdKey), "ctrl": UInt32(controlKey),
        "option": UInt32(optionKey), "shift": UInt32(shiftKey),
    ]

    private static let keys: [String: (code: Int, label: String)] = {
        var table: [String: (code: Int, label: String)] = [:]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
            table[String(letter)] = (code, String(letter).uppercased())
        }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { table[String(digit)] = (code, String(digit)) }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                         kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functions.enumerated() { table["f\(index + 1)"] = (code, "F\(index + 1)") }
        let named: [(String, Int, String)] = [
            ("space", kVK_Space, "Space"), ("return", kVK_Return, "Return"), ("tab", kVK_Tab, "Tab"),
            ("escape", kVK_Escape, "Esc"), ("minus", kVK_ANSI_Minus, "-"), ("equal", kVK_ANSI_Equal, "="),
            ("comma", kVK_ANSI_Comma, ","), ("period", kVK_ANSI_Period, "."), ("slash", kVK_ANSI_Slash, "/"),
            ("semicolon", kVK_ANSI_Semicolon, ";"),
        ]
        for (name, code, label) in named { table[name] = (code, label) }
        return table
    }()
}

/// What one press or release of the record shortcut means. Holding it
/// (released at least `holdThreshold` after the press that started) is
/// push-to-talk; a shorter tap leaves recording on until the next press and
/// release. Pure: the shell feeds it events with timestamps and acts on the
/// answer.
public struct ShortcutGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Ready, cancelled or no speech: a press may start a request.
        case idle
        /// Awaiting admission: nothing is captured yet.
        case preparing
        case recording
        /// Transcribing, reviewing or an issue: the shortcut does nothing.
        case other
    }

    public enum Action: Equatable, Sendable { case nothing, start, stop, cancel }

    public static let holdThreshold: TimeInterval = 0.35

    /// When the press that started the current request went down, until its release.
    private var startedAt: TimeInterval?
    /// A later press during a tap-started request; its release stops.
    private var stopping = false

    public init() {}

    public mutating func press(at time: TimeInterval, phase: Phase) -> Action {
        switch phase {
        case .idle:
            startedAt = time
            stopping = false
            return .start
        case .preparing, .recording:
            // A repeated press while the starting one is still held changes nothing.
            if startedAt == nil { stopping = true }
            return .nothing
        case .other:
            startedAt = nil
            stopping = false
            return .nothing
        }
    }

    public mutating func release(at time: TimeInterval, phase: Phase) -> Action {
        if let started = startedAt {
            startedAt = nil
            guard time - started >= Self.holdThreshold else { return .nothing }
            return Self.end(phase)
        }
        guard stopping else { return .nothing }
        stopping = false
        return Self.end(phase)
    }

    private static func end(_ phase: Phase) -> Action {
        switch phase {
        case .recording: return .stop
        case .preparing: return .cancel // Nothing was captured.
        case .idle, .other: return .nothing
        }
    }
}
