import Foundation
import Combine

public enum DemoIssue: String, CaseIterable {
    case modelMissing, microphonePermission, serverUnavailable, busy, workerFailed, deadlineExceeded
    case microphoneUnavailable, configuration

    public var title: String {
        switch self {
        case .modelMissing: return "Model missing"
        case .microphonePermission: return "Microphone permission needed"
        case .serverUnavailable: return "Server unavailable"
        case .busy: return "Another request is active"
        case .workerFailed: return "Worker stopped unexpectedly"
        case .deadlineExceeded: return "Transcription timed out"
        case .microphoneUnavailable: return "Microphone unavailable"
        case .configuration: return "Configuration needs attention"
        }
    }

    public var recovery: String {
        switch self {
        case .modelMissing: return "Explicitly install or repair the configured model, then retry. No download starts automatically."
        case .microphonePermission:
            return "Allow Microphone access for Hagig in macOS System Settings, then try a new recording."
        case .serverUnavailable:
            return "Check that the paired backend is installed and compatible, then retry. An existing server is never replaced automatically."
        case .busy: return "Wait for the other request to finish, then try again. Nothing is queued."
        case .workerFailed, .deadlineExceeded: return "Nothing delivered. Start a new recording to retry."
        case .microphoneUnavailable: return "Recording was discarded. Check the input device and permission, then try again."
        case .configuration: return "Check the backend configuration, intentionally stop the shared server, then relaunch. No settings were silently substituted."
        }
    }
}

public enum DemoStage: Equatable {
    case ready, awaitingAdmission, recording, transcribing, fallback, cancelled, noSpeech
    case issue(DemoIssue)
}

/// Main-actor visibility/copy authority. The backend separately owns admission.
@MainActor
public final class Presentation: ObservableObject {
    public static let fixture = "Add a timeout to the inference worker and cover cancellation with a regression test."
    @Published public private(set) var stage: DemoStage = .ready
    @Published public private(set) var transcript: String?
    @Published public private(set) var copied = false
    @Published public private(set) var editorMode: EditorMode
    @Published public private(set) var editorLabel: String
    @Published public private(set) var editorID = UUID()
    @Published public private(set) var nearLimit = false
    /// The server's configured model alias from the last admission's status.
    @Published public private(set) var modelID: String?
    public private(set) var requestID: UUID?
    private var discardEditor: (() -> Void)?

    /// The eventual client supplies the validated server setting, not Swift TOML.
    public init(editorMode: EditorMode = .standard) {
        self.editorMode = editorMode
        editorLabel = editorMode == .vim ? "Vim · Normal" : "Standard"
    }

    @discardableResult public func reserve() -> UUID {
        reset()
        let id = UUID()
        requestID = id
        stage = .awaitingAdmission
        return id
    }

    public func admit(requestID: UUID, editorMode: EditorMode, modelID: String? = nil) -> Bool {
        guard self.requestID == requestID, stage == .awaitingAdmission else { return false }
        self.editorMode = editorMode
        if let modelID { self.modelID = modelID }
        editorLabel = editorMode == .vim ? "Vim · Normal" : "Standard"
        stage = .recording
        return true
    }

    public func warnNearLimit(requestID: UUID) {
        guard self.requestID == requestID, stage == .recording else { return }
        nearLimit = true
    }

    public func begin(editorMode: EditorMode? = nil) {
        reset()
        if let editorMode { self.editorMode = editorMode }
        editorLabel = self.editorMode == .vim ? "Vim · Normal" : "Standard"
        requestID = UUID()
        stage = .recording
    }

    public func release() {
        guard stage == .recording else { return }
        stage = .transcribing
    }

    public func complete(requestID: UUID, text: String) {
        guard self.requestID == requestID, stage == .transcribing else { return }
        self.requestID = nil
        // The server already maps whitespace-only text to ""; never normalize again.
        guard !text.isEmpty else {
            stage = .noSpeech
            return
        }
        transcript = text
        stage = .fallback // Review only; never automatic clipboard delivery.
    }

    public func cancel() {
        guard [.awaitingAdmission, .recording, .transcribing, .fallback].contains(stage) else { return }
        reset()
        stage = .cancelled
    }

    public func reset() {
        requestID = nil
        editorID = UUID()
        discardEditor?()
        discardEditor = nil
        transcript = nil
        copied = false
        nearLimit = false
        stage = .ready
    }

    public func show(issue: DemoIssue) {
        reset()
        stage = .issue(issue)
    }

    public func edit(_ text: String, session: UUID) {
        guard stage == .fallback, editorID == session else { return }
        transcript = text
        copied = false
    }

    func updateEditorLabel(_ label: String, session: UUID) {
        guard stage == .fallback, editorID == session, editorLabel != label else { return }
        editorLabel = label
    }

    func attachEditor(session: UUID, discard: @escaping () -> Void) {
        guard stage == .fallback, editorID == session else { discard(); return }
        discardEditor = discard
    }

    func copySelection(_ text: String, session: UUID, using write: (String) -> Bool) -> Bool {
        guard stage == .fallback, editorID == session, !text.isEmpty else { return false }
        let success = write(text)
        copied = success && text == transcript
        return success
    }

    /// Only an explicit Copy action may invoke this effect. Failure leaves Copy available.
    public func copy(using write: (String) -> Bool) {
        guard stage == .fallback, let transcript, !transcript.isEmpty else { return }
        copied = write(transcript)
    }
}
