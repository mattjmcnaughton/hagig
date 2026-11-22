import SwiftUI

/// What setup instructions name. The shell passes the paired bundle's own helper;
/// the render harness passes a synthetic path. Shown and copied, never executed.
public struct SetupGuide: Equatable {
    public let helperPath: String?
    public init(helperPath: String? = nil) { self.helperPath = helperPath }

    /// A settings file that only chooses a model (backend `config.py`).
    static let exampleSettings = "[model]\nid = \"qwen3-asr-0.6b\""

    /// The explicit install the user runs in a terminal (TDD §4), or nil when the
    /// helper or a plain model alias is not known.
    func installCommand(modelID: String?) -> String? {
        guard let helperPath, let modelID, !modelID.isEmpty,
              modelID.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || "0123456789.-_".unicodeScalars.contains($0)) })
        else { return nil }
        return "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "' model install " + modelID
    }
}

/// The registered shortcuts' display strings (`Shortcut.display`), for the
/// shortcut panel's recording hint.
public struct PanelShortcuts: Equatable {
    public let record: String
    public let cancel: String
    public init(record: String, cancel: String) { self.record = record; self.cancel = cancel }
}

/// Display names for the tracked manifest aliases (`backend/src/hagig/manifests`),
/// which own the IDs. An alias this build does not know is shown as it is.
func modelDisplayName(_ id: String) -> String {
    switch id {
    case "qwen3-asr-0.6b": return "Qwen3-ASR 0.6B"
    case "qwen3-asr-1.7b": return "Qwen3-ASR 1.7B"
    case "whisper-large-v3-turbo": return "Whisper large-v3 turbo"
    default: return id
    }
}

/// The shell and image harness both render this view; no screenshot-only UI.
///
/// It paints no surface of its own. The popover supplies the material and shape
/// (Sequoia's popover material, Liquid Glass when linked against the macOS 26
/// SDK), and everything here is a stock control, a system colour or a label
/// style, so each macOS draws it in its own design language, including Reduce
/// Transparency and Increase Contrast.
@MainActor
public struct HagigView: View {
    @ObservedObject private var presentation: Presentation
    private let copy: (String) -> Bool
    private let animateActivity: Bool
    private let clock: Date?
    private let setup: SetupGuide
    private let record: () -> Void
    private let stop: () -> Void
    private let cancel: () -> Void
    private let preferences: Preferences?
    private let loginItem: LoginItem?
    /// Set while the surface is in the shortcut panel, which is not key, so
    /// Return and Escape reach the user's app; the hint names these instead.
    private var panelShortcuts: PanelShortcuts?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.openURL) private var openURL
    private var reduceMotion: Bool { systemReduceMotion || !animateActivity }
    /// A recessed panel on whatever material the popover provides.
    static let panel = Color.primary.opacity(0.06)

    /// `clock` fixes the time for deterministic renders; nil follows the system
    /// clock. `setup` names the paired helper in setup instructions. `loginItem`
    /// shows Open at login in Settings; nil hides it.
    public init(presentation: Presentation, animateActivity: Bool = true, clock: Date? = nil,
                setup: SetupGuide = SetupGuide(), preferences: Preferences? = nil, loginItem: LoginItem? = nil,
                record: @escaping () -> Void = {}, stop: @escaping () -> Void = {},
                cancel: (() -> Void)? = nil, copy: @escaping (String) -> Bool) {
        self.presentation = presentation
        self.animateActivity = animateActivity
        self.clock = clock
        self.setup = setup
        self.preferences = preferences
        self.loginItem = loginItem
        self.record = record
        self.stop = stop
        self.cancel = cancel ?? { presentation.cancel() }
        self.copy = copy
    }

    /// The same view, with the recording hint for the shortcut panel (non-nil)
    /// or the popover (nil).
    public func inPanel(_ shortcuts: PanelShortcuts?) -> HagigView {
        var view = self
        view.panelShortcuts = shortcuts
        return view
    }

    public var body: some View {
        if let preferences {
            Paged(preferences: preferences) { surface(page: $0) }
        } else {
            surface(page: nil)
        }
    }

    /// Setup pages replace dictation only outside a request.
    private var idle: Bool {
        ![.awaitingAdmission, .recording, .transcribing, .fallback].contains(presentation.stage)
    }

    private func surface(page: Preferences.Page?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Hagig").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let model = presentation.modelID {
                    Text(modelDisplayName(model)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let language = presentation.language,
                       let name = Locale(identifier: "en").localizedString(forLanguageCode: language) {
                        Text(name).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                if let preferences, page == nil, idle {
                    Button { preferences.open(.models) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless).help("Speech models").accessibilityLabel("Speech models")
                    Button { preferences.open(.settings) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let preferences, let page, idle {
                    switch page {
                    case .models: ModelLibraryView(library: preferences)
                    case .settings: SettingsView(preferences: preferences, loginItem: loginItem)
                    }
                } else {
                    dictation
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .frame(width: 330)
        .onExitCommand {
            if [.awaitingAdmission, .recording, .transcribing].contains(presentation.stage) { cancel() }
            else if page != nil { preferences?.close() }
        }
    }

    @ViewBuilder private var dictation: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if case .issue = presentation.stage {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15))
                    .foregroundStyle(.orange).accessibilityHidden(true)
            }
            // The one serif line per state: the written word this app produces.
            Text(title).font(.system(size: 21, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        content
    }

    private var title: String {
        switch presentation.stage {
        case .ready: return "Ready when you are"
        case .awaitingAdmission: return "Preparing to record…"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .fallback: return "Review transcript"
        case .cancelled: return "Cancelled"
        case .noSpeech: return "No speech recognized"
        case .issue(let issue): return issue.title
        }
    }

    @ViewBuilder private var content: some View {
        switch presentation.stage {
        case .ready:
            description("Speak a prompt, review the text, then copy it wherever you need it.")
            action("Record", systemImage: "mic.fill", prominent: true, action: record)
                .keyboardShortcut(.defaultAction)
        case .awaitingAdmission:
            HStack(spacing: 7) {
                if reduceMotion {
                    Circle().trim(from: 0.1, to: 0.85).stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 13, height: 13).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text("Waiting for the service and microphone").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(12)
            .background(Self.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            description("Nothing is recording yet.")
            action("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        case .recording:
            trace {
                RecordingIndicator(reduceMotion: reduceMotion)
                ElapsedTime(started: presentation.recordingStarted, clock: clock)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                if presentation.nearLimit {
                    Text("Stops at 5:00").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
            }
            if let panelShortcuts {
                description("Press \(panelShortcuts.record) to stop (or release it if you’re holding it). \(panelShortcuts.cancel) discards the recording.")
            } else {
                description("Return stops and transcribes. Escape discards the recording.")
            }
            HStack(spacing: 8) {
                action("Cancel", width: 92, action: cancel).keyboardShortcut(.cancelAction)
                action("Stop", systemImage: "stop.fill", prominent: true, action: stop)
                    .keyboardShortcut(.defaultAction)
            }
        case .transcribing:
            trace {
                if reduceMotion {
                    Circle().trim(from: 0.1, to: 0.85).stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 13, height: 13).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text("Processing audio").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            description("Turning your recording into text. Nothing has been delivered.")
            action("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        case .fallback:
            ReviewEditor(presentation: presentation, write: copy)
                .id(presentation.editorID)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
            if presentation.editorMode == .vim {
                // Vim needs its mode visible (TDD §8); Standard has no mode to show.
                Text(presentation.editorLabel).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Editor mode: \(presentation.editorLabel)")
                    .accessibilityIdentifier("review-editor-mode")
            }
            HStack(spacing: 8) {
                action("Dismiss", width: 92) { presentation.reset() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .help("Discard this transcript (Command-Shift-D)")
                action(presentation.copied ? "Copied" : "Copy all",
                       systemImage: presentation.copied ? "checkmark" : "doc.on.doc", prominent: true) {
                    presentation.copy(using: copy)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(presentation.transcript?.isEmpty != false)
                .help("Copy entire edited transcript (Command-Shift-C)")
            }
        case .cancelled:
            description("That recording was discarded. Nothing will be delivered from it.")
            backButton
        case .noSpeech:
            description("Nothing was transcribed and nothing was copied. Check that the right microphone is selected, then record again.")
            backButton
        case .issue(let issue):
            description(issue.recovery)
            if let detail = presentation.issueDetail {
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Reported by the service: \(detail)")
            }
            switch issue {
            case .configuration:
                if let preferences {
                    action("Choose a model…", systemImage: "square.and.arrow.down") { preferences.open(.models) }
                    action("Open Settings", systemImage: "gearshape") { preferences.open(.settings) }
                } else {
                    Snippet(label: "A minimal settings file", text: SetupGuide.exampleSettings, copy: copy)
                }
            case .modelMissing:
                if let preferences {
                    action("Download a model…", systemImage: "square.and.arrow.down") { preferences.open(.models) }
                } else if let command = setup.installCommand(modelID: presentation.modelID) {
                    Snippet(label: "Run once in Terminal", text: command, copy: copy)
                }
            case .microphonePermission:
                action("Open Microphone Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        openURL(url)
                    }
                }
            default:
                EmptyView()
            }
            backButton
        }
    }

    private func description(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Every action is a full-row native button, or a fixed-width companion to one.
    @ViewBuilder
    private func action(_ title: String, systemImage: String? = nil, prominent: Bool = false,
                        width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
        }
        .controlSize(.large)
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private var backButton: some View {
        action("Back to ready", prominent: true) { presentation.reset() }
            .keyboardShortcut(.defaultAction)
    }

    /// The capture's own loudness, oldest to newest, above a status row. While
    /// transcribing the same trace stays, dimmed: that is what is being read.
    private func trace<Status: View>(@ViewBuilder status: () -> Status) -> some View {
        let recording = presentation.stage == .recording
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7, content: status)
            LevelTrace(levels: presentation.levels, bar: recording ? Color.accentColor : Color.secondary.opacity(0.6),
                       rest: Color.secondary.opacity(0.35), caret: recording ? Color.orange : nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Re-renders the surface when the page changes.
private struct Paged<Content: View>: View {
    @ObservedObject var preferences: Preferences
    let content: (Preferences.Page?) -> Content
    var body: some View { content(preferences.page) }
}

/// One capsule per capture chunk, newest at the right beside the caret where the
/// text will begin. Slots with no audio yet are dots; nothing is invented.
private struct LevelTrace: View {
    let levels: [Float]
    let bar: Color
    let rest: Color
    let caret: Color?

    var body: some View {
        let empty = max(Presentation.levelCount - levels.count, 0)
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Presentation.levelCount, id: \.self) { slot in
                if slot < empty {
                    Capsule().fill(rest).frame(width: 3, height: 3)
                } else {
                    Capsule().fill(bar).frame(width: 3, height: 3 + 27 * CGFloat(levels[slot - empty]))
                }
            }
            if let caret { Capsule().fill(caret).frame(width: 2, height: 30) }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

private struct ElapsedTime: View {
    let started: Date?
    let clock: Date?

    var body: some View {
        if let clock {
            text(at: clock)
        } else {
            TimelineView(.periodic(from: started ?? Date(), by: 1)) { text(at: $0.date) }
        }
    }

    private func text(at date: Date) -> some View {
        let seconds = min(max(Int(date.timeIntervalSince(started ?? date)), 0), 300)
        return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .accessibilityLabel("Recording time \(seconds / 60) minutes \(seconds % 60) seconds")
    }
}

/// Setup text the user needs elsewhere. Its Copy goes through the same
/// current-host-only writer as the transcript; the text is not selectable, so no
/// default responder can copy it another way.
private struct Snippet: View {
    let label: String
    let text: String
    let copy: (String) -> Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copied = copy(text)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .accessibilityLabel(copied ? "Copied: \(label)" : "Copy: \(label)")
            }
            Text(text).font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(HagigView.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecordingIndicator: View {
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        Circle().fill(.red)
            .frame(width: 7, height: 7)
            .padding(4)
            .background(Color.red.opacity(0.14), in: Circle())
            .scaleEffect(expanded && !reduceMotion ? 1.18 : 1)
            .task(id: reduceMotion) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { expanded = false }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        expanded = true
                    }
                }
            }
            .accessibilityHidden(true)
    }
}
