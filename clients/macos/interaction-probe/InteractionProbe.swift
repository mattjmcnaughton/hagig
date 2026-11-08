import AppKit
import ApplicationServices
import XCTest

@MainActor
final class InteractionProbe: XCTestCase {
    private var owned: [NSRunningApplication] = []
    private var recording: RecordingSession?
    private var backdrop: NSWindow?
    private var syntheticCopies: Set<String> = []
    private var seededClipboard = false
    private var passed = false
    private var destination: URL?

    nonisolated override func tearDown() async throws {
        await cleanup()
    }

    private func cleanup() async {
        let stopped = await recording?.shutdown(until: Date().addingTimeInterval(5)) ?? true
        // Retained identities, never a PID read from text or a broad kill.
        for process in owned.reversed() where !process.isTerminated { process.terminate() }
        let end = Date().addingTimeInterval(3)
        while owned.contains(where: { !$0.isTerminated }) && Date() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let appsStopped = owned.allSatisfy(\.isTerminated)
        var clipboardClean = true
        if seededClipboard {
            let board = NSPasteboard.general
            if board.pasteboardItems?.isEmpty != false { /* already empty */ }
            else if let value = board.string(forType: .string), syntheticCopies.contains(value) {
                board.prepareForNewContents(with: .currentHostOnly)
                clipboardClean = board.pasteboardItems?.isEmpty != false
            } else { clipboardClean = false } // Never clear unknown contents.
        }
        backdrop?.close()
        let clean = stopped && appsStopped && clipboardClean
        if passed && clean, let recording, let destination {
            do {
                try recording.publish(to: destination)
                print("HAGIG_PROBE movie-published=true")
            } catch { XCTFail("candidate publication failed") }
        }
        let discarded = recording?.discard() ?? true
        print("HAGIG_PROBE cleanup=\(clean && discarded)")
        XCTAssertTrue(clean && discarded, "owned cleanup required")
    }

    func testOwnedShellInputFeasibility() async throws {
        continueAfterFailure = false
        let shell = XCUIApplication()
        let products = Bundle(for: InteractionProbe.self).bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // UI bundle is Runner.app/Contents/PlugIns/InteractionProbe.xctest.
        let canaryURL = products.appendingPathComponent("InputCanary.app")
        let canary = XCUIApplication(url: canaryURL)

        func retainOwned(_ identifier: String, name: String) throws -> NSRunningApplication {
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            guard matches.count == 1, let process = matches.first,
                  process.bundleURL?.lastPathComponent == name,
                  process.bundleURL?.deletingLastPathComponent().standardizedFileURL == products.standardizedFileURL else {
                throw NSError(domain: "HagigSyntheticProbe", code: 1)
            }
            owned.append(process)
            return process
        }

        for identifier in ["com.mattjmcnaughton.hagig.synthetic-probe", "com.mattjmcnaughton.hagig.synthetic-canary"] {
            XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
        }
        print("HAGIG_PROBE stage=shell-launch")
        shell.launch()
        let shellProcess = try retainOwned("com.mattjmcnaughton.hagig.synthetic-probe", name: "HagigShellProbe.app")
        let record = shell.buttons["Simulate recording"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(record.isEnabled)
        let point = record.frame
        canary.launchEnvironment = ["PROBE_X": String(Double(point.midX)), "PROBE_Y": String(Double(point.midY))]
        print("HAGIG_PROBE stage=canary-launch")
        canary.launch()
        let canaryProcess = try retainOwned("com.mattjmcnaughton.hagig.synthetic-canary", name: "InputCanary.app")
        let receiver = canary.textViews["probe-input"]
        XCTAssertTrue(receiver.waitForExistence(timeout: 5))
        print("HAGIG_PROBE stage=canary-click-key")
        receiver.click()
        receiver.typeText("z")
        XCTAssertEqual(receiver.value as? String, "clicks=1 down=1 up=1")
        print("HAGIG_PROBE canary-positive=true")

        // Deliberately leave the overlapping owned canary foregrounded. An
        // app-scoped click must not become a canary click when focus differs.
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, canaryProcess.processIdentifier)
        XCTAssertFalse(shellProcess.isTerminated)
        print("HAGIG_PROBE stage=focus-race-click")
        record.click()
        XCTAssertEqual(receiver.value as? String, "clicks=1 down=1 up=1")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, shellProcess.processIdentifier)
        XCTAssertTrue(shell.buttons["Simulate release"].isEnabled)
        print("HAGIG_PROBE focus-race-receiver-unchanged=true recording-transition=true")
        canary.activate()
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, canaryProcess.processIdentifier)
        shell.typeKey("q", modifierFlags: [])
        XCTAssertEqual(receiver.value as? String, "clicks=1 down=1 up=1")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, shellProcess.processIdentifier)
        print("HAGIG_PROBE focus-race-key-receiver-unchanged=true")
        canaryProcess.terminate()
        let canaryEnd = Date().addingTimeInterval(3)
        while !canaryProcess.isTerminated && Date() < canaryEnd {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(canaryProcess.isTerminated)
        print("HAGIG_PROBE stage=release-result")
        shell.buttons["Simulate release"].click()
        XCTAssertTrue(shell.buttons["Simulate result"].isEnabled)
        shell.buttons["Simulate result"].click()
        XCTAssertTrue(shell.textViews["Transcript editor"].waitForExistence(timeout: 5))
        print("HAGIG_PROBE shell-review-reached=true")

        let trusted = AXIsProcessTrusted()
        let captureAllowed = CGPreflightScreenCaptureAccess()
        print("HAGIG_PROBE capabilities=ax-\(trusted)-capture-\(captureAllowed)")
        XCTAssertTrue(trusted && captureAllowed)
        let board = NSPasteboard.general
        XCTAssertTrue(board.pasteboardItems?.isEmpty != false)
        let sentinel = "HAGIG-SYNTHETIC-XCUI-" + UUID().uuidString
        let standard = "Synthetic Standard 😀\nsecond line"
        let vim = "Synthetic Vim 😀\nsecond line"
        syntheticCopies = [sentinel, standard, vim]
        func seed(_ text: String) {
            board.prepareForNewContents(with: .currentHostOnly)
            seededClipboard = true
            XCTAssertTrue(board.setString(text, forType: .string))
        }
        seed(sentinel)
        guard let output = ProcessInfo.processInfo.environment["HAGIG_PROBE_OUTPUT"] else {
            throw NSError(domain: "HagigSyntheticProbe", code: 2)
        }
        destination = URL(fileURLWithPath: output).appendingPathComponent("interaction.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination!.path))

        let screen = try XCTUnwrap(NSScreen.main)
        let background = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.ignoresMouseEvents = true
        background.backgroundColor = .magenta
        background.orderBack(nil)
        backdrop = background
        let session = RecordingSession(pid: shellProcess.processIdentifier, deadline: Date().addingTimeInterval(90))
        recording = session
        try await session.start(displayID: CGMainDisplayID(), backdropID: CGWindowID(background.windowNumber))
        try await Task.sleep(nanoseconds: 500_000_000)
        background.backgroundColor = .cyan
        try await Task.sleep(nanoseconds: 500_000_000)
        print("HAGIG_PROBE exclusion-control=magenta-cyan-must-not-appear")

        try await driveEditor(shell: shell, pid: shellProcess.processIdentifier, board: board,
                              sentinel: sentinel, standard: standard, vim: vim)
        background.backgroundColor = .magenta
        try await Task.sleep(nanoseconds: 500_000_000)
        try await session.finish()
        passed = true
    }

    // A nonisolated async function runs on the generic executor in Swift 5 / the
    // selected Xcode 16.4. Synchronous XCTest RPCs must NOT starve the main-actor
    // recorder callbacks or its independent 58s stop watchdog.
    nonisolated private func driveEditor(shell: XCUIApplication, pid: pid_t, board: NSPasteboard,
                                        sentinel: String, standard: String, vim: String) async throws {
        XCTAssertFalse(Thread.isMainThread, "recorder actor must remain runnable")
        func seed(_ text: String) {
            board.prepareForNewContents(with: .currentHostOnly)
            XCTAssertTrue(board.setString(text, forType: .string))
        }
        let editor = shell.textViews["Transcript editor"]
        func expectText(_ text: String) { XCTAssertEqual(editor.value as? String, text) }
        func clipboard(_ text: String) { XCTAssertEqual(board.string(forType: .string), text) }
        func mode(_ expected: String) {
            let label = shell.staticTexts["review-editor-mode"]
            XCTAssertTrue(label.exists)
            XCTAssertTrue(label.label.contains(expected) || (label.value as? String)?.contains(expected) == true)
        }
        func selection(_ expected: String) {
            var focused: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                       kAXFocusedUIElementAttribute as CFString, &focused), .success)
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                XCTFail("focused editor required"); return
            }
            let element = unsafeBitCast(focused, to: AXUIElement.self)
            var role: CFTypeRef?, selected: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role), .success)
            XCTAssertEqual(role as? String, kAXTextAreaRole)
            XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected), .success)
            XCTAssertEqual(selected as? String, expected)
        }
        func beginReview() {
            shell.buttons["Simulate recording"].click()
            shell.buttons["Simulate release"].click()
            shell.buttons["Simulate result"].click()
            XCTAssertTrue(editor.exists)
        }
        print("HAGIG_PROBE stage=standard-editor")
        editor.click()
        shell.typeKey("a", modifierFlags: .command)
        editor.typeText(standard)
        expectText(standard); clipboard(sentinel)
        shell.typeKey("a", modifierFlags: .command)
        selection(standard)
        shell.typeKey("c", modifierFlags: .command); clipboard(standard)
        seed(sentinel)
        shell.typeKey("x", modifierFlags: .command); expectText(""); clipboard(standard)
        shell.typeKey("z", modifierFlags: .command); expectText(standard)
        shell.typeKey(.escape, modifierFlags: []); expectText(standard)
        seed(sentinel)
        shell.buttons["Dismiss"].hover()
        shell.buttons["Copy all"].hover()
        shell.buttons["Copy all"].click(); clipboard(standard)
        print("HAGIG_PROBE standard-edit-select-copy-cut-undo-escape-pointer-copy=true")
        shell.buttons["Dismiss"].click()
        shell.buttons["Show menu-bar surface"].click()
        XCTAssertTrue(shell.staticTexts["Ready when you are"].exists)
        XCTAssertFalse(editor.exists); clipboard(standard)
        print("HAGIG_PROBE standard-pointer-dismiss-reopen=true")

        shell.popUpButtons["synthetic-editor-mode"].click()
        shell.menuItems["Bounded Vim"].click()
        beginReview(); clipboard(standard); mode("Vim · Normal")
        editor.click()
        shell.typeKey("i", modifierFlags: [])
        shell.typeKey("a", modifierFlags: .command)
        editor.typeText(vim)
        shell.typeKey(.escape, modifierFlags: [])
        expectText(vim); mode("Vim · Normal"); clipboard(standard)
        shell.typeText("ggvl")
        selection("Sy"); mode("Vim · Visual")
        shell.typeKey("x", modifierFlags: []); expectText(String(vim.dropFirst(2)))
        shell.typeKey("u", modifierFlags: []); expectText(vim)
        shell.typeText("yy"); clipboard(standard)
        print("HAGIG_PROBE vim-insert-escape-visual-delete-undo-register=true")
        shell.typeKey("c", modifierFlags: [.command, .shift]); clipboard(vim)
        shell.typeKey("a", modifierFlags: .command)
        shell.typeKey("v", modifierFlags: .command)
        expectText(vim); mode("Vim · Normal")
        shell.typeKey("x", modifierFlags: []); expectText(String(vim.dropLast()))
        shell.typeKey("u", modifierFlags: []); expectText(vim); clipboard(vim)
        shell.typeKey("d", modifierFlags: [.command, .shift])
        shell.buttons["Show menu-bar surface"].click()
        XCTAssertTrue(shell.staticTexts["Ready when you are"].exists)
        XCTAssertFalse(editor.exists); clipboard(vim)
        print("HAGIG_PROBE vim-native-paste-normal-cursor-keyboard-copy-dismiss=true")
    }
}
