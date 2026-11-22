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
        let pages = ["models", "modelConsent", "modelDownloading", "modelFailed", "settings"]
        let names = arguments[1] == "proof" ? ["ready"] :
            ["ready", "awaitingAdmission", "recording", "nearLimit", "transcribing", "fallback", "copied", "cancelled", "noSpeech"] + DemoIssue.allCases.map(\.rawValue) + pages
        // Fixed synthetic inputs: a clock, a model alias, helper, settings and
        // logs paths and a loudness curve. None is a measurement, a recording or a real path.
        let clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let setup = SetupGuide(helperPath: "/Applications/Hagig.app/Contents/Helpers/hagig")
        // The tracked registry's names and sizes, as `hagig model list` reports
        // them; installed and in-use states are synthetic.
        func registry(installed: Set<String>) -> [ModelEntry] {
            [("qwen3-asr-0.6b", "Qwen3-ASR 0.6B", "qwen3-asr", "Qwen", "Qwen/Qwen3-ASR-0.6B-hf", "Apache-2.0", Int64(1_576_363_223)),
             ("qwen3-asr-1.7b", "Qwen3-ASR 1.7B", "qwen3-asr", "Qwen", "Qwen/Qwen3-ASR-1.7B-hf", "Apache-2.0", 4_087_628_216),
             ("whisper-large-v3-turbo", "Whisper large-v3 turbo", "mlx-whisper", "OpenAI", "openai/whisper-large-v3-turbo", "MIT", 1_617_826_120)]
                .map { ModelEntry(id: $0.0, name: $0.1, engine: $0.2, publisher: $0.3, repository: $0.4, license: $0.5,
                                  downloadBytes: $0.6, supported: true, installed: installed.contains($0.0) ? "installed" : "missing") }
        }
        for name in names {
            let preferences = Preferences(run: { _, _, _ in HelperExit(status: 0, error: nil) })
            switch name {
            case "models":
                preferences.preview(page: .models, models: registry(installed: ["qwen3-asr-0.6b"]), configured: "qwen3-asr-0.6b")
            case "modelConsent":
                preferences.preview(page: .models, models: registry(installed: []), configured: nil,
                                    pending: "whisper-large-v3-turbo")
            case "modelDownloading":
                preferences.preview(page: .models, models: registry(installed: []), configured: nil,
                                    download: .init(id: "qwen3-asr-0.6b", step: "download",
                                                    received: 612_000_000, total: 1_576_363_223))
            case "modelFailed":
                preferences.preview(page: .models, models: registry(installed: ["qwen3-asr-0.6b"]), configured: "qwen3-asr-0.6b",
                                    failure: .init(id: "qwen3-asr-1.7b", code: "download_failed: model.safetensors"))
            case "settings":
                preferences.preview(page: .settings, models: registry(installed: ["qwen3-asr-0.6b", "whisper-large-v3-turbo"]),
                                    configured: "whisper-large-v3-turbo",
                                    settings: StoredSettings(modelId: "whisper-large-v3-turbo", editorMode: "vim",
                                                             vocabulary: ["Hagig", "Ghostty", "Qwen"],
                                                             recordShortcut: "ctrl+option+space",
                                                             cancelShortcut: "ctrl+option+escape"),
                                    settingsPath: "/Users/you/.config/hagig/config.toml",
                                    logsDir: "/Users/you/.local/state/hagig/logs")
            default: break
            }
            // Bounded synthetic gallery: review exercises Standard and Vim,
            // multiline Unicode and the current edited buffer through shared UI.
            let presentation = Presentation()
            if !["ready", DemoIssue.configuration.rawValue].contains(name), !pages.contains(name) {
                // Every other state follows an admission, which names the model;
                // a settings problem stops the service before any admission.
                let id = presentation.reserve()
                if name != "awaitingAdmission" {
                    _ = presentation.admit(requestID: id, editorMode: name == "copied" ? .vim : .standard,
                                           modelID: "qwen3-asr-0.6b",
                                           started: clock.addingTimeInterval(name == "nearLimit" ? -287 : -12))
                    for step in 0..<(name == "nearLimit" ? Presentation.levelCount : 30) {
                        let phrase = abs(sin(Double(step) * 0.55)) * (0.35 + 0.5 * abs(sin(Double(step) * 0.13)))
                        presentation.recordLevel(Float(step % 11 == 9 ? 0.04 : 0.12 + phrase), requestID: id)
                    }
                }
            }
            if let issue = DemoIssue(rawValue: name) {
                presentation.show(issue: issue, detail: issue == .configuration ?
                    "config_invalid: model.id missing; set [model] id in /Users/you/.config/hagig/config.toml" : nil)
            } else if !["ready", "awaitingAdmission"].contains(name), !pages.contains(name) {
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
                // The view paints no surface: the popover does. This opaque
                // backdrop stands in for that material so the images are legible;
                // it is not what a popover looks like on any macOS.
                let view = HagigView(presentation: presentation, animateActivity: false, clock: clock,
                                     setup: setup, preferences: preferences, loginItem: .inert,
                                     revealLogs: { _ in }, // inert: shows the button, opens nothing
                                     copy: { _ in false })
                    .background(Color(nsColor: .windowBackgroundColor))
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
