// Proof-only application recorder. Never linked into HagigShell or its shared views.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ScreenCaptureKit

private var proofInterrupted: sig_atomic_t = 0
private enum ProofFailure: Error { case gate }

@available(macOS 15.0, *)
@MainActor
private final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    let pid: pid_t
    let deadline: Date
    private(set) var bounds: CGRect?
    private let background = CGColor(gray: 0, alpha: 1)
    private let movie = FileManager.default.temporaryDirectory.appendingPathComponent("hagig-proof-" + UUID().uuidString + ".mov")
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var started = false
    private var finished = false
    private var failed = false
    private var ready = false
    private var stopRequested = false
    private var stopCompleted = false
    private var stopFailed = false
    private var limitReached = false
    private var limit: Task<Void, Never>?
    private var beganAt: Date?

    init(pid: pid_t, deadline: Date) {
        self.pid = pid
        self.deadline = deadline
    }

    var cleanupDeadline: Date {
        min(deadline, beganAt?.addingTimeInterval(60) ?? deadline)
    }

    func check() throws {
        if let beganAt, !stopCompleted, Date().timeIntervalSince(beganAt) >= 58 {
            limitReached = true
            requestStop()
        }
        guard proofInterrupted == 0, Date() < deadline, !failed, !limitReached,
              !finished || stopRequested else { throw ProofFailure.gate }
    }

    private func pause() async throws {
        try check()
        try await Task.sleep(nanoseconds: 50_000_000)
        try check()
    }

    private func requestStop() {
        guard let stream, !stopRequested else { return }
        stopRequested = true
        stream.stopCapture { error in
            let failed = error != nil
            Task { @MainActor in
                self.stopFailed = failed
                self.stopCompleted = true
            }
        }
    }

    func start(displayID: CGDirectDisplayID, backdropID: CGWindowID) async throws {
        // Callback APIs plus yielding bounded polls: a late enumeration never
        // starts a capture after this method has failed.
        var content: SCShareableContent?
        var enumerated = false
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { result, error in
            let succeeded = error == nil
            Task { @MainActor in
                content = succeeded ? result : nil
                enumerated = true
            }
        }
        let enumerationEnd = Date().addingTimeInterval(5)
        while !enumerated && Date() < enumerationEnd { try await pause() }
        guard enumerated, let content else { throw ProofFailure.gate }
        let applications = content.applications.filter { $0.processID == pid }
        let displays = content.displays.filter { $0.displayID == displayID }
        guard applications.count == 1, displays.count == 1 else { throw ProofFailure.gate }
        let display = displays[0]
        let windows = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !windows.isEmpty, windows.allSatisfy({ display.frame.contains($0.frame) }),
              content.windows.contains(where: {
                  $0.windowID == backdropID && $0.owningApplication?.processID == getpid()
              }) else { throw ProofFailure.gate }
        try check()
        // Exact application inclusion handles new shell popovers. Unknown
        // surfaces and the driver backdrop are never added as exceptions.
        let filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        filter.includeMenuBar = false
        let configuration = SCStreamConfiguration()
        configuration.includeChildWindows = true
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.backgroundColor = background
        configuration.width = display.width
        configuration.height = display.height
        bounds = display.frame
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        let file = SCRecordingOutputConfiguration()
        file.outputURL = movie
        file.outputFileType = .mov
        let output = SCRecordingOutput(configuration: file, delegate: self)
        self.output = output
        try stream.addRecordingOutput(output)
        beganAt = Date()
        // Leave two seconds for shutdown before the 60s acceptance ceiling.
        limit = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 58_000_000_000) }
            catch { return }
            self.limitReached = true
            self.requestStop()
        }
        var startCompleted = false
        var startFailed = false
        stream.startCapture { error in
            let failed = error != nil
            Task { @MainActor in
                startFailed = failed
                startCompleted = true
                if self.stopRequested {
                    // Failed-start cleanup must also stop a late start.
                    self.stopRequested = false
                    self.stopCompleted = false
                    self.requestStop()
                }
            }
        }
        let startEnd = Date().addingTimeInterval(5)
        while !(startCompleted && started) && Date() < startEnd {
            guard !startFailed else { throw ProofFailure.gate }
            try await pause()
        }
        try check()
        guard startCompleted, !startFailed, started, !finished else { throw ProofFailure.gate }
        print("PASS recorder.exact-owned-application-filter menu-bar=false child-windows=true cursor=true audio=false microphone=false")
    }

    func finish() async throws {
        try check()
        guard started, !finished else { throw ProofFailure.gate }
        requestStop()
        let end = Date().addingTimeInterval(5)
        while !(stopCompleted && finished) && Date() < end {
            guard !stopFailed else { throw ProofFailure.gate }
            try await pause()
        }
        try check()
        guard stopCompleted, !stopFailed, finished,
              beganAt.map({ Date().timeIntervalSince($0) <= 60 }) == true else { throw ProofFailure.gate }
        limit?.cancel()
        let bytes = try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? NSNumber
        guard (bytes?.intValue ?? 0) > 1000 else { throw ProofFailure.gate }
        ready = true
        print("PASS recorder.started-and-finished-callbacks max-seconds=60")
    }

    func shutdown(until end: Date) async -> Bool {
        limit?.cancel()
        requestStop()
        let end = min(end, min(cleanupDeadline, Date().addingTimeInterval(5)))
        while stream != nil && !stopCompleted && Date() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return stream == nil || (stopCompleted && !stopFailed)
    }

    func publish(to destination: URL) throws {
        try check()
        guard ready, started, finished, stopCompleted, !stopFailed else { throw ProofFailure.gate }
        try FileManager.default.moveItem(at: movie, to: destination)
    }

    func discard() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
            print("cleanup temporary-recording-removed=true")
            return true
        } catch {
            print("cleanup temporary-recording-removed=false")
            return false
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.started = true }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished = true }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.failed = true }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.failed = true }
    }
}

// Reuse the already-capable CLI recorder identity, never grant the UI runner
// access or record a display. The XCTest process owns and terminates the shell.
@main
private struct CaptureProbe {
    @MainActor static func main() {
        guard #available(macOS 15.0, *), CommandLine.arguments.count == 4,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { exit(2) }
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("hagig-xcui-probe")
        let bridge = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let name = CommandLine.arguments[3]
        let prefix = "com.mattjmcnaughton.hagig.synthetic-recording-"
        guard bridge == root.appendingPathComponent("bridge").standardizedFileURL,
              bundle == root.appendingPathComponent("derived/Build/Products/Debug/HagigShellProbe.app").standardizedFileURL,
              name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              CGPreflightScreenCaptureAccess() else {
            print("HAGIG_PROBE recorder-preflight=false"); exit(2)
        }
        print("HAGIG_PROBE recorder-preflight=true")
        signal(SIGINT) { _ in proofInterrupted = 1 }
        signal(SIGTERM) { _ in proofInterrupted = 1 }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let request = NSPasteboard(name: .init(name + ".request"))
        let status = NSPasteboard(name: .init(name + ".status"))
        Task { @MainActor in
            var session: RecordingSession?
            var background: NSWindow?
            var passed = false
            var acceptedStart = false
            func report(_ value: String) throws {
                status.prepareForNewContents(with: .currentHostOnly)
                guard status.setString(value, forType: .string) else { throw ProofFailure.gate }
            }
            do {
                let deadline = Date().addingTimeInterval(150)
                while request.string(forType: .string) != "start" {
                    guard request.string(forType: .string) != "stop", proofInterrupted == 0, Date() < deadline else { throw ProofFailure.gate }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                acceptedStart = true
                let matches = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mattjmcnaughton.hagig.synthetic-probe")
                guard matches.count == 1, let process = matches.first, !process.isTerminated,
                      process.bundleURL?.standardizedFileURL == bundle,
                      process.executableURL?.standardizedFileURL == bundle.appendingPathComponent("Contents/MacOS/HagigShellProbe"),
                      let screen = NSScreen.main else { throw ProofFailure.gate }
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.ignoresMouseEvents = true
                window.backgroundColor = .magenta
                window.orderBack(nil)
                background = window
                let recorder = RecordingSession(pid: process.processIdentifier, deadline: deadline)
                session = recorder
                try await recorder.start(displayID: CGMainDisplayID(), backdropID: CGWindowID(window.windowNumber))
                guard !process.isTerminated else { throw ProofFailure.gate }
                try await Task.sleep(nanoseconds: 500_000_000)
                window.backgroundColor = .cyan
                try await Task.sleep(nanoseconds: 500_000_000)
                try report("ready")
                print("HAGIG_PROBE exclusion-control=magenta-cyan-must-not-appear")
                while request.string(forType: .string) != "stop" {
                    try recorder.check()
                    guard !process.isTerminated else { throw ProofFailure.gate }
                    if let marker = request.string(forType: .string),
                       ["focus-standard", "focus-vim"].contains(marker),
                       status.string(forType: .string) != marker.replacingOccurrences(of: "focus-", with: "focused-") {
                        // Read only the retained application's focused role and
                        // owner, never text, selection contents or global focus.
                        guard AXIsProcessTrusted() else { throw ProofFailure.gate }
                        let app = AXUIElementCreateApplication(process.processIdentifier)
                        guard AXUIElementSetMessagingTimeout(app, 0.3) == .success else { throw ProofFailure.gate }
                        var focused: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw ProofFailure.gate }
                        try recorder.check()
                        let element = focused as! AXUIElement
                        var owner: pid_t = 0
                        var role: CFTypeRef?
                        guard AXUIElementSetMessagingTimeout(element, 0.3) == .success,
                              AXUIElementGetPid(element, &owner) == .success, owner == process.processIdentifier,
                              AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                              role as? String == kAXTextAreaRole else { throw ProofFailure.gate }
                        try recorder.check()
                        try report(marker.replacingOccurrences(of: "focus-", with: "focused-"))
                        print("HAGIG_PROBE " + marker + "-owned-text-area=true")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                window.backgroundColor = .magenta
                try await Task.sleep(nanoseconds: 500_000_000)
                try await recorder.finish()
                passed = true
            } catch { print("HAGIG_PROBE recorder-attempt=false") }
            let stopped = await session?.shutdown(until: Date().addingTimeInterval(5)) ?? true
            background?.close()
            if passed && stopped, let session {
                do {
                    // Private staging only. The coordinator exports only after
                    // successful XCTest AND confirmed app/clipboard cleanup.
                    try session.publish(to: bridge.appendingPathComponent("candidate.mov"))
                } catch { passed = false }
            }
            let discarded = session?.discard() ?? true
            print("HAGIG_PROBE recorder-cleanup=\(stopped && discarded)")
            var success = passed && stopped && discarded
            if acceptedStart {
                do { try report(success ? "complete" : "failed") }
                catch { success = false }
            } else {
                // No active waiter/capture was admitted. Do not recreate a
                // failed status after early test teardown released the boards.
                request.releaseGlobally()
                status.releaseGlobally()
            }
            exit(success ? 0 : 1)
        }
        application.run()
    }
}
