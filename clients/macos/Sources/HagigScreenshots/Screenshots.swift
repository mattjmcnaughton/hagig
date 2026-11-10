import AppKit
import SwiftUI
import HagigPresentation

private enum CaptureError: Error { case usage, renderFailed }

/// Native view rendering, not a screen capture or an XCTest app-interaction test.
@main
struct Screenshots {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["proof", "states"].contains(arguments[1]) else {
            throw CaptureError.usage // HagigScreenshots <proof|states> <output-directory>
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = arguments[1] == "proof" ? ["ready"] :
            ["ready", "awaitingAdmission", "recording", "nearLimit", "transcribing", "fallback", "copied", "cancelled", "noSpeech"] + DemoIssue.allCases.map(\.rawValue)
        for name in names {
            // Bounded synthetic gallery: review exercises Standard and Vim,
            // multiline Unicode and the current edited buffer through shared UI.
            let presentation = Presentation(editorMode: name == "copied" ? .vim : .standard)
            if let issue = DemoIssue(rawValue: name) {
                presentation.show(issue: issue)
            } else if name == "awaitingAdmission" {
                presentation.reserve()
            } else if name != "ready" {
                presentation.begin()
                if name == "nearLimit", let id = presentation.requestID {
                    presentation.warnNearLimit(requestID: id)
                }
                if !["recording", "nearLimit"].contains(name) { presentation.release() }
                if ["fallback", "copied", "noSpeech"].contains(name), let id = presentation.requestID {
                    presentation.complete(requestID: id, text: name == "noSpeech" ? "" : Presentation.fixture)
                }
                if name == "copied" {
                    presentation.edit("Synthetic edited review 😀\nCover cancellation and e\u{301} / 日本語 bounds.",
                                      session: presentation.editorID)
                    presentation.copy { _ in true }
                }
                if name == "cancelled" { presentation.cancel() }
            }
            for dark in [false, true] {
                let view = HagigView(presentation: presentation, animateActivity: false, copy: { _ in false })
                    .environment(\.colorScheme, dark ? .dark : .light)
                // ImageRenderer omits AppKit-backed controls. Cache the hosted native view
                // instead; capture only its bounds, never the runner's desktop.
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.orderFront(nil)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                hosting.displayIfNeeded()
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                    pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ) else { throw CaptureError.renderFailed }
                bitmap.size = size
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                window.close()
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CaptureError.renderFailed
                }
                try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        print("Rendered \(names.count * 2) native PNGs (2×, activity animation disabled).")
    }
}
