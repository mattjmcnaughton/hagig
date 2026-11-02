import AppKit
import SwiftUI
import XCTest
@testable import HagigPresentation

final class EditorTests: XCTestCase {
    @MainActor private func editor(_ text: String, mode: EditorMode = .vim) -> ReviewTextView {
        _ = NSApplication.shared
        let view = ReviewTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        view.configure(text: text, mode: mode, write: { _ in false }, changed: { _ in }, modeChanged: { _ in })
        return view
    }

    @MainActor private func keys(_ text: String, in view: ReviewTextView,
                                 modifiers: NSEvent.ModifierFlags = []) {
        for character in text {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false,
                keyCode: character == "\r" ? 36 : 0)!
            view.keyDown(with: event)
            // Real key events have run-loop boundaries; let native undo close
            // event groups instead of accidentally testing one synthetic event.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    func testModesInsertEscapeEnterAndNativeStandardEditing() async {
        await MainActor.run {
            let view = editor("ab")
            XCTAssertEqual(view.modeLabel, "Vim · Normal")
            keys("i", in: view)
            XCTAssertEqual(view.modeLabel, "Vim · Insert")
            view.insertText("X\n", replacementRange: view.selectedRange())
            keys("\r", in: view)
            keys("\u{1b}", in: view)
            XCTAssertEqual(view.string, "X\n\nab")
            XCTAssertEqual(view.modeLabel, "Vim · Normal")
            keys("\r", in: view)
            XCTAssertEqual(view.string, "X\n\nab")
            keys("ga", in: view) // unsupported g-prefix is consumed; does not insert
            keys("a", in: view)
            XCTAssertEqual(view.modeLabel, "Vim · Insert")
            let standard = editor("seed", mode: .standard)
            standard.setSelectedRange(NSRange(location: 4, length: 0))
            standard.insertText("\n😀", replacementRange: standard.selectedRange())
            keys("\u{1b}", in: standard)
            XCTAssertEqual(standard.string, "seed\n😀")
            XCTAssertEqual(standard.modeLabel, "Standard")
        }
    }

    func testEveryMotionCountsAndVisualUnicodeBounds() async {
        await MainActor.run {
            let view = editor("one two!\nthree four\nfive")
            let cases: [(String, Int)] = [("l", 1), ("h", 0), ("w", 4), ("e", 6),
                ("b", 4), ("0", 0), ("$", 7), ("j", 16), ("k", 7),
                ("gg", 0), ("2w", 7), ("G", 20), ("2gg", 9), ("3G", 20)]
            for (command, offset) in cases {
                keys(command, in: view)
                XCTAssertEqual(view.selectedRange(), NSRange(location: offset, length: 0), command)
            }
            let unicode = editor("a👩🏽‍💻e\u{301}\n日本語")
            keys("lvll", in: unicode)
            XCTAssertEqual((unicode.string as NSString).substring(with: unicode.selectedRange()), "👩🏽‍💻e\u{301}\n")
            XCTAssertEqual(unicode.modeLabel, "Vim · Visual")
            keys("\u{1b}ggVj", in: unicode)
            XCTAssertEqual(unicode.selectedRange(), NSRange(location: 0, length: (unicode.string as NSString).length))
            XCTAssertEqual(unicode.modeLabel, "Vim · Visual line")
            keys("\u{1b}", in: unicode)
            XCTAssertEqual(unicode.selectedRange().length, 0)
        }
    }

    func testDeletesRegisterPasteAndUndoRedo() async {
        await MainActor.run {
            let view = editor("one two\nthree\nfour")
            keys("dw", in: view)
            XCTAssertEqual(view.string, "two\nthree\nfour")
            keys("u", in: view)
            XCTAssertEqual(view.string, "one two\nthree\nfour")
            keys("r", in: view, modifiers: .control)
            XCTAssertEqual(view.string, "two\nthree\nfour")
            keys("cw", in: view)
            XCTAssertEqual(view.string, "\nthree\nfour")
            XCTAssertEqual(view.modeLabel, "Vim · Insert")
            keys("\u{1b}ggdd", in: view)
            XCTAssertEqual(view.string, "three\nfour")
            keys("p", in: view)
            XCTAssertEqual(view.string, "three\n\nfour")
            keys("ggyyGp", in: view)
            XCTAssertEqual(view.string, "three\n\nfour\nthree\n")
            let counted = editor("a😀bc\ntwo\nthree\nfour")
            keys("l2x", in: counted)
            XCTAssertEqual(counted.string, "ac\ntwo\nthree\nfour")
            keys("gg2dd", in: counted)
            XCTAssertEqual(counted.string, "three\nfour")
            keys("2yyGp", in: counted)
            XCTAssertEqual(counted.string, "three\nfour\nthree\nfour\n")
            let words = editor("one two three four")
            keys("2dw", in: words)
            XCTAssertEqual(words.string, "three four")
            let changes = editor("one two three")
            keys("2cw", in: changes)
            XCTAssertEqual(changes.string, " three")
            let boundary = editor("one two")
            keys("2lcw", in: boundary)
            XCTAssertEqual(boundary.string, "on two")
        }
    }

    func testCountedMotionsCharacterRegisterAndHistory() async {
        await MainActor.run {
            let motion = editor("abcd\nefgh\nijkl")
            let cases: [(String, Int)] = [("2l", 2), ("2j", 12), ("2k", 2),
                ("2h", 0), ("2$", 8), ("gg2e", 8), ("2b", 0)]
            for (command, offset) in cases {
                keys(command, in: motion)
                XCTAssertEqual(motion.selectedRange().location, offset, command)
            }
            let view = editor("a😀bc")
            keys("lxp", in: view)
            XCTAssertEqual(view.string, "ab😀c")
            keys("ggxx", in: view)
            XCTAssertEqual(view.string, "😀c")
            keys("2u", in: view)
            XCTAssertEqual(view.string, "ab😀c")
            keys("2", in: view)
            keys("r", in: view, modifiers: .control)
            XCTAssertEqual(view.string, "😀c")
            let visual = editor("a😀bc\nnext")
            keys("lv lx", in: visual) // space is unsupported, selection remains Unicode-safe
            XCTAssertEqual(visual.string, "ac\nnext")
        }
    }

    func testNormalCursorAtDeletionAndEmptyLineBoundaries() async {
        await MainActor.run {
            for input in ["ab", "ab\nnext", "a😀\nnext"] {
                let view = editor(input)
                keys("lx", in: view)
                XCTAssertEqual(view.selectedRange().location, 0, input)
                keys("x", in: view)
                XCTAssertEqual(view.string, input.contains("\n") ? "\nnext" : "", input)
                keys("u", in: view)
                XCTAssertEqual(view.selectedRange().location, 0, input)
                keys("r", in: view, modifiers: .control)
                XCTAssertEqual(view.selectedRange().location, 0, input)
            }
            let change = editor("ab\nnext")
            keys("lcw", in: change)
            change.insertText("X", replacementRange: change.selectedRange())
            XCTAssertEqual(change.string, "aX\nnext")
            for input in ["\nnext", ""] {
                let view = editor(input)
                keys("a", in: view)
                view.insertText("X", replacementRange: view.selectedRange())
                XCTAssertEqual(view.string, "X" + input)
            }
            let paste = editor("z\n\nnext")
            keys("xjp", in: paste)
            XCTAssertEqual(paste.string, "\nz\nnext")
            for (input, expected) in [("a\n", 2), ("a", 0), ("a\n\n", 3)] {
                let view = editor(input)
                keys("9j", in: view)
                XCTAssertEqual(view.selectedRange().location, expected, input)
                keys("gg9$", in: view)
                XCTAssertEqual(view.selectedRange().location, expected, input)
            }
        }
    }

    func testNativeKillCommandsCannotExportDiscardedText() async {
        await MainActor.run {
            // Observe an ordinary NSTextView, not just the guarded replacement:
            // disabling yank in Hagig alone must not mask a shared kill-buffer write.
            let receiver = NSTextView(frame: .zero)
            let control = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
            control.string = "ordinary synthetic kill control"
            control.setSelectedRange(NSRange(location: 0, length: 0))
            control.deleteToEndOfParagraph(nil)
            receiver.yank(nil)
            let priorKill = receiver.string
            XCTAssertEqual(priorKill, "ordinary synthetic kill control",
                           "Positive control must detect native kill-buffer export")
            for mode in EditorMode.allCases {
                for action in [#selector(NSTextView.deleteToEndOfParagraph(_:)),
                               #selector(NSTextView.deleteToBeginningOfParagraph(_:)),
                               #selector(NSTextView.deleteToEndOfLine(_:)),
                               #selector(NSTextView.deleteToBeginningOfLine(_:)),
                               #selector(NSTextView.deleteToMark(_:))] {
                    let view = editor("synthetic private canary", mode: mode)
                    view.setMark(nil)
                    view.setSelectedRange(NSRange(location: 10, length: 0))
                    view.doCommand(by: action)
                    XCTAssertNotEqual(view.string, "synthetic private canary")
                    view.discard()
                    receiver.string = ""
                    receiver.yank(nil)
                    XCTAssertEqual(receiver.string, priorKill, NSStringFromSelector(action))
                    let fresh = editor("next request", mode: mode)
                    fresh.yank(nil)
                    fresh.doCommand(by: NSSelectorFromString("yankAndSelect:"))
                    XCTAssertEqual(fresh.string, "next request")
                }
            }
            // Preserve native Ctrl-K semantics at paragraph boundaries without
            // calling the native kill implementation on review content.
            for input in ["a\nb", "a\r\nb", "a\nb\nc"] {
                let view = editor(input, mode: .standard)
                control.string = input
                view.setSelectedRange(NSRange(location: 1, length: 0))
                control.setSelectedRange(NSRange(location: 1, length: 0))
                control.deleteToEndOfParagraph(nil)
                receiver.string = ""
                receiver.yank(nil)
                let nativeKill = receiver.string
                view.deleteToEndOfParagraph(nil)
                XCTAssertEqual(view.string, input == "a\nb\nc" ? "ab\nc" : "ab")
                XCTAssertEqual(view.string, control.string,
                               "Input: \(input.debugDescription); native: \(control.string.debugDescription)")
                receiver.string = ""
                receiver.yank(nil)
                XCTAssertEqual(receiver.string, nativeKill)
                if input == "a\nb\nc" {
                    view.deleteToEndOfParagraph(nil)
                    XCTAssertEqual(view.string, "a\nc")
                    view.deleteToEndOfParagraph(nil)
                    XCTAssertEqual(view.string, "ac")
                }
            }
        }
    }

    func testSharedSurfaceEditedCopyAndImmediateDismissDiscard() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let writer = LocalClipboard(pasteboard: board)
            XCTAssertTrue(writer.write("existing"))
            let model = Presentation(editorMode: .vim)
            model.begin(); model.release()
            model.complete(requestID: model.requestID!, text: "synthetic")
            let hosting = NSHostingView(rootView: HagigView(presentation: model, copy: writer.write))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 500),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            @MainActor func textView(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.lazy.compactMap { textView(in: $0) }.first
            }
            let text = try XCTUnwrap(textView(in: hosting) as? ReviewTextView)
            XCTAssertEqual(board.string(forType: .string), "existing")
            text.selectAll(nil)
            text.insertText("edited 😀", replacementRange: text.selectedRange())
            XCTAssertEqual(model.transcript, "edited 😀")
            keys("\u{1b}", in: text)
            XCTAssertEqual(model.stage, .fallback)
            text.copyAll(nil)
            XCTAssertEqual(board.string(forType: .string), "edited 😀")
            XCTAssertTrue(model.copied)
            model.reset() // real shared editor must clear synchronously, not on a later render
            XCTAssertEqual(text.string, "")
            XCTAssertFalse(text.undoManager?.canUndo ?? true)
            XCTAssertEqual(board.string(forType: .string), "edited 😀")
        }
    }

    func testClipboardResponderActionsAndEmptyBufferUseActualPasteboard() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let writer = LocalClipboard(pasteboard: board)
            XCTAssertTrue(writer.write("untouched"))
            let view = editor("one 😀 two")
            view.write = writer.write
            keys("yy", in: view)
            XCTAssertEqual(board.string(forType: .string), "untouched")
            view.selectAll(nil)
            XCTAssertFalse(view.writeSelection(to: board, type: .string))
            XCTAssertFalse(view.writeSelection(to: board, types: [.string]))
            XCTAssertEqual(board.string(forType: .string), "untouched")
            view.copy(nil) // context-menu/responder action
            XCTAssertEqual(board.string(forType: .string), view.string)
            view.setSelectedRange(NSRange(location: 0, length: 3))
            keys("c", in: view, modifiers: .command)
            XCTAssertEqual(board.string(forType: .string), "one")
            keys("x", in: view, modifiers: .command)
            XCTAssertEqual(view.string, " 😀 two")
            keys("C", in: view, modifiers: [.command, .shift])
            XCTAssertEqual(board.string(forType: .string), " 😀 two")
            view.selectAll(nil)
            view.cut(nil)
            XCTAssertEqual(view.string, "")
            let saved = board.string(forType: .string)
            view.copy(nil)
            view.copyAll(nil)
            XCTAssertEqual(board.string(forType: .string), saved)
            keys("ddwbe0$ggGxpu", in: view)
            XCTAssertEqual(board.string(forType: .string), saved)
        }
    }

    func testLongMultilineNativeSelectionUnicodeCutAndFailedCut() async {
        await MainActor.run {
            let text = String(repeating: "Synthetic line 😀 e\u{301} 日本語\n", count: 200)
            let view = editor(text, mode: .standard)
            keys("a", in: view, modifiers: .command)
            XCTAssertEqual(view.selectedRange().length, text.utf16.count)
            view.cut(nil) // rejected writer must preserve text
            XCTAssertEqual(view.string, text)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let writer = LocalClipboard(pasteboard: board)
            view.write = writer.write
            view.setSelectedRange((text as NSString).range(of: "😀 e\u{301}"))
            view.cut(nil)
            XCTAssertEqual(board.string(forType: .string), "😀 e\u{301}")
            XCTAssertTrue(view.string.hasPrefix("Synthetic line  日本語"))
            keys("z", in: view, modifiers: .command)
            XCTAssertEqual(view.string, text)
            keys("Z", in: view, modifiers: [.command, .shift])
            XCTAssertTrue(view.string.hasPrefix("Synthetic line  日本語"))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertTrue(view.string.hasPrefix("😀 e\u{301}Synthetic line"))
            XCTAssertFalse(writer.write(""))
            XCTAssertEqual(board.string(forType: .string), "😀 e\u{301}")
        }
    }

    func testEditedCopyFeedbackAndSessionInvalidation() async {
        await MainActor.run {
            let model = Presentation(editorMode: .vim)
            model.begin(); model.release()
            model.complete(requestID: model.requestID!, text: "original")
            let session = model.editorID
            model.edit("edited\n😀", session: session)
            var copied = ""
            model.copy { copied = $0; return true }
            XCTAssertEqual(copied, "edited\n😀")
            XCTAssertTrue(model.copied)
            model.edit("", session: session)
            XCTAssertFalse(model.copied)
            model.copy { copied = $0; return true }
            XCTAssertEqual(copied, "edited\n😀")
            model.reset()
            model.edit("late", session: session)
            XCTAssertNil(model.transcript)
            model.begin(); model.release()
            model.complete(requestID: model.requestID!, text: "new")
            model.edit("old", session: session)
            XCTAssertEqual(model.transcript, "new")
            let view = editor("private")
            keys("dd", in: view)
            view.discard()
            keys("pu", in: view)
            XCTAssertEqual(view.string, "")
            XCTAssertFalse(view.undoManager?.canUndo ?? true)
        }
    }
}
