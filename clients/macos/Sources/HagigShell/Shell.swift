import AppKit
import SwiftUI
import HagigPresentation

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let presentation = Presentation()
    private var demoWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Hagig synthetic demo")
        statusItem.button?.toolTip = "Hagig · synthetic demo. Right-click for demo controls."
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            HagigView(presentation: presentation, copy: Self.copy)
        )
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
            demoWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.setString(text, forType: .string)
    }
}

/// Simulation stays outside the production-facing popover. Only its Copy button
/// writes to the clipboard; these controls never deliver a synthetic result.
@MainActor
private struct DemoControls: View {
    @ObservedObject var presentation: Presentation
    let showPopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Synthetic demo", systemImage: "flask").font(.headline)
            Text("No microphone, inference, global shortcut, or automatic paste. All results are synthetic. Only explicit Copy in the popover writes to this Mac’s clipboard.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Right-click the menu-bar microphone to reopen these controls.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show menu-bar surface", action: showPopover)
            HStack {
                Button("Simulate recording") { presentation.begin(); showPopover() }
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
        .onExitCommand { presentation.cancel() }
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
