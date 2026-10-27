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
            ["ready", "recording", "transcribing", "fallback", "copied", "cancelled", "noSpeech"] + DemoIssue.allCases.map(\.rawValue)
        for name in names {
            let presentation = Presentation()
            if let issue = DemoIssue(rawValue: name) {
                presentation.show(issue: issue)
            } else if name != "ready" {
                presentation.begin()
                if name != "recording" { presentation.release() }
                if ["fallback", "copied", "noSpeech"].contains(name), let id = presentation.requestID {
                    presentation.complete(requestID: id, text: name == "noSpeech" ? " \n" : Presentation.fixture)
                }
                if name == "copied" { presentation.copy { _ in true } }
                if name == "cancelled" { presentation.cancel() }
            }
            for dark in [false, true] {
                let view = HagigView(presentation: presentation, copy: { _ in false })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.accessibilityReduceMotion, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { throw CaptureError.renderFailed }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CaptureError.renderFailed
                }
                try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        print("Rendered \(names.count * 2) native PNGs (2×, reduced motion).")
    }
}
