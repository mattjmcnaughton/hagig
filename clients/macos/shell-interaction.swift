// Proof-only desktop driver. Never linked into HagigShell or its shared views.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ScreenCaptureKit

private var proofInterrupted: sig_atomic_t = 0
private enum ProofFailure: Error { case gate, foreignTarget }

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

#if HAGIG_CAPTURE_PROBE
// Reuse the already-capable CLI recorder identity, never grant the UI runner
// access or record a display. The XCTest process owns and terminates the shell.
@main
private struct CaptureProbe {
    @MainActor static func main() {
        guard #available(macOS 15.0, *), CommandLine.arguments.count == 3,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { exit(2) }
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("hagig-xcui-probe")
        let bridge = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard bridge == root.appendingPathComponent("bridge").standardizedFileURL,
              bundle == root.appendingPathComponent("derived/Build/Products/Debug/HagigShellProbe.app").standardizedFileURL,
              CGPreflightScreenCaptureAccess() else {
            print("HAGIG_PROBE recorder-preflight=false"); exit(2)
        }
        print("HAGIG_PROBE recorder-preflight=true")
        signal(SIGINT) { _ in proofInterrupted = 1 }
        signal(SIGTERM) { _ in proofInterrupted = 1 }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            var session: RecordingSession?
            var background: NSWindow?
            var passed = false
            do {
                let deadline = Date().addingTimeInterval(150)
                func exists(_ name: String) -> Bool {
                    FileManager.default.fileExists(atPath: bridge.appendingPathComponent(name).path)
                }
                while !exists("start") {
                    guard !exists("stop"), proofInterrupted == 0, Date() < deadline else { throw ProofFailure.gate }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
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
                try Data().write(to: bridge.appendingPathComponent("ready"), options: .atomic)
                print("HAGIG_PROBE exclusion-control=magenta-cyan-must-not-appear")
                while !exists("stop") {
                    try recorder.check()
                    guard !process.isTerminated else { throw ProofFailure.gate }
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
            let success = passed && stopped && discarded
            try? Data().write(to: bridge.appendingPathComponent(success ? "complete" : "failed"), options: .atomic)
            exit(success ? 0 : 1)
        }
        application.run()
    }
}
#else
// Separate-PID receiving control, never part of Hagig or an accepted recording.
@MainActor
private final class InputCanary: NSTextView {
    private var clicks = 0
    private var keyDowns = 0
    private var keyUps = 0
    private var insertions = 0
    var counts: [Int] { [clicks, keyDowns, keyUps, insertions] }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        clicks += 1
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        keyDowns += 1
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        keyUps += 1
        super.keyUp(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        insertions += 1
        super.insertText(insertString, replacementRange: replacementRange)
    }
}

@available(macOS 15.0, *)
@MainActor
private final class ShellProof {
    let shell = Process()
    let deadline = Date().addingTimeInterval(90)
    let executable: URL
    let output: URL
    var app: AXUIElement!
    var stage = "arguments"
    var shellPID: pid_t?
    var recording: RecordingSession?
    var backdrop: NSWindow?
    var receiverWindow: NSWindow?
    var inputCanary: InputCanary?
    var inputControlPassed = false
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
        try recording?.check()
    }

    func pause(_ seconds: Double = 0.15) async throws {
        try check()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try check()
        if shellPID != nil { try captureIdentity() }
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
        var result = [AXUIElement]()
        while !queue.isEmpty {
            try check()
            let element = queue.removeLast()
            if result.contains(where: { CFEqual($0, element) }) { continue }
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

    func awaitName(_ name: String) async throws -> AXUIElement {
        let end = Date().addingTimeInterval(4)
        repeat {
            if let element = try find(name) {
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                let knownRoles = ["AXButton", "AXTextArea", "AXWindow", "AXStaticText", "AXPopUpButton", "AXMenuItem", "AXGroup"]
                // Names come only from the fixed synthetic scenario, never AX dumps.
                print("AX name=\(name) role=\(knownRoles.contains(role) ? role : "unrecognized")")
                return element
            }
            try await pause(0.1)
        } while Date() < end
        print("AX missing-name=\(name)")
        throw ProofFailure.gate
    }

    func awaitMode(_ label: String) async throws {
        let end = Date().addingTimeInterval(4)
        repeat {
            let matches = try nodes().filter { (attribute($0, kAXIdentifierAttribute) as? String) == "review-editor-mode" }
            try require(matches.count <= 1)
            if let mode = matches.first {
                try require((attribute(mode, kAXRoleAttribute) as? String) == "AXStaticText")
                let value = attribute(mode, kAXValueAttribute) as? String
                if value == label || value == "Editor mode: " + label {
                    print("PASS identified-mode-value=\(label)")
                    return
                }
            }
            try await pause(0.1)
        } while Date() < end
        print("AX missing-mode=\(label)")
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

    // Privacy comes from SCK application inclusion, never composited pixels or
    // exemptions for unknown layers. This check does not prove input visibility.
    func captureIdentity() throws {
        try require(shell.isRunning && shellPID == shell.processIdentifier)
        try require(NSRunningApplication(processIdentifier: shell.processIdentifier)?
            .executableURL?.resolvingSymlinksInPath() == executable)
    }

    func shellInputPID() throws -> pid_t {
        try check()
        try captureIdentity()
        guard let shellPID else { throw ProofFailure.gate }
        return shellPID
    }

    func targetPoint(_ element: AXUIElement) throws -> CGPoint {
        guard owned(element) else { throw ProofFailure.foreignTarget }
        _ = try shellInputPID()
        let rect = try frame(element)
        let bounds = recording?.bounds ?? CGDisplayBounds(CGMainDisplayID())
        try require(bounds.contains(rect))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func ownedHit(at point: CGPoint) throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        try require(AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success)
        guard let hit else { throw ProofFailure.gate }
        try require(owned(hit))
        return hit
    }

    func warpCursor(to point: CGPoint) throws {
        try check()
        // This emits no mouse event. A background driver may be denied; do not
        // activate it or substitute a global event to make the movie pass.
        try require(CGDisplayBounds(CGMainDisplayID()).contains(point))
        try require(CGWarpMouseCursorPosition(point) == .success)
        guard let actual = CGEvent(source: nil)?.location else { throw ProofFailure.gate }
        try require(abs(actual.x - point.x) <= 1 && abs(actual.y - point.y) <= 1)
    }

    func inputWindow(at point: CGPoint, pid: pid_t) throws -> (number: Int, frame: CGRect)? {
        try check()
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ProofFailure.gate
        }
        // WindowServer returns front-to-back order. Ignore other PIDs entirely;
        // ordinary click also requires an owned AX hit immediately before posting.
        for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
            guard let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0 else { continue }
            guard let values = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: values as CFDictionary),
                  !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  let number = window[kCGWindowNumber as String] as? NSNumber, number.intValue > 0 else {
                throw ProofFailure.gate
            }
            if frame.contains(point) { return (number.intValue, frame) }
        }
        return nil
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: (number: Int, frame: CGRect)) throws -> CGEvent {
        let local = CGPoint(x: point.x - window.frame.minX, y: window.frame.maxY - point.y)
        try require(window.frame.contains(point))
        guard let factory = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.number,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0),
              let event = factory.cgEvent else {
            throw ProofFailure.gate
        }
        try require(NSEvent(cgEvent: event)?.windowNumber == window.number)
        if type == .leftMouseDown {
            guard let untouched = event.copy(), let same = event.copy(), let target = event.copy() else {
                throw ProofFailure.gate
            }
            let originalGlobal = event.location
            let originalLocal = NSEvent(cgEvent: event)?.locationInWindow
            let fields: [CGEventField] = [.mouseEventWindowUnderMousePointer,
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                .mouseEventClickState, .mouseEventButtonNumber, .mouseEventNumber]
            let metadata = fields.map { event.getIntegerValueField($0) }
            same.location = originalGlobal
            target.location = point
            // Diagnostic copies are NEVER posted. Keep the known original
            // transport while separating copy/setter effects on public metadata.
            for (name, sample) in [("original", event), ("copy", untouched), ("same", same), ("target", target)] {
                let bridged = NSEvent(cgEvent: sample)
                let localMatches = bridged.map { abs($0.locationInWindow.x - local.x) <= 1 && abs($0.locationInWindow.y - local.y) <= 1 } ?? false
                print("mouse.metadata case=\(name) own-window=\(factory.window != nil) global-original=\(sample.location == originalGlobal) global-target=\(sample.location == point) local-original=\(bridged?.locationInWindow == originalLocal) local-target=\(localMatches) window-number=\(bridged?.windowNumber == window.number) routing-and-fields=\(fields.map { sample.getIntegerValueField($0) } == metadata) type-and-flags=\(sample.type == event.type && sample.flags == event.flags)")
            }
        }
        return event
    }

    func mousePair(at point: CGPoint, window: (number: Int, frame: CGRect)) throws -> [CGEvent] {
        try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { try mouse($0, at: point, window: window) }
    }

    func keyPair(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) throws -> [CGEvent] {
        try [true, false].map { down in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw ProofFailure.gate }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
                }
            }
            return event
        }
    }

    func click(_ element: AXUIElement) async throws {
        let target = try targetPoint(element)
        guard let origin = CGEvent(source: nil)?.location else { throw ProofFailure.gate }
        for step in 1...8 {
            let pid = try shellInputPID()
            let t = CGFloat(step) / 8
            let point = CGPoint(x: origin.x + (target.x - origin.x) * t,
                                y: origin.y + (target.y - origin.y) * t)
            try warpCursor(to: point)
            if let window = try inputWindow(at: point, pid: pid) {
                try mouse(.mouseMoved, at: point, window: window).postToPid(pid)
            }
            try await pause(0.015)
        }
        let targetPID = try shellInputPID()
        guard let window = try inputWindow(at: target, pid: targetPID) else { throw ProofFailure.gate }
        let events = try mousePair(at: target, window: window)
        let hit = try ownedHit(at: target)
        print("pointer.hit-editor-name=\(named(hit, "Transcript editor")) hit-text-area=\((attribute(hit, kAXRoleAttribute) as? String) == "AXTextArea")")
        print("pointer.hit-requested=\(CFEqual(hit, element)) hit-menu-item=\((attribute(hit, kAXRoleAttribute) as? String) == "AXMenuItem") target-enabled=\((attribute(element, kAXEnabledAttribute) as? NSNumber)?.intValue ?? -1)")
        // Diagnostics may synchronously query AX. Revalidate after them, directly
        // before the PID-bound pair; a focus race still cannot reroute the pair.
        let pid = try shellInputPID()
        try require(try targetPoint(element) == target)
        _ = try ownedHit(at: target)
        let currentWindow = try inputWindow(at: target, pid: pid)
        try require(currentWindow?.number == window.number && currentWindow?.frame == window.frame)
        for event in events { event.postToPid(pid) }
        try await pause()
    }

    func focused() throws -> AXUIElement {
        try require(shell.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == shell.processIdentifier)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw ProofFailure.gate }
        let element = value as! AXUIElement
        try require(owned(element))
        return element
    }

    func editorFocused() async throws {
        let end = Date().addingTimeInterval(2)
        var element = try focused()
        var role = attribute(element, kAXRoleAttribute) as? String ?? ""
        while !(named(element, "Transcript editor") && role == "AXTextArea") && Date() < end {
            try await pause(0.1)
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
        }
        try require(isEditor)
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) async throws {
        let events = try keyPair(code, flags: flags, text: text)
        let pid = try shellInputPID()
        _ = try focused()
        for event in events { event.postToPid(pid) }
        try await pause(0.1)
    }

    func type(_ text: String) async throws {
        for character in text {
            try await editorFocused()
            if character == "\n" { try await key(36) }
            else { try await key(0, text: String(character)) }
        }
    }

    func expectText(_ expected: String) async throws {
        let end = Date().addingTimeInterval(3)
        repeat {
            if let editor = try find("Transcript editor"), (attribute(editor, kAXValueAttribute) as? String) == expected { return }
            try await pause(0.1)
        } while Date() < end
        throw ProofFailure.gate
    }

    func selectedLength() async throws -> Int {
        let editor = try await awaitName("Transcript editor")
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

    func beginReview() async throws {
        for name in ["Simulate recording", "Simulate release", "Simulate result"] {
            try await click(await awaitName(name))
            let feedback = try nodes()
            print("simulation.action=\(name) recording=\(feedback.contains { named($0, "Listening…") }) transcribing=\(feedback.contains { named($0, "Transcribing…") }) review=\(feedback.contains { named($0, "Review transcript") })")
        }
        _ = try await awaitName("Transcript editor")
        _ = try await awaitName("Dismiss")
    }

    func prepareBackdrop() throws {
        guard let primary = NSScreen.screens.first else { throw ProofFailure.gate }
        // Created before shell launch so the shell orders above this separate-PID
        // synthetic backdrop. No screen pixels, user text or product hooks.
        let window = NSWindow(contentRect: primary.visibleFrame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .magenta
        window.orderFrontRegardless()
        backdrop = window
        try require(window.windowNumber > 0)
    }

    func receiverIsFocused(_ window: NSWindow) -> Bool {
        NSApp.isActive && NSApp.keyWindow === window &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }

    func showReceiver(_ window: NSWindow) async throws {
        // Only the pre-movie focus-race control activates the driver, never a
        // cursor step or ordinary shell scenario. These are ordinary AppKit
        // window/application actions, not AX focus setters.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let end = Date().addingTimeInterval(2)
        while !receiverIsFocused(window) && Date() < end { try await pause(0.05) }
        try require(receiverIsFocused(window))
    }

    func restoreShell(using element: AXUIElement) async throws {
        // The focus-race setup deliberately activates the driver. PID-directed
        // events do not ask WindowServer to activate another application, so
        // restore only the owned shell explicitly before any movie can begin.
        try require(recording == nil)
        let pid = try shellInputPID()
        receiverWindow?.orderOut(nil)
        guard let application = NSRunningApplication(processIdentifier: pid) else { throw ProofFailure.gate }
        try require(application.activate(options: [.activateIgnoringOtherApps]))
        let end = Date().addingTimeInterval(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != shellPID && Date() < end {
            try await pause(0.05)
        }
        _ = try focused()
        try await click(element)
        _ = try focused()
    }

    func proveInputIsolation() async throws {
        stage = "driver.input-canary-positive"
        let control = try await awaitName("Show menu-bar surface")
        let point = try targetPoint(control)
        _ = try ownedHit(at: point)
        _ = try focused()
        guard let screen = NSScreen.screens.first else { throw ProofFailure.gate }
        let display = CGDisplayBounds(CGMainDisplayID())
        let cocoa = CGPoint(x: screen.frame.minX + point.x - display.minX,
                            y: screen.frame.maxY - (point.y - display.minY))
        let window = NSWindow(contentRect: CGRect(x: cocoa.x - 90, y: cocoa.y - 40, width: 180, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Hagig synthetic input canary"
        window.isReleasedWhenClosed = false
        receiverWindow = window
        let canary = InputCanary(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
        canary.isRichText = false
        canary.allowsUndo = false
        window.contentView = canary
        inputCanary = canary
        try require(screen.visibleFrame.contains(window.frame))
        try await showReceiver(window)
        try warpCursor(to: point)
        guard let canaryWindow = try inputWindow(at: point, pid: getpid()) else { throw ProofFailure.gate }
        try require(canaryWindow.number == window.windowNumber)
        let local = CGPoint(x: point.x - canaryWindow.frame.minX, y: canaryWindow.frame.maxY - point.y)
        try require(canary.bounds.contains(canary.convert(local, from: nil)))
        let positiveMouse = try mousePair(at: point, window: canaryWindow)
        try check()
        try require(receiverIsFocused(window))
        // The sole non-shell dispatch: explicitly prove the driver's receiving
        // control works before treating zero receipt as a negative result.
        for event in positiveMouse { event.postToPid(getpid()) }
        let clickEnd = Date().addingTimeInterval(2)
        while canary.counts[0] == 0 && Date() < clickEnd { try await pause(0.05) }
        print("input-canary.positive clicks=\(canary.counts[0]) first-responder=\(window.firstResponder === canary) focused=\(receiverIsFocused(window))")
        try require(canary.counts[0] == 1 && window.firstResponder === canary)
        let positiveKey = try keyPair(0, text: "q")
        try check()
        try require(receiverIsFocused(window))
        for event in positiveKey { event.postToPid(getpid()) }
        let keyEnd = Date().addingTimeInterval(2)
        while canary.counts != [1, 1, 1, 1] && Date() < keyEnd { try await pause(0.05) }
        try require(canary.counts == [1, 1, 1, 1] && canary.string == "q")
        let received = canary.counts
        print("PASS input-canary.positive targeted-own-PID click=1 key-down=1 key-up=1 text=1")

        try await restoreShell(using: control)
        try require(canary.counts == received && canary.string == "q")
        stage = "driver.input-canary-focus-race"
        // Validate the actual shell target/focus, then deliberately put only our
        // receiving window over that point and make it frontmost. Reuse the
        // retained shell PID after this controlled check-to-dispatch focus race.
        let pid = try shellInputPID()
        try require(try targetPoint(control) == point)
        _ = try ownedHit(at: point)
        _ = try focused()
        guard let shellWindow = try inputWindow(at: point, pid: pid) else { throw ProofFailure.gate }
        let negativeMouse = try mousePair(at: point, window: shellWindow)
        let negativeKey = try keyPair(0, text: "q")
        try await showReceiver(window)
        try warpCursor(to: point)
        try require(try shellInputPID() == pid)
        try require(receiverIsFocused(window) && window.firstResponder === canary)
        // Key first so mouse-triggered shell activation cannot invalidate the
        // keyboard race control. No global dispatch is permitted in either pair.
        for event in negativeKey { event.postToPid(pid) }
        try require(try shellInputPID() == pid)
        try require(receiverIsFocused(window))
        for event in negativeMouse { event.postToPid(pid) }
        try await pause(0.5)
        try require(canary.counts == received && canary.string == "q")
        print("PASS input-canary.focus-race shell-PID-targeted driver-click-key-text-receipt=0")
        try await restoreShell(using: control)
        try require(canary.counts == received && canary.string == "q")
        window.close()
        receiverWindow = nil
        inputCanary = nil
        inputControlPassed = true
    }

    func startRecording() async throws {
        stage = "recording.owned-filter-start"
        try captureIdentity()
        try require(inputControlPassed && receiverWindow == nil && inputCanary == nil)
        guard let shellPID, let backdrop else { throw ProofFailure.gate }
        let session = RecordingSession(pid: shellPID, deadline: deadline)
        recording = session
        try await session.start(displayID: CGMainDisplayID(), backdropID: CGWindowID(backdrop.windowNumber))
        try captureIdentity()
        print("INSPECT exclusion-canary magenta-then-cyan must-never-appear including-transparent-edges")
        try await pause(0.5)
        backdrop.backgroundColor = .cyan
        try await pause(0.5)
    }

    func finishRecording() async throws {
        try captureIdentity()
        guard let recording else { throw ProofFailure.gate }
        try await recording.finish()
        try captureIdentity()
    }

    func run() async throws {
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
        stage = "driver.synthetic-exclusion-backdrop"
        try prepareBackdrop()
        stage = "shell.launch-identity"
        shell.executableURL = executable
        shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
        try shell.run()
        shellPID = shell.processIdentifier
        app = AXUIElementCreateApplication(shell.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        _ = try await awaitName("Simulate recording")
        try require(NSRunningApplication(processIdentifier: shell.processIdentifier)?.executableURL?.resolvingSymlinksInPath() == executable)
        print("PASS shell.owned-fresh-process")
        stage = "driver.negative-input-owner"
        do {
            // Exact same pre-event guard as normal pointer input; the driver
            // owns the canary, but is deliberately NOT an allowed input PID.
            try await click(AXUIElementCreateApplication(getpid()))
            throw ProofFailure.gate
        } catch ProofFailure.foreignTarget {
            print("PASS negative-input-owner driver-PID-rejected-before-event")
        }
        try await proveInputIsolation()
        stage = "standard.result-no-copy"
        try await beginReview()
        try clipboard(canary)
        try await startRecording()
        stage = "standard.pointer-editor"
        try await click(await awaitName("Transcript editor"))
        stage = "standard.editor-focus"
        try await editorFocused()
        stage = "standard.replace-select-all"
        try await key(0, flags: .maskCommand)
        stage = "standard.type-unicode-multiline"
        try await type(standard)
        stage = "standard.verify-edited-text"
        try await expectText(standard)
        stage = "standard.verify-no-copy"
        try clipboard(canary)
        stage = "standard.verify-select-all"
        try await key(0, flags: .maskCommand)
        try require(await selectedLength() == standard.utf16.count)
        print("PASS standard.focused-AXTextArea unicode-multiline-edit selection")
        stage = "standard.copy-cut-undo"
        try await key(8, flags: .maskCommand); try clipboard(standard)
        board.prepareForNewContents(with: .currentHostOnly)
        try require(board.setString(canary, forType: .string))
        try await key(7, flags: .maskCommand); try await expectText(""); try clipboard(standard)
        try await key(6, flags: .maskCommand); try await expectText(standard)
        try await key(53); try await expectText(standard)
        board.prepareForNewContents(with: .currentHostOnly)
        try require(board.setString(canary, forType: .string))
        let copyButton = try find("Copy all") ?? find("Copied")
        guard let copyButton else { throw ProofFailure.gate }
        try await click(copyButton); try clipboard(standard)
        print("PASS standard.keyboard-copy-cut-undo escape-retains-review pointer-copy")
        stage = "standard.pointer-dismiss"
        try await click(await awaitName("Dismiss")); try await pause()
        try await click(await awaitName("Show menu-bar surface"))
        _ = try await awaitName("Ready when you are")
        try require(find("Transcript editor") == nil); try clipboard(standard)
        print("PASS standard.pointer-dismiss ready-after-reopen clipboard-unchanged")
        stage = "vim.demo-picker"
        let demo = try await awaitName("Hagig · Demo controls")
        let popups = try nodes(in: demo).filter { (attribute($0, kAXRoleAttribute) as? String) == "AXPopUpButton" }
        let pickers = popups.filter { (attribute($0, kAXIdentifierAttribute) as? String) == "synthetic-editor-mode" }
        print("picker.popup-count=\(popups.count) mode-match-count=\(pickers.count)")
        try require(pickers.count == 1)
        try await click(pickers[0]); try await click(await awaitName("Bounded Vim"))
        print("picker.vim-value=\((attribute(pickers[0], kAXValueAttribute) as? String) == "Bounded Vim") vim-name=\(named(pickers[0], "Bounded Vim"))")
        print("picker.menu-item-remains=\(try find("Bounded Vim") != nil)")
        stage = "vim.begin-review"
        try await beginReview(); try clipboard(standard)
        stage = "vim.mode-label"
        let modeLabels = try nodes().filter { (attribute($0, kAXRoleAttribute) as? String) == "AXStaticText" }
        for (mode, label) in [("standard", "Standard"), ("vim-normal", "Vim · Normal")] {
            let labelled = "Editor mode: " + label
            print("mode.\(mode).named=\(modeLabels.contains { named($0, labelled) }) value=\(modeLabels.contains { let value = attribute($0, kAXValueAttribute) as? String; return value == label || value == labelled })")
        }
        try await awaitMode("Vim · Normal")
        stage = "vim.focus-insert-escape"
        try await click(await awaitName("Transcript editor")); try await editorFocused()
        try await key(34); try await key(0, flags: .maskCommand); try await type(vim); try await key(53)
        try await expectText(vim)
        try await awaitMode("Vim · Normal")
        try clipboard(standard)
        print("PASS vim.focus insert-unicode-multiline escape-normal no-copy")
        stage = "vim.visual-delete-undo-register"
        // gg, v, l, x, u use real key events, not editor methods/AX setters.
        try await key(5); try await key(5); try await key(9); try await key(37)
        try require(await selectedLength() == 2)
        try await awaitMode("Vim · Visual")
        try await key(7); try await expectText(String(vim.dropFirst(2)))
        try await key(32); try await expectText(vim)
        try await key(16); try await key(16); try clipboard(standard)
        print("PASS vim.visual-selection delete undo internal-register-no-copy")
        stage = "vim.keyboard-copy-dismiss"
        try await key(8, flags: [.maskCommand, .maskShift]); try clipboard(vim)
        stage = "vim.native-paste-normal-cursor"
        try await key(0, flags: .maskCommand); try await key(9, flags: .maskCommand)
        try await expectText(vim); try await awaitMode("Vim · Normal")
        try await key(7); try await expectText(String(vim.dropLast()))
        try await key(32); try await expectText(vim); try clipboard(vim)
        print("PASS vim.native-paste normal-cursor delete undo clipboard-unchanged")
        stage = "vim.keyboard-dismiss"
        try await key(2, flags: [.maskCommand, .maskShift]); try await pause()
        try await click(await awaitName("Show menu-bar surface"))
        _ = try await awaitName("Ready when you are")
        try require(find("Transcript editor") == nil); try clipboard(vim)
        print("PASS vim.keyboard-copy-all keyboard-dismiss ready-after-reopen clipboard-unchanged")
        stage = "recording.finalize"
        backdrop?.backgroundColor = .magenta
        try await pause(0.5)
        try await finishRecording()
        try captureIdentity()
    }

    func cleanup() async -> Bool {
        if shell.isRunning { shell.terminate() }
        // Failure cleanup shares the global bound and cannot extend an active
        // recording past its ceiling. Process exit releases any stalled stream.
        var end = min(deadline, Date().addingTimeInterval(5))
        if let recording { end = min(end, recording.cleanupDeadline) }
        let recordingStopped = await recording?.shutdown(until: end) ?? true
        let killAt = min(end.addingTimeInterval(-0.5), Date().addingTimeInterval(4))
        while shell.isRunning && Date() < end {
            if shell.isRunning && Date() >= killAt { kill(shell.processIdentifier, SIGKILL) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if shell.isRunning { kill(shell.processIdentifier, SIGKILL) }
        let shellStopped = !shell.isRunning
        receiverWindow?.close()
        receiverWindow = nil
        inputCanary = nil
        backdrop?.close()
        backdrop = nil
        if seededClipboard {
            if let value = board.string(forType: .string), syntheticCopies.contains(value) {
                board.prepareForNewContents(with: .currentHostOnly)
                print("cleanup synthetic-clipboard-cleared")
            } else { print("cleanup unknown-or-empty-clipboard-preserved") }
        }
        print("cleanup owned-shell-stopped=\(shellStopped) owned-recorder-stopped=\(recordingStopped)")
        return recordingStopped && shellStopped
    }

    func publishCandidate() throws {
        try check()
        try require(!shell.isRunning && inputControlPassed && receiverWindow == nil && inputCanary == nil)
        guard let recording else { throw ProofFailure.gate }
        // No movie enters the artifact directory before successful cleanup.
        // Canary exclusion and visual fidelity remain inspection gates.
        try recording.publish(to: output.appendingPathComponent("interaction.mov"))
        print("CANDIDATE interaction-assertions; INSPECT canary-exclusion transparency cursor live-popovers focus; no-shell-counterfactual")
    }

    func discardTemporaryMovie() -> Bool {
        recording?.discard() ?? true
    }
}

@main
private struct ShellInteraction {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { print("UNPROVEN arguments"); exit(2) }
        guard #available(macOS 15.0, *) else { print("UNPROVEN macOS15-required"); exit(2) }
        signal(SIGINT) { _ in proofInterrupted = 1 }
        signal(SIGTERM) { _ in proofInterrupted = 1 }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let driver = ShellProof(executable: URL(fileURLWithPath: CommandLine.arguments[1]),
                                output: URL(fileURLWithPath: CommandLine.arguments[2]))
        Task { @MainActor in
            var passed = false
            do { try await driver.run(); passed = true }
            catch { print("UNPROVEN stage=\(driver.stage)") }
            let cleaned = await driver.cleanup()
            if passed && cleaned {
                do { try driver.publishCandidate() }
                catch { passed = false; print("UNPROVEN candidate-publication") }
            }
            let discarded = driver.discardTemporaryMovie()
            exit(passed && cleaned && discarded ? 0 : 1)
        }
        // Service AppKit events for the synthetic backdrop while async waits
        // yield MainActor; no nested run-loop or blocking semaphore waits.
        application.run()
    }
}
#endif
