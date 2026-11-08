// Separate-process synthetic receiving control; never linked into Hagig.
import AppKit

@MainActor
private final class Receiver: NSView {
    private var clicks = 0, downs = 0, ups = 0
    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        setAccessibilityValue("clicks=\(clicks) down=\(downs) up=\(ups)")
    }

    override func mouseDown(with event: NSEvent) {
        clicks += 1
        window?.makeFirstResponder(self)
        refresh()
    }

    override func keyDown(with event: NSEvent) { downs += 1; refresh() }
    override func keyUp(with event: NSEvent) { ups += 1; refresh() }
}

@MainActor
private final class CanaryDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        guard let x = Double(env["PROBE_X"] ?? ""), let y = Double(env["PROBE_Y"] ?? ""),
              x.isFinite, y.isFinite, let screen = NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }
        let frame = CGRect(x: x - 90, y: screen.frame.maxY - y - 40, width: 180, height: 80)
        guard screen.visibleFrame.contains(frame) else { NSApp.terminate(nil); return }
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Hagig synthetic receiving canary"
        window.isReleasedWhenClosed = false
        let receiver = Receiver(frame: CGRect(origin: .zero, size: frame.size))
        receiver.setAccessibilityElement(true)
        receiver.setAccessibilityRole(.textArea)
        receiver.setAccessibilityIdentifier("probe-input")
        receiver.refresh()
        window.contentView = receiver
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
private struct Canary {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = CanaryDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
