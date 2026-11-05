// Proof-only desktop driver. Never linked into HagigShell or its shared views.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

private var proofInterrupted: sig_atomic_t = 0
private enum ProofFailure: Error { case gate }

@MainActor
private final class ShellProof {
    let shell = Process()
    let recorder = Process()
    let debugger = Process()
    let deadline = Date().addingTimeInterval(90)
    let executable: URL
    let output: URL
    let temporaryMovie = FileManager.default.temporaryDirectory.appendingPathComponent("hagig-proof-" + UUID().uuidString + ".mov")
    var app: AXUIElement!
    var stage = "arguments"
    var crop: CGRect?
    var recordingStarted = false
    var seededClipboard = false
    var syntheticCopies = Set<String>()
    let board = NSPasteboard.general

    init(executable: URL, output: URL) {
        self.executable = executable.resolvingSymlinksInPath()
        self.output = output
    }

    func require(_ condition: Bool, line: UInt = #line) throws {
        if !condition {
            print("gate_failed source_line=\(line)")
            throw ProofFailure.gate
        }
    }

    func check() throws {
        try require(proofInterrupted == 0 && Date() < deadline)
    }

    func pause(_ seconds: Double = 0.15) throws {
        try check()
        Thread.sleep(forTimeInterval: seconds)
        try check()
        try safeCrop()
        if recordingStarted { try require(recorder.isRunning) }
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func owned(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return shell.isRunning && AXUIElementGetPid(element, &pid) == .success && pid == shell.processIdentifier
    }

    func nodes(in root: AXUIElement? = nil) throws -> [AXUIElement] {
        var queue = [root ?? app!]
        var seen = Set<CFHashCode>()
        var result = [AXUIElement]()
        while !queue.isEmpty {
            try check()
            let element = queue.removeLast()
            if !seen.insert(CFHash(element)).inserted { continue }
            try require(result.count < 1500 && owned(element))
            result.append(element)
            queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return result
    }

    func named(_ element: AXUIElement, _ name: String) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
            (attribute(element, $0) as? String) == name
        }
    }

    func find(_ name: String) throws -> AXUIElement? {
        try nodes().first { named($0, name) }
    }

    func awaitName(_ name: String) throws -> AXUIElement {
        let end = Date().addingTimeInterval(4)
        repeat {
            if let element = try find(name) {
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                let knownRoles = ["AXButton", "AXTextArea", "AXWindow", "AXStaticText", "AXPopUpButton", "AXMenuItem", "AXGroup"]
                // Names come only from the fixed synthetic scenario, never AX dumps.
                print("AX name=\(name) role=\(knownRoles.contains(role) ? role : "unrecognized")")
                return element
            }
            try pause(0.1)
        } while Date() < end
        throw ProofFailure.gate
    }

    func frame(_ element: AXUIElement) throws -> CGRect {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw ProofFailure.gate
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        try require(AXValueGetValue(position as! AXValue, .cgPoint, &point))
        try require(AXValueGetValue(size as! AXValue, .cgSize, &dimensions))
        let rect = CGRect(origin: point, size: dimensions)
        try require(!rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
                    rect.width.isFinite && rect.height.isFinite)
        return rect
    }

    // Refuse to record or drive across another application's normal windows.
    // Never log their names, values, owner names or window dictionaries.
    func safeCrop() throws {
        guard let crop else { return }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw ProofFailure.gate
        }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != shell.processIdentifier else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { throw ProofFailure.gate }
            try require(!rect.intersects(crop))
        }
    }

    func click(_ element: AXUIElement, diagnostic: Bool = false) throws {
        try require(owned(element))
        try safeCrop()
        let rect = try frame(element)
        if let crop { try require(crop.contains(rect)) }
        let target = CGPoint(x: rect.midX, y: rect.midY)
        let origin = CGEvent(source: nil)?.location ?? target
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let point = CGPoint(x: origin.x + (target.x - origin.x) * t,
                                y: origin.y + (target.y - origin.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                     mouseCursorPosition: point, mouseButton: .left) else { throw ProofFailure.gate }
            move.post(tap: .cghidEventTap)
            try pause(0.015)
        }
        var hit: AXUIElement?
        try require(AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                    Float(target.x), Float(target.y), &hit) == .success)
        guard let hit else { throw ProofFailure.gate }
        try require(owned(hit))
        print("pointer.hit-editor-name=\(named(hit, "Transcript editor")) hit-text-area=\((attribute(hit, kAXRoleAttribute) as? String) == "AXTextArea")")
        // Validate the pointer before debugger stops can delay AX replies.
        if diagnostic { try startResponderDiagnostic() }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: target, mouseButton: .left) else { throw ProofFailure.gate }
            event.post(tap: .cghidEventTap)
        }
        try pause()
    }

    func focused() throws -> AXUIElement {
        try require(shell.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == shell.processIdentifier)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw ProofFailure.gate }
        let element = value as! AXUIElement
        try require(owned(element))
        return element
    }

    func editorFocused() throws {
        let end = Date().addingTimeInterval(2)
        var element = try focused()
        var role = attribute(element, kAXRoleAttribute) as? String ?? ""
        while !(named(element, "Transcript editor") && role == "AXTextArea") && Date() < end {
            try pause(0.1)
            element = try focused()
            role = attribute(element, kAXRoleAttribute) as? String ?? ""
        }
        let isEditor = named(element, "Transcript editor") && role == "AXTextArea"
        if !isEditor {
            let roles = ["AXButton", "AXTextArea", "AXWindow", "AXStaticText", "AXPopUpButton", "AXGroup", "AXScrollArea",
                         "AXApplication", "AXUnknown", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXTextField",
                         "AXLayoutArea", "AXLayoutItem", "AXSplitGroup", "AXToolbar", "AXStatusItem", "AXMenuButton",
                         "AXRadioButton", "AXPopover", "AXTabGroup", "AXComboBox", "AXScrollBar", "AXImage"]
            let names = ["Transcript editor", "Copy all", "Copied", "Dismiss", "Simulate recording",
                         "Simulate release", "Simulate result", "Show menu-bar surface"]
            let name = names.first { named(element, $0) } ?? "unrecognized"
            print("focus.expected-editor=false known-name=\(name) known-role=\(roles.contains(role) ? role : "unrecognized")")
            var roleValue: CFTypeRef?
            let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            var globalValue: CFTypeRef?
            let globalStatus = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString, &globalValue)
            var globalOwned = false, globalEditor = false
            if globalStatus == .success, let globalValue, CFGetTypeID(globalValue) == AXUIElementGetTypeID() {
                let globalElement = globalValue as! AXUIElement
                globalOwned = owned(globalElement)
                globalEditor = globalOwned && named(globalElement, "Transcript editor") &&
                    (attribute(globalElement, kAXRoleAttribute) as? String) == "AXTextArea"
            }
            print("focus.app-role-status=\(roleStatus.rawValue) system-status=\(globalStatus.rawValue) system-owned=\(globalOwned) system-editor=\(globalEditor)")
            if let editor = try find("Transcript editor") {
                let editorFocus = attribute(editor, kAXFocusedAttribute) as? Bool
                var settable = DarwinBoolean(false)
                let status = AXUIElementIsAttributeSettable(editor, kAXValueAttribute as CFString, &settable)
                print("focus.editor-focused=\(editorFocus.map { String($0) } ?? "unavailable") value-settable-status=\(status.rawValue) value-settable=\(settable.boolValue)")
            }
            var childValue: CFTypeRef?
            let childStatus = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &childValue)
            var childEditor = false
            if childStatus == .success, let childValue, CFGetTypeID(childValue) == AXUIElementGetTypeID() {
                let child = childValue as! AXUIElement
                childEditor = owned(child) && named(child, "Transcript editor") &&
                    (attribute(child, kAXRoleAttribute) as? String) == "AXTextArea"
            }
            print("focus.container-child-status=\(childStatus.rawValue) child-editor=\(childEditor)")
            // A guarded diagnostic still is not a passing interaction recording.
            if let crop {
                try safeCrop()
                let still = temporaryMovie.appendingPathExtension("png")
                let capture = Process()
                defer { _ = stop(capture) }
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                let region = "\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))"
                capture.arguments = ["-x", "-R" + region, still.path]
                capture.standardOutput = FileHandle.nullDevice; capture.standardError = FileHandle.nullDevice
                try capture.run()
                while capture.isRunning { try pause(0.05) }
                try require(capture.terminationStatus == 0)
                try safeCrop()
                try FileManager.default.moveItem(at: still, to: output.appendingPathComponent("editor-focus-diagnostic.png"))
                print("UNPROVEN focus-diagnostic-still; no-interaction-acceptance")
            }
        }
        try require(isEditor)
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) throws {
        try check()
        _ = try focused()
        try safeCrop()
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw ProofFailure.gate }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
                }
            }
            event.post(tap: .cghidEventTap)
        }
        try pause(0.1)
    }

    func type(_ text: String) throws {
        for character in text {
            try editorFocused()
            if character == "\n" { try key(36) }
            else { try key(0, text: String(character)) }
        }
    }

    func expectText(_ expected: String) throws {
        let end = Date().addingTimeInterval(3)
        repeat {
            if let editor = try find("Transcript editor"), (attribute(editor, kAXValueAttribute) as? String) == expected { return }
            try pause(0.1)
        } while Date() < end
        throw ProofFailure.gate
    }

    func selectedLength() throws -> Int {
        let editor = try awaitName("Transcript editor")
        guard let value = attribute(editor, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            throw ProofFailure.gate
        }
        var range = CFRange()
        try require(AXValueGetValue(value as! AXValue, .cfRange, &range))
        return range.length
    }

    func clipboard(_ expected: String) throws {
        try require(board.string(forType: .string) == expected)
    }

    func beginReview() throws {
        for name in ["Simulate recording", "Simulate release", "Simulate result"] {
            try click(awaitName(name))
        }
        _ = try awaitName("Transcript editor")
        _ = try awaitName("Dismiss")
    }

    func startResponderDiagnostic() throws {
        stage = "diagnostic.attach"
        debugger.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        debugger.arguments = ["lldb", "--batch", "--no-lldbinit", "--one-line",
                              "command script import native_responder_diagnostic.py", "--one-line",
                              "script native_responder_diagnostic.observe(lldb.debugger)"]
        var environment = ProcessInfo.processInfo.environment
        environment["HAGIG_DIAGNOSTIC_PID"] = String(shell.processIdentifier)
        environment["HAGIG_DIAGNOSTIC_EXECUTABLE"] = executable.path
        environment["HAGIG_DIAGNOSTIC_DIRECTORY"] = output.path
        debugger.environment = environment
        // Only the observer's numeric allowlisted file is uploaded, not LLDB output.
        debugger.standardOutput = FileHandle.nullDevice; debugger.standardError = FileHandle.nullDevice
        try debugger.run()
        let end = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("responder.ready").path) {
            try require(debugger.isRunning && Date() < end)
            try pause(0.05)
        }
        try require(debugger.isRunning)
        print("diagnostic.attached-read-only-observer; instrumented-not-acceptance")
    }

    func finishResponderDiagnostic() throws {
        try Data().write(to: output.appendingPathComponent("responder.stop"))
        let end = Date().addingTimeInterval(10)
        while debugger.isRunning && Date() < end { try pause(0.05) }
        try require(!debugger.isRunning && debugger.terminationStatus == 0)
        let log = try String(contentsOf: output.appendingPathComponent("responder.log"), encoding: .utf8)
        try require(log.contains("observation-complete-not-acceptance=1\n") &&
                    log.contains("detached=1\n") && !log.contains("UNPROVEN"))
        print("diagnostic.completed-detached; no-acceptance-waiver")
    }

    func stop(_ process: Process, interrupt: Bool = false) -> Bool {
        guard process.isRunning else { return true }
        if interrupt { process.interrupt() } else { process.terminate() }
        let end = Date().addingTimeInterval(4)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killEnd = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killEnd { Thread.sleep(forTimeInterval: 0.05) }
        }
        return !process.isRunning
    }

    func startRecording() throws {
        stage = "recording.native-help"
        let help = Process()
        let helpURL = output.appendingPathComponent("capture-help.tmp")
        FileManager.default.createFile(atPath: helpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: helpURL)
        defer { _ = stop(help); try? handle.close(); try? FileManager.default.removeItem(at: helpURL) }
        help.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        help.arguments = ["-h"]
        help.standardOutput = handle; help.standardError = handle
        try help.run()
        while help.isRunning { try pause(0.05) }
        try handle.synchronize()
        let helpText = try String(contentsOf: helpURL, encoding: .utf8)
        // Validate native help before using these flags; incompatible hosts fail.
        for (flag, meaning) in [("-v", "video"), ("-V", "seconds"), ("-C", "cursor"), ("-R", "rect")] {
            let supported = helpText.components(separatedBy: .newlines).contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix(flag) && line.lowercased().contains(meaning)
            }
            print("recorder.option=\(flag) supported=\(supported)")
            try require(supported)
        }
        print("PASS recorder.native-help video=true duration=true cursor=true rectangle=true")
        stage = "recording.crop-and-start"
        var bounds = CGRect.null
        for element in try nodes() where (attribute(element, kAXRoleAttribute) as? String) == "AXWindow" {
            bounds = bounds.union(try frame(element))
        }
        // Popovers need not appear as AXWindow nodes. Include every visible
        // window belonging to this exact shell, never a foreign window's bounds.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw ProofFailure.gate
        }
        var ownedWindows = 0
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == shell.processIdentifier,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { continue }
            guard let value = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: value as CFDictionary) else { throw ProofFailure.gate }
            try require(!rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
                        rect.width.isFinite && rect.height.isFinite)
            bounds = bounds.union(rect)
            ownedWindows += 1
        }
        try require(ownedWindows > 0)
        print("recorder.owned-visible-windows=\(ownedWindows)")
        try require(!bounds.isNull)
        let screen = CGDisplayBounds(CGMainDisplayID())
        // Include neighboring controls and the extra Copied feedback row.
        bounds = bounds.insetBy(dx: -48, dy: -48).intersection(screen).integral
        try require(!bounds.isEmpty)
        crop = bounds
        try safeCrop()
        let region = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
        recorder.executableURL = help.executableURL
        recorder.arguments = ["-v", "-V", "45", "-C", "-R" + region, temporaryMovie.path]
        recorder.standardOutput = FileHandle.nullDevice; recorder.standardError = FileHandle.nullDevice
        try recorder.run()
        recordingStarted = true
        print("recorder.region=\(region) max-seconds=45 cursor-requested=true")
        try pause(0.5)
        try require(recorder.isRunning)
    }

    func run() throws {
        try require(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true")
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build").resolvingSymlinksInPath()
        try require(executable.path.hasPrefix(build.path + "/") && executable.lastPathComponent == "HagigShell")
        stage = "driver.preflight"
        let trusted = AXIsProcessTrusted(), posting = CGPreflightPostEventAccess(), capture = CGPreflightScreenCaptureAccess()
        print("driver_preflight ax_trusted=\(trusted) event_posting_allowed=\(posting) screen_capture_allowed=\(capture)")
        try require(trusted && posting && capture)
        try require(board.pasteboardItems?.isEmpty != false)
        let canary = "HAGIG-SYNTHETIC-SHELL-" + UUID().uuidString
        let standard = "Synthetic Standard 😀\nsecond line"
        let vim = "Synthetic Vim 😀\nsecond line"
        syntheticCopies = [canary, standard, vim]
        board.prepareForNewContents(with: .currentHostOnly)
        seededClipboard = true
        try require(board.setString(canary, forType: .string))
        stage = "shell.launch-identity"
        shell.executableURL = executable
        shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
        try shell.run()
        app = AXUIElementCreateApplication(shell.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        _ = try awaitName("Simulate recording")
        try require(NSRunningApplication(processIdentifier: shell.processIdentifier)?.executableURL?.resolvingSymlinksInPath() == executable)
        print("PASS shell.owned-fresh-process")
        stage = "standard.result-no-copy"
        try beginReview()
        try clipboard(canary)
        try startRecording()
        do {
            stage = "standard.pointer-editor"
            try click(awaitName("Transcript editor"), diagnostic: true)
            stage = "diagnostic.dispatch-return"
            let dispatchEnd = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("responder.dispatched").path) {
                try require(debugger.isRunning && Date() < dispatchEnd)
                try pause(0.05)
            }
            try finishResponderDiagnostic()
            stage = "standard.editor-focus"
            try editorFocused()
        } catch {
            if debugger.isRunning { try finishResponderDiagnostic() }
            throw error
        }
        stage = "standard.replace-select-all"
        try key(0, flags: .maskCommand)
        stage = "standard.type-unicode-multiline"
        try type(standard)
        stage = "standard.verify-edited-text"
        try expectText(standard)
        stage = "standard.verify-no-copy"
        try clipboard(canary)
        stage = "standard.verify-select-all"
        try key(0, flags: .maskCommand)
        try require(selectedLength() == standard.utf16.count)
        print("PASS standard.focused-AXTextArea unicode-multiline-edit selection")
        stage = "standard.copy-cut-undo"
        try key(8, flags: .maskCommand); try clipboard(standard)
        board.prepareForNewContents(with: .currentHostOnly)
        try require(board.setString(canary, forType: .string))
        try key(7, flags: .maskCommand); try expectText(""); try clipboard(standard)
        try key(6, flags: .maskCommand); try expectText(standard)
        try key(53); try expectText(standard)
        board.prepareForNewContents(with: .currentHostOnly)
        try require(board.setString(canary, forType: .string))
        let copyButton = try find("Copy all") ?? find("Copied")
        guard let copyButton else { throw ProofFailure.gate }
        try click(copyButton); try clipboard(standard)
        print("PASS standard.keyboard-copy-cut-undo escape-retains-review pointer-copy")
        stage = "standard.pointer-dismiss"
        try click(awaitName("Dismiss")); try pause()
        try click(awaitName("Show menu-bar surface"))
        _ = try awaitName("Ready when you are")
        try require(find("Transcript editor") == nil); try clipboard(standard)
        print("PASS standard.pointer-dismiss ready-after-reopen clipboard-unchanged")
        stage = "vim.demo-picker"
        let demo = try awaitName("Hagig · Demo controls")
        let pickers = try nodes(in: demo).filter { (attribute($0, kAXRoleAttribute) as? String) == "AXPopUpButton" }
        try require(pickers.count == 1)
        try click(pickers[0]); try click(awaitName("Bounded Vim"))
        try beginReview(); try clipboard(standard)
        _ = try awaitName("Editor mode: Vim · Normal")
        stage = "vim.focus-insert-escape"
        try click(awaitName("Transcript editor")); try editorFocused()
        try key(34); try key(0, flags: .maskCommand); try type(vim); try key(53)
        try expectText(vim)
        _ = try awaitName("Editor mode: Vim · Normal")
        try clipboard(standard)
        print("PASS vim.focus insert-unicode-multiline escape-normal no-copy")
        stage = "vim.visual-delete-undo-register"
        // gg, v, l, x, u use real key events, not editor methods/AX setters.
        try key(5); try key(5); try key(9); try key(37)
        try require(selectedLength() == 2)
        _ = try awaitName("Editor mode: Vim · Visual")
        try key(7); try expectText(String(vim.dropFirst(2)))
        try key(32); try expectText(vim)
        try key(16); try key(16); try clipboard(standard)
        print("PASS vim.visual-selection delete undo internal-register-no-copy")
        stage = "vim.keyboard-copy-dismiss"
        try key(8, flags: [.maskCommand, .maskShift]); try clipboard(vim)
        try key(2, flags: [.maskCommand, .maskShift]); try pause()
        try click(awaitName("Show menu-bar surface"))
        _ = try awaitName("Ready when you are")
        try require(find("Transcript editor") == nil); try clipboard(vim)
        print("PASS vim.keyboard-copy-all keyboard-dismiss ready-after-reopen clipboard-unchanged")
        stage = "recording.finalize"
        try safeCrop()
        try require(recorder.isRunning && stop(recorder, interrupt: true) && recorder.terminationStatus == 0)
        try safeCrop()
        let bytes = try FileManager.default.attributesOfItem(atPath: temporaryMovie.path)[.size] as? NSNumber
        try require((bytes?.intValue ?? 0) > 1000)
        // Only completed, privacy-checked candidate captures enter the artifact.
        try FileManager.default.moveItem(at: temporaryMovie, to: output.appendingPathComponent("interaction.mov"))
        print("VALIDATED candidate-interaction-assertions; movie-needs-human-inspection; no-shell-counterfactual")
    }

    func cleanup() -> Bool {
        // Ask the observer to detach before stopping only these owned processes.
        try? Data().write(to: output.appendingPathComponent("responder.stop"))
        let debuggerEnd = Date().addingTimeInterval(3)
        while debugger.isRunning && Date() < debuggerEnd { Thread.sleep(forTimeInterval: 0.05) }
        let debuggerStopped = stop(debugger)
        let recordingStopped = stop(recorder, interrupt: true)
        let shellStopped = stop(shell)
        var temporaryRemoved = true
        for file in [temporaryMovie, temporaryMovie.appendingPathExtension("png")] {
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { temporaryRemoved = false }
            }
        }
        if seededClipboard {
            if let value = board.string(forType: .string), syntheticCopies.contains(value) {
                board.prepareForNewContents(with: .currentHostOnly)
                print("cleanup synthetic-clipboard-cleared")
            } else { print("cleanup unknown-or-empty-clipboard-preserved") }
        }
        print("cleanup owned-shell-stopped=\(shellStopped) owned-recorder-stopped=\(recordingStopped) temporary-recording-removed=\(temporaryRemoved)")
        print("cleanup owned-debugger-stopped=\(debuggerStopped)")
        return debuggerStopped && recordingStopped && shellStopped && temporaryRemoved
    }
}

@main
private struct ShellInteraction {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { print("UNPROVEN arguments"); exit(2) }
        signal(SIGINT) { _ in proofInterrupted = 1 }
        signal(SIGTERM) { _ in proofInterrupted = 1 }
        let driver = ShellProof(executable: URL(fileURLWithPath: CommandLine.arguments[1]),
                                output: URL(fileURLWithPath: CommandLine.arguments[2]))
        var passed = false
        do { try driver.run(); passed = true }
        catch { print("UNPROVEN stage=\(driver.stage)") }
        let cleaned = driver.cleanup()
        exit(passed && cleaned ? 0 : 1)
    }
}
