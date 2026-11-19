import Foundation
import Combine

public enum DemoIssue: String, CaseIterable {
    case modelMissing, microphonePermission, serverUnavailable, busy, workerFailed, deadlineExceeded
    case microphoneUnavailable, configuration, isolationUnavailable

    public var title: String {
        switch self {
        case .modelMissing: return "Model not installed"
        case .microphonePermission: return "Microphone access is off"
        case .serverUnavailable: return "Transcription service unavailable"
        case .busy: return "Another request is active"
        case .workerFailed: return "Worker stopped unexpectedly"
        case .deadlineExceeded: return "Transcription timed out"
        case .microphoneUnavailable: return "Microphone unavailable"
        case .configuration: return "Settings need attention"
        case .isolationUnavailable: return "Network isolation unavailable"
        }
    }

    public var recovery: String {
        switch self {
        case .modelMissing:
            return "Hagig never downloads a model on its own. Install or repair the configured model yourself, then record again."
        case .microphonePermission:
            return "In System Settings, open Privacy & Security, then Microphone, and allow Hagig. Then record again."
        case .serverUnavailable:
            return "The paired service did not answer, or the one running belongs to a different build. Stop that service with the build that started it, then record again. Hagig never replaces a running service."
        case .busy: return "The service transcribes one request at a time and queues nothing. Wait for the other request to finish, then record again."
        case .workerFailed: return "Nothing was delivered. Record again to start a fresh worker."
        case .deadlineExceeded: return "Nothing was delivered. Record again to retry."
        case .microphoneUnavailable: return "The recording was discarded. Check the input device, then record again."
        case .configuration:
            return "The service did not start because its settings file is missing or invalid. Fix the file, then record again. Hagig never substitutes settings."
        case .isolationUnavailable:
            return "The inference worker could not start inside its network sandbox, so it was not started. Hagig never falls back to an unsandboxed worker by itself."
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
    /// The server's transcription language code from the same status.
    @Published public private(set) var language: String?
    /// When capture began, for the elapsed-time display.
    @Published public private(set) var recordingStarted: Date?
    /// Loudness of the most recent capture chunks (0...1, oldest first). A
    /// bounded display value, never audio; discarded with the request.
    @Published public private(set) var levels: [Float] = []
    /// One stable, content-free line from the paired helper about a failure.
    @Published public private(set) var issueDetail: String?
    public static let levelCount = 44
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

    public func admit(requestID: UUID, editorMode: EditorMode, modelID: String,
                      language: String = "en", started: Date = Date()) -> Bool {
        guard self.requestID == requestID, stage == .awaitingAdmission else { return false }
        self.editorMode = editorMode
        self.modelID = modelID
        self.language = language
        editorLabel = editorMode == .vim ? "Vim · Normal" : "Standard"
        recordingStarted = started
        stage = .recording
        return true
    }

    /// One capture chunk's loudness, for the current recording only.
    public func recordLevel(_ level: Float, requestID: UUID) {
        guard self.requestID == requestID, stage == .recording, level.isFinite else { return }
        levels.append(min(max(level, 0), 1))
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
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
        recordingStarted = Date()
        stage = .recording
    }

    public func release() {
        guard stage == .recording else { return }
        stage = .transcribing
    }

    public func complete(requestID: UUID, text: String) {
        guard self.requestID == requestID, stage == .transcribing else { return }
        self.requestID = nil
        levels = []
        recordingStarted = nil
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
        levels = []
        recordingStarted = nil
        issueDetail = nil
        stage = .ready
    }

    public func show(issue: DemoIssue, detail: String? = nil) {
        reset()
        issueDetail = detail
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
