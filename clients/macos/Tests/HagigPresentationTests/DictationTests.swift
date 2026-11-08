import XCTest
@testable import HagigPresentation

@MainActor
private final class ControlledRequest: DictationRequest {
    var admission: CheckedContinuation<EditorMode, Error>?
    var result: CheckedContinuation<String, Error>?
    var audio: Data?
    var closed = false
    func reserve(id: UUID) async throws -> EditorMode {
        try await withCheckedThrowingContinuation { admission = $0 }
    }
    func transcribe(_ audio: Data, id: UUID) async throws -> String {
        self.audio = audio
        return try await withCheckedThrowingContinuation { result = $0 }
    }
    func cancel() { closed = true }
}

@MainActor
private final class ControlledCapture: NativeCapture {
    var stopped = false
    var bytes = Data([0, 0, 0, 0])
    func start() throws {}
    func stop() -> Data { stopped = true; return bytes }
}

final class DictationTests: XCTestCase {
    @MainActor
    func testLiveUnicodeReviewAndEmptyRecognitionDifferFromEmptyCapture() async {
        for text in ["Live controlled λ.\nSecond line 😀", "", "no-capture"] {
            let model = Presentation()
            let request = ControlledRequest()
            let capture = ControlledCapture()
            if text == "no-capture" { capture.bytes = Data() }
            let controller = DictationController(presentation: model, makeRequest: { request },
                permission: { true }, makeCapture: { _ in capture })
            controller.record()
            for _ in 0..<100 where request.admission == nil { await Task.yield() }
            request.admission?.resume(returning: .vim)
            for _ in 0..<100 where model.stage != .recording { await Task.yield() }
            XCTAssertEqual(model.stage, .recording)
            controller.stop()
            for _ in 0..<100 where request.result == nil && model.stage == .transcribing { await Task.yield() }
            if text == "no-capture" {
                XCTAssertNil(request.audio)
                XCTAssertEqual(model.stage, .issue(.microphoneUnavailable))
            } else {
                XCTAssertNotNil(request.result)
                request.result?.resume(returning: text)
                for _ in 0..<100 where model.stage == .transcribing { await Task.yield() }
                XCTAssertEqual(model.stage, text.isEmpty ? .noSpeech : .fallback)
                XCTAssertEqual(model.transcript, text.isEmpty ? nil : text)
                XCTAssertEqual(model.editorMode, .vim)
                XCTAssertFalse(model.copied)
                var clipboard = "Existing clipboard"
                model.copy { clipboard = $0; return true }
                XCTAssertEqual(clipboard, text.isEmpty ? "Existing clipboard" : text)
            }
            XCTAssertTrue(request.closed)
            XCTAssertTrue(capture.stopped)
        }
    }

    @MainActor
    func testCancelDuringAdmissionNeverStartsCaptureAndLateResultNeverCopies() async {
        let model = Presentation()
        let request = ControlledRequest()
        var captures = 0
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { true }, makeCapture: { _ in captures += 1; return ControlledCapture() })
        controller.record()
        for _ in 0..<100 where request.admission == nil { await Task.yield() }
        XCTAssertNotNil(request.admission)
        controller.cancel()
        request.admission?.resume(returning: .vim)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(request.closed)
        XCTAssertEqual(model.stage, .cancelled)
        XCTAssertNil(model.transcript)
    }

    @MainActor
    func testStopCapConvergeAndCancellationWinsAgainstDelayedResult() async {
        let model = Presentation()
        let request = ControlledRequest()
        let capture = ControlledCapture()
        var event: ((MicrophoneCapture.Event) -> Void)?
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { true }, makeCapture: { event = $0; return capture })
        controller.record()
        for _ in 0..<100 where request.admission == nil { await Task.yield() }
        request.admission?.resume(returning: .standard)
        for _ in 0..<100 where model.stage != .recording { await Task.yield() }
        XCTAssertEqual(model.stage, .recording)
        event?(.warning)
        XCTAssertTrue(model.nearLimit)
        controller.stop()
        event?(.limit)
        for _ in 0..<100 where request.result == nil { await Task.yield() }
        XCTAssertEqual(request.audio, Data([0, 0, 0, 0]))
        XCTAssertTrue(capture.stopped)
        controller.cancel()
        request.result?.resume(returning: "Late controlled text must not appear")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.stage, .cancelled)
        XCTAssertNil(model.transcript)
        var copied = false
        model.copy { _ in copied = true; return true }
        XCTAssertFalse(copied)
        XCTAssertTrue(request.closed)
    }

    @MainActor
    func testPermissionDeniedReleasesReservationAndCanRetry() async {
        let model = Presentation()
        let request = ControlledRequest()
        var captures = 0
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { false }, makeCapture: { _ in captures += 1; return ControlledCapture() })
        controller.record()
        for _ in 0..<100 where request.admission == nil { await Task.yield() }
        request.admission?.resume(returning: .standard)
        for _ in 0..<100 where model.stage == .awaitingAdmission { await Task.yield() }
        XCTAssertEqual(model.stage, .issue(.microphonePermission))
        XCTAssertTrue(request.closed)
        XCTAssertEqual(captures, 0)
        model.reset()
        XCTAssertEqual(model.stage, .ready)
    }
}
