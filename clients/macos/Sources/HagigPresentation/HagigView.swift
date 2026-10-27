import SwiftUI

/// The shell and image harness both render this view; no screenshot-only UI.
@MainActor
public struct HagigView: View {
    @ObservedObject private var presentation: Presentation
    private let copy: (String) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color(red: 0.19, green: 0.37, blue: 0.73)

    public init(presentation: Presentation, copy: @escaping (String) -> Bool) {
        self.presentation = presentation
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "mic").foregroundStyle(blue)
                Text("Hagig").fontWeight(.semibold)
                Spacer()
                Text("Parakeet · English").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Label("Synthetic demo · no microphone or inference", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Text("No app-maintained transcript history")
                .font(.caption2).foregroundStyle(.secondary).padding(14)
        }
        .font(.system(size: 13))
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(blue)
        .onExitCommand { presentation.cancel() }
    }

    private var title: String {
        switch presentation.stage {
        case .ready: return "Ready when you are"
        case .recording: return "Listening… (simulated)"
        case .transcribing: return "Transcribing… (simulated)"
        case .fallback: return "Destination unverified"
        case .cancelled: return "Cancelled"
        case .noSpeech: return "No speech recognized"
        case .issue(let issue): return issue.title
        }
    }

    @ViewBuilder private var content: some View {
        switch presentation.stage {
        case .ready:
            Text("Explore the native shell with synthetic text. No shortcut is registered and nothing is pasted.").foregroundStyle(.secondary)
            Button("Simulate recording") { presentation.begin() }.buttonStyle(.borderedProminent)
        case .recording:
            Text("Simulate release to transcribe. Escape cancels and discards this request.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                RecordingIndicator(reduceMotion: reduceMotion)
                Text("Recording simulation")
            }
            Button("Simulate release") { presentation.release() }.buttonStyle(.borderedProminent)
            cancelButton
        case .transcribing:
            HStack(spacing: 10) {
                if reduceMotion {
                    Image(systemName: "hourglass").foregroundStyle(blue)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Waiting for a simulated result").foregroundStyle(.secondary)
            }
            Button("Simulate result") {
                if let id = presentation.requestID {
                    presentation.complete(requestID: id, text: Presentation.fixture)
                }
            }.buttonStyle(.borderedProminent)
            cancelButton
        case .fallback:
            Text("Nothing pasted. Copy the synthetic text, then choose where to paste it.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Text(presentation.transcript ?? "").fixedSize(horizontal: false, vertical: true)
                Button {
                    presentation.copy(using: copy)
                } label: {
                    Image(systemName: presentation.copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(presentation.copied ? "Copy again" : "Copy synthetic transcript")
                .help("Copy synthetic transcript")
            }
            .padding(14)
            .background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            if presentation.copied { Text("Copied synthetic text").font(.caption).foregroundStyle(.secondary) }
            Button("Dismiss") { presentation.reset() }.keyboardShortcut(.cancelAction)
        case .cancelled:
            Text("This request was discarded. A late result cannot appear.").foregroundStyle(.secondary)
            backButton
        case .noSpeech:
            Text("Nothing to copy or paste. Try a new recording.").foregroundStyle(.secondary)
            backButton
        case .issue(let issue):
            Text(issue.recovery).foregroundStyle(.secondary)
            backButton
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { presentation.cancel() }.keyboardShortcut(.cancelAction)
    }
    private var backButton: some View {
        Button("Back to ready") { presentation.reset() }
    }
}

private struct RecordingIndicator: View {
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        Circle().fill(Color(red: 0.69, green: 0.19, blue: 0.26))
            .frame(width: 8, height: 8)
            .padding(5)
            .background(Color.red.opacity(0.08), in: Circle())
            .scaleEffect(expanded && !reduceMotion ? 1.18 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: expanded)
            .onAppear { expanded = true }
            .accessibilityHidden(true)
    }
}
