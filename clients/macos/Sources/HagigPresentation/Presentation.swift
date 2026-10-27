import Foundation
import Combine

public enum DemoIssue: String, CaseIterable {
    case modelMissing, microphonePermission, accessibilityPermission, busy, workerFailed, deadlineExceeded

    public var title: String {
        switch self {
        case .modelMissing: return "Model missing"
        case .microphonePermission: return "Microphone permission needed"
        case .accessibilityPermission: return "Accessibility permission needed"
        case .busy: return "Another request is active"
        case .workerFailed: return "Worker stopped unexpectedly"
        case .deadlineExceeded: return "Transcription timed out"
        }
    }

    public var recovery: String {
        switch self {
        case .modelMissing: return "A real client will require explicit model installation. No download starts here."
        case .microphonePermission, .accessibilityPermission:
            return "A real client will need access in macOS System Settings. This shell requests no permissions."
        case .busy: return "Wait for the other request to finish, then try again. Nothing is queued."
        case .workerFailed, .deadlineExceeded: return "Nothing delivered. Start a new recording to retry."
        }
    }
}

public enum DemoStage: Equatable {
    case ready, recording, transcribing, fallback, cancelled, noSpeech
    case issue(DemoIssue)
}

/// Local presentation only. Not the Rust server's request lifecycle or a backend client.
@MainActor
public final class Presentation: ObservableObject {
    public static let fixture = "Add a timeout to the inference worker and cover cancellation with a regression test."
    @Published public private(set) var stage: DemoStage = .ready
    @Published public private(set) var transcript: String?
    @Published public private(set) var copied = false
    public private(set) var requestID: UUID?

    public init() {}

    public func begin() {
        reset()
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage = .noSpeech
            return
        }
        transcript = text
        stage = .fallback // Synthetic results never qualify for automatic delivery.
    }

    public func cancel() {
        guard [.recording, .transcribing, .fallback].contains(stage) else { return }
        reset()
        stage = .cancelled
    }

    public func reset() {
        requestID = nil
        transcript = nil
        copied = false
        stage = .ready
    }

    public func show(issue: DemoIssue) {
        reset()
        stage = .issue(issue)
    }

    /// Only an explicit Copy action may invoke this effect. Failure leaves Copy available.
    public func copy(using write: (String) -> Bool) {
        guard stage == .fallback, let transcript else { return }
        copied = write(transcript)
    }
}
