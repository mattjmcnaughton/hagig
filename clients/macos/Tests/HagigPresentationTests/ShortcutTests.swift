import SwiftUI
import XCTest
import HagigPresentation

/// Expected codes and masks are written out from Apple's Events.h values, not
/// read back from the table under test.
final class ShortcutTests: XCTestCase {
    private let control: UInt32 = 0x1000, option: UInt32 = 0x0800, shift: UInt32 = 0x0200, command: UInt32 = 0x0100

    func testDefaultsAndDisplay() throws {
        let record = try XCTUnwrap(Shortcut(Shortcut.defaultRecord))
        XCTAssertEqual(record.keyCode, 49) // kVK_Space
        XCTAssertEqual(record.modifiers, control | option)
        XCTAssertEqual(record.display, "⌃⌥Space")
        let cancel = try XCTUnwrap(Shortcut(Shortcut.defaultCancel))
        XCTAssertEqual(cancel.keyCode, 53) // kVK_Escape
        XCTAssertEqual(cancel.display, "⌃⌥Esc")
    }

    func testKeysAreUSPositionsAndModifiersAnyOrder() throws {
        let cases: [(String, UInt32, UInt32, String)] = [
            ("cmd+shift+a", 0, command | shift, "⇧⌘A"),
            ("shift+cmd+a", 0, command | shift, "⇧⌘A"),
            ("ctrl+option+cmd+shift+z", 6, control | option | shift | command, "⌃⌥⇧⌘Z"),
            ("option+0", 29, option, "⌥0"),
            ("ctrl+9", 25, control, "⌃9"),
            ("shift+f1", 122, shift, "⇧F1"),
            ("cmd+f12", 111, command, "⌘F12"),
            ("ctrl+return", 36, control, "⌃Return"),
            ("ctrl+tab", 48, control, "⌃Tab"),
            ("ctrl+slash", 44, control, "⌃/"),
            ("ctrl+semicolon", 41, control, "⌃;"),
            ("option+minus", 27, option, "⌥-"),
        ]
        for (text, code, modifiers, display) in cases {
            let shortcut = try XCTUnwrap(Shortcut(text), text)
            XCTAssertEqual(shortcut.keyCode, code, text)
            XCTAssertEqual(shortcut.modifiers, modifiers, text)
            XCTAssertEqual(shortcut.display, display, text)
        }
        XCTAssertEqual(Shortcut("ctrl+shift+r"), Shortcut("shift+ctrl+r"))
        XCTAssertNotEqual(Shortcut("ctrl+r"), Shortcut("ctrl+shift+r"))
    }

    /// The same rejections as the backend's `test_invalid_shortcuts_name_the_field`.
    func testInvalidShortcutsMirrorTheBackend() {
        for text in ["", "space", "ctrl", "ctrl+option", "ctrl+a+b", "ctrl+ctrl+a", "Ctrl+a", "ctrl+A",
                     "ctrl + a", "ctrl+", "+a", "ctrl++a", "control+a", "alt+a", "command+a", "fn+a",
                     "ctrl+f13", "ctrl+enter", "ctrl+é", "ctrl+["] {
            XCTAssertNil(Shortcut(text), text)
        }
    }

    func testHoldStopsOnReleaseAfterThreshold() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.press(at: 10, phase: .idle), .start)
        // Auto-repeat while held changes nothing.
        XCTAssertEqual(gesture.press(at: 10.2, phase: .recording), .nothing)
        XCTAssertEqual(gesture.release(at: 10.5, phase: .recording), .stop)
    }

    func testTapStartsAndTheNextPressAndReleaseStops() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.press(at: 1, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 1.2, phase: .recording), .nothing)
        XCTAssertEqual(gesture.press(at: 5, phase: .recording), .nothing)
        XCTAssertEqual(gesture.release(at: 5.05, phase: .recording), .stop)
        // Nothing is pending afterwards.
        XCTAssertEqual(gesture.release(at: 6, phase: .other), .nothing)
    }

    func testReleaseBeforeAdmissionCancels() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.press(at: 1, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 2, phase: .preparing), .cancel)
        // A tap-started request still preparing is cancelled by the next tap.
        XCTAssertEqual(gesture.press(at: 3, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 3.1, phase: .preparing), .nothing)
        XCTAssertEqual(gesture.press(at: 3.5, phase: .preparing), .nothing)
        XCTAssertEqual(gesture.release(at: 3.6, phase: .preparing), .cancel)
    }

    func testIgnoredWhileTranscribingReviewingOrAfterTheRequestEnded() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.press(at: 1, phase: .other), .nothing)
        XCTAssertEqual(gesture.release(at: 2, phase: .other), .nothing)
        // A hold whose request failed before release does nothing on release.
        XCTAssertEqual(gesture.press(at: 3, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 4, phase: .other), .nothing)
        // A tap-started request stopped another way: the next press starts anew.
        XCTAssertEqual(gesture.press(at: 5, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 5.1, phase: .recording), .nothing)
        XCTAssertEqual(gesture.press(at: 9, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 9.1, phase: .recording), .nothing)
    }
}

/// The review chords as SwiftUI key equivalents; expected characters are
/// written out (AppKit's NSF1FunctionKey is U+F704), not read from the table.
final class ReviewShortcutTests: XCTestCase {
    func testKeyEquivalentsAndModifiers() throws {
        let cases: [(String, Character, SwiftUI.EventModifiers)] = [
            (Shortcut.defaultCopy, "c", [.command, .shift]),
            (Shortcut.defaultDismiss, "d", [.command, .shift]),
            ("ctrl+option+7", "7", [.control, .option]),
            ("cmd+space", " ", [.command]),
            ("option+return", "\r", [.option]),
            ("ctrl+tab", "\t", [.control]),
            ("cmd+escape", "\u{1B}", [.command]),
            ("shift+f1", "\u{F704}", [.shift]),
            ("cmd+f12", "\u{F70F}", [.command]),
            ("cmd+minus", "-", [.command]), ("cmd+equal", "=", [.command]),
            ("cmd+comma", ",", [.command]), ("cmd+period", ".", [.command]),
            ("cmd+slash", "/", [.command]), ("cmd+semicolon", ";", [.command]),
        ]
        for (text, character, modifiers) in cases {
            let shortcut = try XCTUnwrap(Shortcut(text), text)
            XCTAssertEqual(shortcut.keyEquivalent.character, character, text)
            XCTAssertEqual(shortcut.eventModifiers, modifiers, text)
        }
    }

    func testReviewShortcutsFallBackToTheDefaults() throws {
        let copy = try XCTUnwrap(Shortcut("cmd+shift+c")), dismiss = try XCTUnwrap(Shortcut("cmd+shift+d"))
        XCTAssertEqual(ReviewShortcuts(nil).copy, copy)
        XCTAssertEqual(ReviewShortcuts(nil).dismiss, dismiss)
        let invalid = ReviewShortcuts(copy: "not+a+chord", dismiss: "ctrl")
        XCTAssertEqual(invalid, .defaults)
        let configured = ReviewShortcuts(StoredSettings(modelId: "m", copyShortcut: "option+return",
                                                        dismissShortcut: "ctrl+f5"))
        XCTAssertEqual(configured.copy.display, "⌥Return")
        XCTAssertEqual(configured.dismiss.display, "⌃F5")
    }
}
