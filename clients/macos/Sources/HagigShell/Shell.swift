import AppKit
import SwiftUI
import HagigPresentation

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let presentation = Presentation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Hagig synthetic demo")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            VStack(spacing: 0) {
                HagigView(presentation: presentation, copy: Self.copy)
                Divider()
                HStack {
                    Menu("Preview error") {
                        ForEach(DemoIssue.allCases, id: \.self) { issue in
                            Button(issue.title) { self.presentation.show(issue: issue) }
                        }
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }.padding(12).frame(width: 360)
            }
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.setString(text, forType: .string)
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
