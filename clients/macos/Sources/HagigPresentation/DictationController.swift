import Foundation

@MainActor
protocol DictationRequest: AnyObject {
    /// Reads status, reserves the slot and opens the streaming upload.
    func reserve() async throws -> Admission
    /// Thread-safe: forwards canonical PCM to the open upload as capture produces it.
    nonisolated var sink: @Sendable (Data) -> Void { get }
    /// Ends the upload body. The outcome arrives through `result()`.
    func finish()
    /// The upload's outcome, which the server may send before the body ends.
    func result() async throws -> String
    /// Closes the upload without ending its body; never waits for a reply.
    func cancel()
}

@MainActor
protocol NativeCapture: AnyObject {
    func start() throws
    /// Stops capture. True only when it streamed audio and did not fail.
    @discardableResult func stop() -> Bool
}

extension MicrophoneCapture: NativeCapture {}

/// Serializes admission, capture, cancellation and result visibility. Backend
/// disconnection releases only this client's reservation; never stops the server.
@MainActor
public final class DictationController {
    private let presentation: Presentation
    private let makeRequest: () -> DictationRequest
    private let permission: () async -> Bool
    private let makeCapture: (@escaping @Sendable (Data) -> Void,
                              @escaping (MicrophoneCapture.Event) -> Void) -> NativeCapture
    private var request: DictationRequest?
    private var capture: NativeCapture?
    private var task: Task<Void, Never>?
    private var outcome: Task<Void, Never>?

    public convenience init(presentation: Presentation, helper: URL) {
        self.init(presentation: presentation, makeRequest: { SocketRequest(helper: helper) },
                  permission: { await MicrophoneCapture.requestPermission() },
                  makeCapture: { MicrophoneCapture(sink: $0, event: $1) })
    }

    init(presentation: Presentation, makeRequest: @escaping () -> DictationRequest,
         permission: @escaping () async -> Bool,
         makeCapture: @escaping (@escaping @Sendable (Data) -> Void,
                                 @escaping (MicrophoneCapture.Event) -> Void) -> NativeCapture) {
        self.presentation = presentation
        self.makeRequest = makeRequest
        self.permission = permission
        self.makeCapture = makeCapture
    }

    public func record() {
        guard ![.awaitingAdmission, .recording, .transcribing].contains(presentation.stage) else { return }
        let id = presentation.reserve()
        let request = makeRequest()
        self.request = request
        task = Task {
            do {
                let admission = try await request.reserve()
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                // The upload is open before any permission prompt; its outcome can arrive early.
                outcome = Task { await finished(request, id: id) }
                let allowed = await permission()
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                guard allowed else { throw CaptureFailure.permission }
                let capture = makeCapture(request.sink) { [weak self] event in self?.received(event, id: id) }
                self.capture = capture
                try capture.start()
                guard presentation.admit(requestID: id, editorMode: admission.editorMode,
                                         modelID: admission.modelID) else {
                    capture.stop(); request.cancel(); return
                }
            } catch { fail(error, id: id) }
        }
    }

    public func stop() {
        guard presentation.stage == .recording, let id = presentation.requestID,
              let request, let capture else { return }
        // Transition before ending the body so cap and Stop share one path.
        presentation.release()
        self.capture = nil
        // A failed or empty capture is discarded, never sent as a complete body.
        guard capture.stop() else { fail(CaptureFailure.invalidAudio, id: id); return }
        request.finish()
    }

    public func cancel() {
        // Invalidate display and all clipboard routes before closing the upload.
        presentation.cancel()
        task?.cancel(); task = nil
        outcome?.cancel(); outcome = nil
        request?.cancel(); request = nil
        capture?.stop(); capture = nil
    }

    private func finished(_ request: DictationRequest, id: UUID) async {
        do {
            let text = try await request.result()
            request.cancel() // The upload has ended; release it.
            guard presentation.requestID == id, !Task.isCancelled else { return }
            // Text is a result only after Stop ended the body.
            guard presentation.stage == .transcribing else { throw BackendFailure.generic }
            self.request = nil
            presentation.complete(requestID: id, text: text)
        } catch { fail(error, id: id) }
    }

    private func received(_ event: MicrophoneCapture.Event, id: UUID) {
        guard presentation.requestID == id, presentation.stage == .recording else { return }
        switch event {
        case .warning: presentation.warnNearLimit(requestID: id)
        case .limit: stop()
        case .failed: fail(CaptureFailure.device, id: id)
        }
    }

    private func fail(_ error: Error, id: UUID) {
        guard presentation.requestID == id else { return }
        let issue: DemoIssue
        if let failure = error as? BackendFailure { issue = failure.issue }
        else if let failure = error as? CaptureFailure {
            switch failure {
            case .permission: issue = .microphonePermission
            case .device, .invalidAudio: issue = .microphoneUnavailable
            }
        } else { issue = .serverUnavailable }
        // Showing an error discards local generations/editor before releasing resources.
        presentation.show(issue: issue)
        request?.cancel(); request = nil
        capture?.stop(); capture = nil
    }
}
