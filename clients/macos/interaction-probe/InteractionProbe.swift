import AppKit
import XCTest

final class InteractionProbe: XCTestCase {
    // No screenshot, recording, interruption handler, foreign app query, clipboard
    // write or product instrumentation. Existing interaction gate is unchanged.
    @MainActor
    func testOwnedShellInputFeasibility() throws {
        continueAfterFailure = false
        let shell = XCUIApplication()
        let products = Bundle(for: InteractionProbe.self).bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // UI bundle is Runner.app/Contents/PlugIns/InteractionProbe.xctest.
        let canaryURL = products.appendingPathComponent("InputCanary.app")
        let canary = XCUIApplication(url: canaryURL)
        var owned: [NSRunningApplication] = []
        defer {
            // Retained process identities, never a PID read from text or a broad kill.
            for process in owned.reversed() where !process.isTerminated { process.terminate() }
            let end = Date().addingTimeInterval(3)
            while owned.contains(where: { !$0.isTerminated }) && Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            print("HAGIG_PROBE cleanup=\(owned.allSatisfy(\.isTerminated))")
            XCTAssertTrue(owned.allSatisfy(\.isTerminated), "owned cleanup required")
        }

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
        canary.launchEnvironment = ["PROBE_X": String(point.midX), "PROBE_Y": String(point.midY)]
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
        print("HAGIG_PROBE stage=release-result")
        shell.buttons["Simulate release"].click()
        XCTAssertTrue(shell.buttons["Simulate result"].isEnabled)
        shell.buttons["Simulate result"].click()
        XCTAssertTrue(shell.textViews["Transcript editor"].waitForExistence(timeout: 5))
        print("HAGIG_PROBE shell-review-reached=true")
    }
}
