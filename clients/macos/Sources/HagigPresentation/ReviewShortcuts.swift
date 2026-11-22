import Carbon.HIToolbox
import SwiftUI

/// The review's Copy all and Dismiss chords (`[shortcuts] copy` and `dismiss`).
/// Each falls back to its default when the setting is missing or invalid, or
/// when settings are unknown. The backend refuses a settings file in which
/// any two of the four shortcuts are equal.
public struct ReviewShortcuts: Equatable, Sendable {
    public let copy: Shortcut
    public let dismiss: Shortcut

    public static let defaults = ReviewShortcuts(copy: nil, dismiss: nil)

    public init(copy: String?, dismiss: String?) {
        // The defaults are valid by construction (ShortcutTests).
        self.copy = copy.flatMap(Shortcut.init) ?? Shortcut(Shortcut.defaultCopy)!
        self.dismiss = dismiss.flatMap(Shortcut.init) ?? Shortcut(Shortcut.defaultDismiss)!
    }

    public init(_ settings: StoredSettings?) {
        self.init(copy: settings?.copyShortcut, dismiss: settings?.dismissShortcut)
    }
}

extension Shortcut {
    /// The SwiftUI key equivalent for this key. Letters and digits are their
    /// character; punctuation its US character; F1–F12 the AppKit function-key
    /// characters (`NSF1FunctionKey` = U+F704 onwards).
    public var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "minus": return "-"
        case "equal": return "="
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "semicolon": return ";"
        default:
            if key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...12).contains(number),
               let scalar = Unicode.Scalar(0xF704 + UInt32(number - 1)) {
                return KeyEquivalent(Character(scalar))
            }
            // a–z and 0–9: the grammar admits nothing else.
            return KeyEquivalent(Character(key))
        }
    }

    public var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        return result
    }
}
