import Foundation

@MainActor
protocol DictationRequest: AnyObject {
    func reserve(id: UUID) async throws -> EditorMode
    func transcribe(_ audio: Data, id: UUID) async throws -> String
    func cancel()
}

@MainActor
protocol NativeCapture: AnyObject {
    func start() throws
    func stop() -> Data
}

extension MicrophoneCapture: NativeCapture {}

struct BackendFailure: Error {
    let issue: DemoIssue
}

/// Serializes admission, capture, cancellation and result visibility. Backend
/// disconnection releases only this client's reservation; never stops the server.
@MainActor
public final class DictationController {
    private let presentation: Presentation
    private let makeRequest: () -> DictationRequest
    private let permission: () async -> Bool
    private let makeCapture: (@escaping (MicrophoneCapture.Event) -> Void) -> NativeCapture
    private var request: DictationRequest?
    private var capture: NativeCapture?
    private var task: Task<Void, Never>?

    public convenience init(presentation: Presentation, helper: URL) {
        self.init(presentation: presentation, makeRequest: { SocketRequest(helper: helper) },
                  permission: { await MicrophoneCapture.requestPermission() },
                  makeCapture: { MicrophoneCapture(event: $0) })
    }

    init(presentation: Presentation, makeRequest: @escaping () -> DictationRequest,
         permission: @escaping () async -> Bool,
         makeCapture: @escaping (@escaping (MicrophoneCapture.Event) -> Void) -> NativeCapture) {
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
                let mode = try await request.reserve(id: id)
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                let allowed = await permission()
                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }
                guard allowed else { throw CaptureFailure.permission }
                let capture = makeCapture { [weak self] event in self?.received(event, id: id) }
                self.capture = capture
                try capture.start()
                guard presentation.admit(requestID: id, editorMode: mode) else {
                    _ = capture.stop(); request.cancel(); return
                }
            } catch { fail(error, id: id) }
        }
    }

    public func stop() {
        guard presentation.stage == .recording, let id = presentation.requestID,
              let request, let capture else { return }
        // Transition before handing audio to async I/O so cap and Stop share one path.
        presentation.release()
        self.capture = nil
        let audio = capture.stop()
        task = Task {
            do {
                guard !audio.isEmpty else { throw CaptureFailure.invalidAudio }
                let text = try await request.transcribe(audio, id: id)
                request.cancel()
                guard presentation.requestID == id, !Task.isCancelled else { return }
                self.request = nil
                presentation.complete(requestID: id, text: text)
            } catch { fail(error, id: id) }
        }
    }

    public func cancel() {
        // Invalidate display and all clipboard routes before any cleanup/IPC.
        presentation.cancel()
        task?.cancel(); task = nil
        request?.cancel(); request = nil
        _ = capture?.stop(); capture = nil
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
        _ = capture?.stop(); capture = nil
    }
}
