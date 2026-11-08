import AppKit
import XCTest

@MainActor
final class InteractionProbe: XCTestCase {
    private var owned: [NSRunningApplication] = []
    private var bridge: NSPasteboard?
    private var recorderStatus: NSPasteboard?
    private var captureStarted = false
    private var syntheticCopies: Set<String> = []
    private var seededClipboard = false

    nonisolated override func tearDown() async throws {
        await cleanup()
    }

    private func cleanup() async {
        var stopped = !captureStarted
        if captureStarted, let bridge, let recorderStatus {
            if !["complete", "failed"].contains(recorderStatus.string(forType: .string) ?? "") {
                bridge.prepareForNewContents(with: .currentHostOnly)
                _ = bridge.setString("stop", forType: .string)
            }
            let end = Date().addingTimeInterval(7)
            while recorderStatus.string(forType: .string) != "complete",
                  recorderStatus.string(forType: .string) != "failed", Date() < end {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            stopped = recorderStatus.string(forType: .string) == "complete"
        }
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
        let clean = stopped && appsStopped && clipboardClean
        if !captureStarted || stopped || recorderStatus?.string(forType: .string) == "failed" {
            bridge?.releaseGlobally()
            recorderStatus?.releaseGlobally()
        }
        print("HAGIG_PROBE cleanup-components=recorder-\(stopped)-apps-\(appsStopped)-clipboard-\(clipboardClean)")
        print("HAGIG_PROBE cleanup=\(clean)")
        XCTAssertTrue(clean, "owned cleanup required")
    }

    func testOwnedShellInputFeasibility() async throws {
        continueAfterFailure = false
        // Retain the metadata-only boards before any input-control failure can
        // throw, so teardown owns their release even before capture admission.
        let prefix = "com.mattjmcnaughton.hagig.synthetic-recording-"
        guard let name = ProcessInfo.processInfo.environment["HAGIG_PROBE_BRIDGE"], name.hasPrefix(prefix),
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else {
            throw NSError(domain: "HagigSyntheticProbe", code: 2)
        }
        bridge = NSPasteboard(name: .init(name + ".request"))
        recorderStatus = NSPasteboard(name: .init(name + ".status"))
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
        let unchanged = receiver.value as? String == "clicks=1 down=1 up=1"
        print("HAGIG_PROBE key-receiver-unchanged=\(unchanged)")
        if !unchanged {
            // This owned canary exposes only counters. Export numbers only,
            // never arbitrary accessibility values or inserted content.
            if let value = receiver.value as? String,
               value.range(of: #"^clicks=[0-9]+ down=[0-9]+ up=[0-9]+$"#, options: .regularExpression) != nil {
                print("HAGIG_PROBE key-receiver-counts=" + value)
            }
            throw NSError(domain: "HagigSyntheticProbe", code: 4)
        }
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

        // XCUITest owns input. The separately launched existing recorder owns
        // capture; the UI runner neither requests nor needs direct AX/SCK access.
        let board = NSPasteboard.general
        XCTAssertTrue(board.pasteboardItems?.isEmpty != false)
        let sentinel = "HAGIG-SYNTHETIC-XCUI-" + UUID().uuidString
        let standard = "Synthetic Standard 😀\nsecond line"
        let vim = "Synthetic Vim 😀\nsecond line"
        syntheticCopies = [sentinel, standard, vim, "Sy"]
        func seed(_ text: String) {
            board.prepareForNewContents(with: .currentHostOnly)
            seededClipboard = true
            XCTAssertTrue(board.setString(text, forType: .string))
        }
        seed(sentinel)
        let bridge = try XCTUnwrap(bridge)
        captureStarted = true
        bridge.prepareForNewContents(with: .currentHostOnly)
        guard bridge.setString("start", forType: .string) else {
            throw NSError(domain: "HagigSyntheticProbe", code: 5)
        }
        try await awaitRecorder("ready")
        try await driveEditor(shell: shell, board: board,
                              sentinel: sentinel, standard: standard, vim: vim)
        bridge.prepareForNewContents(with: .currentHostOnly)
        guard bridge.setString("stop", forType: .string) else {
            throw NSError(domain: "HagigSyntheticProbe", code: 5)
        }
        try await awaitRecorder("complete")
        print("HAGIG_PROBE scenario-complete=true")
    }

    private func awaitRecorder(_ name: String) async throws {
        let bridge = try XCTUnwrap(recorderStatus)
        let end = Date().addingTimeInterval(7)
        while bridge.string(forType: .string) != name {
            guard Date() < end, bridge.string(forType: .string) != "failed" else {
                throw NSError(domain: "HagigSyntheticProbe", code: 3)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // Native UI and pasteboard calls stay on the main actor. The recorder's
    // independent process keeps its watchdog runnable during XCTest RPCs.
    private func driveEditor(shell: XCUIApplication, board: NSPasteboard,
                             sentinel: String, standard: String, vim: String) async throws {
        XCTAssertTrue(Thread.isMainThread)
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
        func selection(_ expected: String, restoring previous: String) {
            // Check selection through the public native Copy contract instead
            // of direct AX access unavailable to the UI runner. Restore only
            // our known synthetic sentinel before testing internal operations.
            clipboard(previous)
            shell.typeKey("c", modifierFlags: .command)
            clipboard(expected)
            seed(previous)
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
        selection(standard, restoring: sentinel)
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
        XCTAssertTrue(shell.staticTexts["Ready when you are"].waitForExistence(timeout: 3))
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
        selection("Sy", restoring: standard); mode("Vim · Visual")
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
        XCTAssertTrue(shell.staticTexts["Ready when you are"].waitForExistence(timeout: 3))
        XCTAssertFalse(editor.exists); clipboard(vim)
        print("HAGIG_PROBE vim-native-paste-normal-cursor-keyboard-copy-dismiss=true")
    }
}
