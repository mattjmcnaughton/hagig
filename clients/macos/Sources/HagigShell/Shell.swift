import AppKit
import SwiftUI
import HagigPresentation

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let presentation = Presentation()
    private var demoWindow: NSWindow!
    private var escapeMonitor: Any?
    private let synthetic = CommandLine.arguments.contains("--synthetic-demo")
    private lazy var dictation = DictationController(presentation: presentation,
        helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hagig"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: synthetic ? "Hagig synthetic demo" : "Hagig")
        statusItem.button?.toolTip = synthetic ? "Hagig · synthetic demo. Right-click for demo controls." : "Hagig · Record, review, Copy. Right-click to quit."
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            HagigView(presentation: presentation,
                      record: { [weak self] in
                          guard let self else { return }
                          if synthetic { presentation.begin() } else { dictation.record() }
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
        } else {
            showPopover()
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
