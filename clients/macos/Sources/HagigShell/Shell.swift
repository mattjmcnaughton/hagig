import AppKit
import AVFoundation
import Combine
import SwiftUI
import HagigPresentation

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let presentation = Presentation()
    private var demoWindow: NSWindow!
    private var escapeMonitor: Any?
    private var stageObserver: AnyCancellable?
    /// Record was chosen while microphone access was undecided, so macOS will
    /// show its prompt for this request, which closes the transient popover.
    private var microphonePromptExpected = false
    private let synthetic = CommandLine.arguments.contains("--synthetic-demo")
    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hagig")
    private lazy var dictation = DictationController(presentation: presentation, helper: helper)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            HagigView(presentation: presentation,
                      // Setup instructions name the paired helper only when it exists.
                      setup: SetupGuide(helperPath: FileManager.default.isExecutableFile(atPath: helper.path)
                          ? helper.path : nil),
                      record: { [weak self] in
                          guard let self else { return }
                          if synthetic {
                              presentation.begin()
                          } else {
                              let undecided = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                              dictation.record()
                              // Set after record(): reserving a request passes through Ready first.
                              microphonePromptExpected = undecided && presentation.stage == .awaitingAdmission
                          }
                      }, stop: { [weak self] in
                          guard let self else { return }
                          if synthetic { presentation.release() } else { dictation.stop() }
                      }, cancel: { [weak self] in
                          guard let self else { return }
                          if synthetic { presentation.cancel() } else { dictation.cancel() }
                      }, copy: Self.copy)
        )
        // Handle active cancellation before normal popover key processing.
        // Only events delivered to this app, and never review-mode Escape.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  [.awaitingAdmission, .recording, .transcribing].contains(presentation.stage) else { return event }
            if synthetic { presentation.cancel() } else { dictation.cancel() }
            return nil
        }
        // The menu-bar item is the only sign of work while the popover is closed.
        // @Published delivers the new stage before storing it, hence the argument.
        stageObserver = presentation.$stage.sink { [weak self] stage in self?.reflect(stage) }
        // Explicit test/demo mode is never selected by a backend/capture failure.
        guard synthetic else { return }
        demoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        demoWindow.title = "Hagig · Demo controls"
        demoWindow.isReleasedWhenClosed = false
        let demoController = NSHostingController(rootView:
            DemoControls(presentation: presentation, showPopover: showPopover)
        )
        demoWindow.contentViewController = demoController
        demoWindow.setContentSize(demoController.view.fittingSize)
        demoWindow.center()
        demoWindow.makeKeyAndOrderFront(nil)
        // Activate only the explicit demo harness, never an intended destination.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The user opened Hagig's own surface: take the keyboard so Return, Escape
    /// and the review editor work at once. Never used for the demo harness, and
    /// never activates any other application.
    private func showPopoverForKeyboard() {
        showPopover()
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func reflect(_ stage: DemoStage) {
        let symbol: String, state: String
        switch stage {
        case .ready, .cancelled, .noSpeech: (symbol, state) = ("mic", "Ready")
        case .awaitingAdmission: (symbol, state) = ("mic", "Preparing to record")
        case .recording: (symbol, state) = ("mic.fill", "Recording")
        case .transcribing: (symbol, state) = ("waveform", "Transcribing")
        case .fallback: (symbol, state) = ("text.cursor", "Transcript ready to review")
        case .issue: (symbol, state) = ("exclamationmark.triangle", "Needs attention")
        }
        let name = synthetic ? "Hagig synthetic demo" : "Hagig"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        if stage == .recording {
            // Template images take the menu bar's colour; recording is the one
            // state drawn in the system red instead.
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
        }
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityValue(state)
        statusItem.button?.toolTip = synthetic ? "Hagig synthetic demo: \(state). Right-click for demo controls."
            : "Hagig: \(state). Right-click to quit."
        // The macOS microphone prompt closes the transient popover. Only for the
        // request that showed it, bring back what the user's answer led to: Stop
        // after Allow, or the way to System Settings after Don't Allow. A popover
        // closed any other way was the user's choice, perhaps to work in another
        // application, and nothing here reopens it or takes focus.
        // Every transition passes through Ready (`Presentation.reset`), so only
        // a settled stage answers or abandons the expectation.
        guard stage != .awaitingAdmission, stage != .ready else { return }
        let answered = stage == .recording || stage == .issue(.microphonePermission)
        let reopen = microphonePromptExpected && answered && !popover.isShown
        microphonePromptExpected = false
        if reopen {
            DispatchQueue.main.async { [weak self] in
                guard let self, presentation.stage == stage, !popover.isShown else { return }
                showPopoverForKeyboard()
            }
        }
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            if synthetic {
                demoWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if let button = statusItem.button {
                let menu = NSMenu()
                let quit = menu.addItem(withTitle: "Quit Hagig", action: #selector(ShellDelegate.quit), keyEquivalent: "")
                quit.target = self
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if synthetic {
            showPopover()
        } else {
            showPopoverForKeyboard()
        }
    }

    private static func copy(_ text: String) -> Bool {
        LocalClipboard().write(text)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if !synthetic { dictation.cancel() }
    }
}

/// Simulation stays outside the production-facing popover. Only its Copy button
/// writes to the clipboard; these controls never deliver a synthetic result.
@MainActor
private struct DemoControls: View {
    @ObservedObject var presentation: Presentation
    let showPopover: () -> Void
    @State private var demoMode = EditorMode.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Synthetic demo", systemImage: "flask").font(.headline)
            Text("No microphone, inference, global shortcut, or automatic paste. All results are synthetic. Only explicit Copy in the popover writes to this Mac’s clipboard.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Right-click the menu-bar microphone to reopen these controls.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Synthetic editor mode (not TOML)", selection: $demoMode) {
                Text("Standard").tag(EditorMode.standard)
                Text("Bounded Vim").tag(EditorMode.vim)
            }
            .accessibilityIdentifier("synthetic-editor-mode")
            Button("Show menu-bar surface", action: showPopover)
            HStack {
                Button("Simulate recording") { presentation.begin(editorMode: demoMode); showPopover() }
                    .disabled(presentation.stage == .recording || presentation.stage == .transcribing)
                Button("Simulate release") { presentation.release(); showPopover() }
                    .disabled(presentation.stage != .recording)
            }
            Button("Simulate result") {
                if let id = presentation.requestID {
                    presentation.complete(requestID: id, text: Presentation.fixture)
                    showPopover()
                }
            }.disabled(presentation.stage != .transcribing)
            HStack {
                Menu("Preview error") {
                    ForEach(DemoIssue.allCases, id: \.self) { issue in
                        Button(issue.title) { presentation.show(issue: issue); showPopover() }
                    }
                }
                Button("Reset") { presentation.reset(); showPopover() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("No app-maintained transcript history. Local clipboard managers may retain copied text.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
        .onExitCommand {
            if presentation.stage == .recording || presentation.stage == .transcribing { presentation.cancel() }
        }
    }
}

@main
struct Shell {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ShellDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
