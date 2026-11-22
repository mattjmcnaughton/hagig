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
    private let log: AppLog
    /// Canonical PCM bytes sent for the current request, counted off the main thread.
    private var sent = ByteCount()
    /// When capture started, then when Stop ended the body: for `duration_ms`.
    private var mark: ContinuousClock.Instant?

    public convenience init(presentation: Presentation, helper: URL, log: AppLog = .inert) {
        self.init(presentation: presentation, makeRequest: { SocketRequest(helper: helper) },
                  permission: { await MicrophoneCapture.requestPermission() },
                  makeCapture: { MicrophoneCapture(sink: $0, event: $1) }, log: log)
    }

    init(presentation: Presentation, makeRequest: @escaping () -> DictationRequest,
         permission: @escaping () async -> Bool,
         makeCapture: @escaping (@escaping @Sendable (Data) -> Void,
                                 @escaping (MicrophoneCapture.Event) -> Void) -> NativeCapture,
         log: AppLog = .inert) {
        self.presentation = presentation
        self.makeRequest = makeRequest
        self.permission = permission
        self.makeCapture = makeCapture
        self.log = log
    }

    public func record(source: RecordingSource = .button) {
        guard ![.awaitingAdmission, .recording, .transcribing].contains(presentation.stage) else { return }
        let id = presentation.reserve()
        let request = makeRequest()
        self.request = request
        let sent = ByteCount()
        self.sent = sent
        mark = nil
        task = Task {
            do {
                let admission = try await request.reserve()
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                // The upload is open before any permission prompt; its outcome can arrive early.
                outcome = Task { await finished(request, id: id) }
                let allowed = await permission()
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                guard allowed else { throw CaptureFailure.permission }
                let forward = request.sink
                let capture = makeCapture({ data in sent.add(data.count); forward(data) }) { [weak self] event in
                    self?.received(event, id: id)
                }
                self.capture = capture
                try capture.start()
                guard presentation.admit(requestID: id, editorMode: admission.editorMode,
                                         modelID: admission.modelID, language: admission.language) else {
                    capture.stop(); request.cancel(); return
                }
                mark = .now
                log.record(.recordingStarted, AppLogFields(source: source.rawValue))
            } catch { fail(error, id: id) }
        }
    }

    public func stop() { stop(capped: false) }

    private func stop(capped: Bool) {
        guard presentation.stage == .recording, let id = presentation.requestID,
              let request, let capture else { return }
        // Transition before ending the body so cap and Stop share one path.
        presentation.release()
        self.capture = nil
        // A failed or empty capture is discarded, never sent as a complete body.
        guard capture.stop() else { fail(CaptureFailure.invalidAudio, id: id); return }
        log.record(capped ? .recordingAutoStopped : .recordingStopped,
                   AppLogFields(durationMs: Self.milliseconds(since: mark), bytes: sent.value))
        mark = .now
        request.finish()
    }

    public func cancel() {
        let stage: String?
        switch presentation.stage {
        case .awaitingAdmission: stage = "admission"
        case .recording: stage = "recording"
        case .transcribing: stage = "transcribing"
        default: stage = nil // Nothing active: the app quitting, for example.
        }
        if let stage { log.record(.recordingCancelled, AppLogFields(stage: stage)) }
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
            log.record(text.isEmpty ? .transcriptionNoSpeech : .transcriptionCompleted,
                       AppLogFields(durationMs: Self.milliseconds(since: mark)))
            presentation.complete(requestID: id, text: text)
        } catch { fail(error, id: id) }
    }

    private func received(_ event: MicrophoneCapture.Event, id: UUID) {
        guard presentation.requestID == id, presentation.stage == .recording else { return }
        switch event {
        case .warning: presentation.warnNearLimit(requestID: id)
        case .limit: stop(capped: true)
        case .failed: fail(CaptureFailure.device, id: id)
        case .level(let level): presentation.recordLevel(level, requestID: id)
        }
    }

    private func fail(_ error: Error, id: UUID) {
        guard presentation.requestID == id else { return }
        let issue: DemoIssue
        var detail: String?
        let code: String
        if let failure = error as? BackendFailure { issue = failure.issue; detail = failure.detail; code = failure.code }
        else if let failure = error as? CaptureFailure {
            switch failure {
            case .permission: issue = .microphonePermission; code = "microphone_permission"
            case .device: issue = .microphoneUnavailable; code = "microphone_failed"
            case .invalidAudio: issue = .microphoneUnavailable; code = "capture_invalid"
            }
        } else { issue = .serverUnavailable; code = "unreachable" }
        // The code and issue only; `detail` names the settings file and is never logged.
        log.record(.dictationFailed, AppLogFields(code: code, stage: issue.rawValue))
        // Showing an error discards local generations/editor before releasing resources.
        presentation.show(issue: issue, detail: detail)
        request?.cancel(); request = nil
        capture?.stop(); capture = nil
    }

    private static func milliseconds(since start: ContinuousClock.Instant?) -> Int? {
        guard let start else { return nil }
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Bytes forwarded by the capture sink, which runs off the main thread.
private final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ bytes: Int) { lock.lock(); count += bytes; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
