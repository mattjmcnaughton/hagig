import AppKit
import SwiftUI

public enum EditorMode: String, CaseIterable {
    case standard, vim
}

/// The only production clipboard writer. Empty writes never clear user content.
@MainActor
public struct LocalClipboard {
    private let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public func write(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.setString(text, forType: .string)
    }
}

/// Shared by the shell and native rendering harness. Each review gets a new identity.
@MainActor
struct ReviewEditor: NSViewRepresentable {
    let presentation: Presentation
    let write: (String) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let text = ReviewTextView(frame: scroll.bounds)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                 height: CGFloat.greatestFiniteMagnitude)
        let session = presentation.editorID
        text.configure(text: presentation.transcript ?? "", mode: presentation.editorMode,
            write: { presentation.copySelection($0, session: session, using: write) },
            changed: { presentation.edit($0, session: session) },
            modeChanged: { presentation.updateEditorLabel($0, session: session) })
        presentation.attachEditor(session: session, discard: { [weak text] in text?.discard() })
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    static func dismantleNSView(_ view: NSScrollView, coordinator: ()) {
        (view.documentView as? ReviewTextView)?.discard()
    }
}

/// Native text editing first; only the bounded TDD §8 Vim keys are translated.
/// Positions are extended grapheme indices, converted to UTF-16 only at AppKit's
/// selection/replacement boundary. Register and undo never leave this review.
@MainActor
final class ReviewTextView: NSTextView, NSTextViewDelegate {
    private enum Mode { case normal, insert, visual, visualLine }
    private enum Operator: String { case go = "g", delete = "d", change = "c", yank = "y" }
    private var editingMode = EditorMode.standard
    private var mode = Mode.normal
    private var register = ""
    private var lineRegister = false
    private var count: Int?
    private var pending: (operation: Operator, count: Int)?
    private var anchor = 0
    private var head = 0
    private var characters: [Character] = []
    private var boundaries = [0]
    private let history = UndoManager()
    private var changed: (String) -> Void = { _ in }
    private var modeChanged: (String) -> Void = { _ in }
    var write: (String) -> Bool = { _ in false }

    override var undoManager: UndoManager? { history }
    // An explicit click should enter review even before the popover is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var modeLabel: String {
        guard editingMode == .vim else { return "Standard" }
        switch mode {
        case .normal: return "Vim · Normal"
        case .insert: return "Vim · Insert"
        case .visual: return "Vim · Visual"
        case .visualLine: return "Vim · Visual line"
        }
    }

    func configure(text: String, mode: EditorMode, write: @escaping (String) -> Bool,
                   changed: @escaping (String) -> Void, modeChanged: @escaping (String) -> Void) {
        discard()
        editingMode = mode
        self.write = write
        self.changed = changed
        self.modeChanged = modeChanged
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        usesFindPanel = false
        isIncrementalSearchingEnabled = false
        font = .systemFont(ofSize: 14)
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 10, height: 12)
        setAccessibilityLabel("Transcript editor")
        string = text
        indexText()
        setSelectedRange(NSRange(location: 0, length: 0))
        delegate = self
        modeChanged(modeLabel)
    }

    func discard() {
        delegate = nil
        register = ""
        lineRegister = false
        count = nil; pending = nil
        mode = .normal; anchor = 0; head = 0
        string = ""
        history.removeAllActions()
        characters = []; boundaries = [0]
        write = { _ in false }; changed = { _ in }; modeChanged = { _ in }
    }

    func textDidChange(_ notification: Notification) { indexText(); changed(string) }

    // No alternate drag/Services/rich-text exporter. Copy/Cut below are the only
    // enabled selection exports, through the presentation's guarded writer.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))),
                                ("Copy all", #selector(copyAll(_:))), ("Paste", #selector(paste(_:))),
                                ("Select all", #selector(selectAll(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) {
            return safeSelection().length > 0
        }
        if item.action == #selector(copyAll(_:)) { return !string.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    // Both key equivalents and menu/context-menu actions converge here. Never
    // call NSTextView's default copy/cut, which would bypass currentHostOnly.
    override func copy(_ sender: Any?) { _ = copySelection() }
    override func cut(_ sender: Any?) {
        let range = safeSelection()
        guard range.length > 0, copySelection() else { return }
        replace(range, with: "")
        if mode == .visual || mode == .visualLine {
            mode = .normal
            count = nil; pending = nil
            modeChanged(modeLabel)
        }
        normalCursor()
    }
    @objc func copyAll(_ sender: Any?) {
        guard !string.isEmpty else { return }
        _ = write(string)
    }
    private func copySelection() -> Bool {
        let range = safeSelection()
        guard range.length > 0 else { return false }
        return write((string as NSString).substring(with: range))
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let accepted = super.readSelection(from: pasteboard, type: type)
        if accepted, mode == .visual || mode == .visualLine {
            mode = .normal
            count = nil; pending = nil
            modeChanged(modeLabel)
        }
        if accepted { normalCursor() }
        return accepted
    }

    // AppKit's line/paragraph/mark deletions otherwise populate a shared kill
    // buffer outside this review's lifetime. Keep deletion/undo native, but do
    // not call those superclass deletion implementations or import their yank.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteWithoutKill { super.moveToBeginningOfLineAndModifySelection(sender) }
    }
    override func deleteToEndOfLine(_ sender: Any?) {
        deleteWithoutKill { super.moveToEndOfLineAndModifySelection(sender) }
    }
    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleteWithoutKill { super.moveToBeginningOfParagraphAndModifySelection(sender) }
    }
    override func deleteToEndOfParagraph(_ sender: Any?) {
        deleteWithoutKill {
            let p = position
            // Ctrl-K at paragraph end removes the terminator, not an empty
            // selection. Select the whole grapheme (including CRLF) locally.
            if p < characters.count && characters[p].isNewline {
                setSelectedRange(range(p, p + 1))
            } else {
                super.moveToEndOfParagraphAndModifySelection(sender)
            }
        }
    }
    override func deleteToMark(_ sender: Any?) {
        deleteWithoutKill { super.selectToMark(sender) }
    }
    private func deleteWithoutKill(select: () -> Void) {
        if selectedRange().length == 0 { select() }
        let selection = safeSelection()
        if selection.length > 0 { replace(selection, with: "") }
        normalCursor()
    }
    override func yank(_ sender: Any?) {}
    override func doCommand(by selector: Selector) {
        // Apple documents this alternate kill-ring binding but omits it from
        // public headers. Never forward it to the inherited implementation.
        if selector == NSSelectorFromString("yankAndSelect:") { return }
        super.doCommand(by: selector)
    }

    private func command(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            if flags.contains(.shift) { copyAll(nil) } else { copy(nil) }
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "v": paste(nil)
        case "z":
            if flags.contains(.shift) { history.redo() } else { history.undo() }
            normalCursor()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if command(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if command(event) { return }
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "\u{1b}" { escape(); return }
        if editingMode == .standard || mode == .insert { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.control) {
            if key == "r" {
                let n = count ?? 1
                count = nil; pending = nil
                for _ in 0..<n { history.redo() }
                normalCursor()
            }
            return
        }
        guard !event.modifierFlags.contains(.option) else { return }
        vim(key)
    }

    override func cancelOperation(_ sender: Any?) { escape() }

    private func escape() {
        count = nil; pending = nil
        if editingMode == .vim {
            if mode == .insert { head = max(lineStart(position), position - 1) }
            else if mode == .normal { head = position }
            mode = .normal
            select(head)
            breakUndoCoalescing()
            modeChanged(modeLabel)
        }
        // Standard Escape is deliberately inert, never Dismiss/Cancel.
    }

    private func indexText() {
        characters = Array(string)
        boundaries = [0]
        for character in characters { boundaries.append(boundaries.last! + String(character).utf16.count) }
    }
    private var position: Int {
        let offset = min(selectedRange().location, (string as NSString).length)
        return boundaries.lastIndex(where: { $0 <= offset }) ?? 0
    }
    private func safeSelection() -> NSRange {
        let offsets = boundaries
        let selection = selectedRange()
        let start = offsets.last(where: { $0 <= selection.location }) ?? 0
        guard selection.length > 0 else { return NSRange(location: start, length: 0) }
        let end = offsets.first(where: { $0 >= min(NSMaxRange(selection), offsets.last!) }) ?? offsets.last!
        return NSRange(location: start, length: end - start)
    }
    private func range(_ start: Int, _ end: Int) -> NSRange {
        let offsets = boundaries
        let a = offsets[max(0, min(start, offsets.count - 1))]
        let b = offsets[max(0, min(end, offsets.count - 1))]
        return NSRange(location: min(a, b), length: abs(b - a))
    }
    private func select(_ target: Int) {
        head = max(0, min(target, characters.count))
        if mode == .normal {
            head = min(head, max(lineStart(head), lineEnd(head) - 1))
        }
        if mode == .visual {
            setSelectedRange(range(min(anchor, head), min(characters.count, max(anchor, head) + 1)))
        } else if mode == .visualLine {
            setSelectedRange(range(lineStart(min(anchor, head)), lineAfter(max(anchor, head))))
        } else {
            setSelectedRange(range(head, head))
        }
        scrollRangeToVisible(selectedRange())
    }
    private func normalCursor() {
        if editingMode == .vim && mode == .normal {
            // Native undo may update text before its delegate notification.
            // Cursor normalization must use the current buffer, not that cache.
            indexText()
            select(position)
        }
    }
    private func replace(_ range: NSRange, with text: String) {
        breakUndoCoalescing()
        // NSTextView owns native undo, notifications and accessibility editing.
        super.insertText(text, replacementRange: range)
        breakUndoCoalescing()
    }
    private func lineStart(_ p: Int) -> Int {
        let chars = characters
        var i = min(p, chars.count)
        while i > 0 && !chars[i - 1].isNewline { i -= 1 }
        return i
    }
    private func lineEnd(_ p: Int) -> Int {
        let chars = characters
        var i = min(p, chars.count)
        while i < chars.count && !chars[i].isNewline { i += 1 }
        return i
    }
    private func lineAfter(_ p: Int) -> Int { min(characters.count, lineEnd(p) + 1) }
    private func kind(_ c: Character) -> Int {
        if c.isWhitespace { return 0 }
        return c.isLetter || c.isNumber || c == "_" ? 1 : 2
    }
    private func word(_ p: Int, direction: String) -> Int {
        let chars = characters
        guard !chars.isEmpty else { return 0 }
        var i = min(p, chars.count)
        if direction == "b" {
            i = max(0, i - 1)
            while i > 0 && kind(chars[i]) == 0 { i -= 1 }
            while i > 0 && kind(chars[i - 1]) == kind(chars[i]) { i -= 1 }
        } else if direction == "e" {
            i = min(chars.count - 1, i + 1)
            while i < chars.count - 1 && kind(chars[i]) == 0 { i += 1 }
            while i < chars.count - 1 && kind(chars[i + 1]) == kind(chars[i]) { i += 1 }
        } else {
            guard i < chars.count else { return chars.count }
            let current = kind(chars[i])
            while i < chars.count && kind(chars[i]) == current { i += 1 }
            while i < chars.count && kind(chars[i]) == 0 { i += 1 }
        }
        return i
    }
    private func motion(_ key: String, from start: Int, count n: Int, explicit: Bool) -> Int? {
        let size = characters.count
        var p = start
        switch key {
        case "h": p = max(lineStart(p), p - n)
        case "l":
            // Visual may include a line terminator; Normal stops on the last character.
            let end = mode == .visual ? lineEnd(p) : max(lineStart(p), lineEnd(p) - 1)
            p = min(end, p + n)
        case "j", "k":
            let column = p - lineStart(p)
            for _ in 0..<n {
                if key == "k" && lineStart(p) == 0 { break }
                if key == "j" && lineEnd(p) == size { break }
                let next = key == "j" ? lineAfter(p) : lineStart(max(0, lineStart(p) - 1))
                p = min(next + column, max(next, lineEnd(next) - 1))
            }
        case "w", "b", "e": for _ in 0..<n { p = word(p, direction: key) }
        case "0": p = lineStart(p)
        case "$":
            for _ in 1..<n {
                if lineEnd(p) == size { break }
                let next = lineAfter(p)
                p = next
            }
            p = max(lineStart(p), lineEnd(p) - 1)
        case "gg", "G":
            if key == "G" && !explicit { p = lineStart(size) }
            else {
                p = 0
                for _ in 1..<n { p = lineAfter(p) }
            }
        default: return nil
        }
        return min(p, size)
    }

    private func wordEditRange(from p: Int, count repetitions: Int, operation: Operator) -> NSRange {
        var end = p
        for iteration in 0..<repetitions {
            if operation == .change, iteration == 0, end < characters.count, kind(characters[end]) != 0 {
                let current = kind(characters[end])
                while end < characters.count && kind(characters[end]) == current { end += 1 }
            } else if operation == .change, iteration > 0 {
                end = min(characters.count, word(max(p, end - 1), direction: "e") + 1)
            } else {
                let start = end
                end = word(end, direction: "w")
                // Final dw preserves its word's terminator; intermediate
                // counted steps and a start on an empty line still cross.
                if operation == .delete, iteration == repetitions - 1,
                   start < characters.count, !characters[start].isNewline {
                    end = min(end, lineEnd(start))
                }
            }
        }
        return range(p, end)
    }

    private func vim(_ key: String) {
        if key.count == 1, let digit = key.first, digit.isASCII && digit.isNumber,
           key != "0" || count != nil {
            // Bound hostile/accidental counts and work per key; no integer overflow.
            count = min(9999, (count ?? 0) * 10 + (digit.wholeNumberValue ?? 0))
            return
        }
        let explicit = count != nil
        let n = count ?? 1
        count = nil
        let p = mode == .visual || mode == .visualLine ? head : position
        if let command = pending {
            let operation = command.operation
            pending = nil
            let repetitions = min(9999, n * command.count)
            if operation == .go {
                if key == "g", let target = motion("gg", from: p, count: repetitions, explicit: true) { select(target) }
            } else if (operation == .delete && key == "d") || (operation == .yank && key == "y") {
                let start = lineStart(p)
                var end = start
                for _ in 0..<repetitions { end = lineAfter(end) }
                let selection = range(start, end)
                guard capture(selection, linewise: true) else { return }
                if operation == .delete { replace(selection, with: ""); select(min(start, characters.count)) }
            } else if key == "w", operation == .delete || operation == .change {
                let selection = wordEditRange(from: p, count: repetitions, operation: operation)
                if operation == .change { mode = .insert }
                delete(selection)
                if operation == .change { modeChanged(modeLabel) }
            }
            return
        }
        if let target = motion(key, from: p, count: n, explicit: explicit) { select(target); return }
        if let operation = Operator(rawValue: key) { pending = (operation, n); return }
        switch key {
        case "i", "a":
            mode = .insert
            select(key == "a" ? min(lineEnd(p), p + 1) : p)
            modeChanged(modeLabel)
        case "v", "V":
            mode = key == "v" ? .visual : .visualLine
            anchor = p; select(p); modeChanged(modeLabel)
        case "x":
            if mode == .visual || mode == .visualLine {
                let selection = safeSelection()
                let linewise = mode == .visualLine
                mode = .normal
                delete(selection, linewise: linewise)
                modeChanged(modeLabel)
            } else { delete(range(p, min(lineEnd(p), p + n))) }
        case "p":
            guard !register.isEmpty else { return }
            let at = lineRegister ? lineAfter(p) : min(lineEnd(p), p + 1)
            let prefix = lineRegister && at == characters.count && !string.isEmpty && string.last?.isNewline != true ? "\n" : ""
            // Refuse amplification above 1 MiB rather than freezing the menu-bar UI.
            guard register.utf8.count <= 1_048_576 / n,
                  string.utf8.count + register.utf8.count * n <= 1_048_576 else { return }
            replace(range(at, at), with: prefix + String(repeating: register, count: n))
            select(at + (prefix.isEmpty ? 0 : 1))
        case "u": for _ in 0..<n { history.undo() }; normalCursor()
        default: break // no ex, dot-repeat, macros, hooks or external process
        }
    }

    private func capture(_ selection: NSRange, linewise: Bool) -> Bool {
        guard selection.length > 0 else { return false }
        register = (string as NSString).substring(with: selection)
        lineRegister = linewise
        if linewise && register.last?.isNewline != true { register += "\n" }
        return true
    }

    private func delete(_ selection: NSRange, linewise: Bool = false) {
        guard capture(selection, linewise: linewise) else { return }
        replace(selection, with: "")
        normalCursor()
    }
}
