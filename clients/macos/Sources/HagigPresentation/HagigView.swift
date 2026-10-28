import SwiftUI

/// The shell and image harness both render this view; no screenshot-only UI.
@MainActor
public struct HagigView: View {
    @ObservedObject private var presentation: Presentation
    private let copy: (String) -> Bool
    private let animateActivity: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var reduceMotion: Bool { systemReduceMotion || !animateActivity }
    private var blue: Color {
        colorScheme == .dark ? Color(red: 0.57, green: 0.72, blue: 1) :
            Color(red: 49 / 255, green: 95 / 255, blue: 187 / 255)
    }
    private var ink: Color {
        colorScheme == .dark || contrast == .increased ? Color(nsColor: .labelColor) :
            Color(red: 32 / 255, green: 48 / 255, blue: 68 / 255)
    }
    private var secondary: Color {
        colorScheme == .dark || contrast == .increased ? Color(nsColor: .secondaryLabelColor) :
            Color(red: 82 / 255, green: 100 / 255, blue: 123 / 255)
    }
    private var inset: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) :
            Color(red: 237 / 255, green: 241 / 255, blue: 247 / 255)
    }
    private var warning: Color {
        colorScheme == .dark ? Color(red: 0.94, green: 0.73, blue: 0.38) :
            Color(red: 135 / 255, green: 85 / 255, blue: 18 / 255)
    }

    public init(presentation: Presentation, animateActivity: Bool = true, copy: @escaping (String) -> Bool) {
        self.presentation = presentation
        self.animateActivity = animateActivity
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(blue)
                Text("Hagig").fontWeight(.semibold)
                Spacer()
                Text("Parakeet · English").font(.system(size: 10)).foregroundStyle(secondary)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            Divider()
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Circle().fill(isWarning ? warning : blue).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(title).font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: 330)
        // Opaque surfaces also work with Reduce Transparency; no custom glass.
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) :
            Color(red: 251 / 255, green: 252 / 255, blue: 254 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .tint(blue)
        .onExitCommand { presentation.cancel() }
    }

    private var isWarning: Bool {
        switch presentation.stage {
        case .fallback, .noSpeech, .issue: return true
        default: return false
        }
    }

    private var title: String {
        switch presentation.stage {
        case .ready: return "Ready when you are"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .fallback: return "Destination unverified"
        case .cancelled: return "Cancelled"
        case .noSpeech: return "No speech recognized"
        case .issue(let issue): return issue.title
        }
    }

    @ViewBuilder private var content: some View {
        switch presentation.stage {
        case .ready:
            description("Hold your shortcut and speak into the focused input.")
            HStack(spacing: 7) {
                ForEach(["⌃", "⇧", "Space"], id: \.self) { key in
                    Text(key)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(inset, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(secondary.opacity(contrast == .increased ? 1 : 0.35)))
                }
            }
            .padding(.top, 11)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example shortcut: Control Shift Space")
            Text("Example shortcut · configurable in TOML")
                .font(.system(size: 11)).foregroundStyle(secondary)
        case .recording:
            description("Release the shortcut to transcribe.\nEscape cancels and discards the audio.")
            HStack(spacing: 8) {
                RecordingIndicator(reduceMotion: reduceMotion)
                Text("Microphone capture")
            }
            .font(.system(size: 12))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(inset, in: RoundedRectangle(cornerRadius: 7))
            .padding(.vertical, 11)
            cancelButton
        case .transcribing:
            description("Turning your recording into text.\nNothing has been delivered.")
            HStack(spacing: 8) {
                if reduceMotion {
                    Circle().trim(from: 0.1, to: 0.85).stroke(blue, lineWidth: 2)
                        .frame(width: 15, height: 15).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text("Processing audio")
            }
            .font(.system(size: 12))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(inset, in: RoundedRectangle(cornerRadius: 7))
            .padding(.vertical, 11)
            cancelButton
        case .fallback:
            description("Nothing pasted. Copy the text, then choose where to paste it.", color: warning)
            Text(presentation.transcript ?? "")
                .font(.system(size: 14)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14).padding(.trailing, 52).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(inset, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    Button {
                        presentation.copy(using: copy)
                    } label: {
                        Image(systemName: presentation.copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(presentation.copied ? "Copied. Copy transcript again" : "Copy transcript")
                    .help(presentation.copied ? "Copied" : "Copy transcript")
                    .padding(8)
                }
                .padding(.vertical, 4)
            if presentation.copied { Text("Copied").font(.system(size: 11)).foregroundStyle(secondary) }
            Button("Dismiss") { presentation.reset() }
                .keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
        case .cancelled:
            description("This request was discarded.\nNothing will be delivered from it.")
            backButton
        case .noSpeech:
            description("Nothing to copy or paste. Try a new recording.")
            backButton
        case .issue(let issue):
            description(issue.recovery)
            backButton
        }
    }

    private func description(_ text: String, color: Color? = nil) -> some View {
        Text(text).foregroundStyle(color ?? secondary).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelButton: some View {
        Button("Cancel") { presentation.cancel() }.keyboardShortcut(.cancelAction)
            .frame(maxWidth: .infinity)
    }
    private var backButton: some View {
        Button { presentation.reset() } label: {
            Text("Back to ready").frame(maxWidth: .infinity)
        }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding(.top, 7)
    }
}

private struct RecordingIndicator: View {
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false

    var body: some View {
        Circle().fill(colorScheme == .dark ? Color(red: 1, green: 0.49, blue: 0.56) :
            Color(red: 176 / 255, green: 48 / 255, blue: 67 / 255))
            .frame(width: 7, height: 7)
            .padding(5)
            .background(Color.red.opacity(0.08), in: Circle())
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
