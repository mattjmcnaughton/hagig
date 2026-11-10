import XCTest
@testable import HagigPresentation

@MainActor
private final class ControlledRequest: DictationRequest {
    var admission: CheckedContinuation<Admission, Error>?
    var result: CheckedContinuation<String, Error>?
    var finished = false
    var closed = false
    var onClose: (() -> Void)?
    nonisolated let sink: @Sendable (Data) -> Void = { _ in }
    func reserve() async throws -> Admission {
        try await withCheckedThrowingContinuation { admission = $0 }
    }
    func finish() { finished = true }
    func result() async throws -> String {
        try await withCheckedThrowingContinuation { result = $0 }
    }
    func cancel() {
        closed = true
        let notify = onClose
        onClose = nil
        notify?()
    }
}

@MainActor
private final class ControlledCapture: NativeCapture {
    var stopped = false
    var streamed = true
    func start() throws {}
    func stop() -> Bool { stopped = true; return streamed }
}

final class DictationTests: XCTestCase {
    private static let vim = Admission(editorMode: .vim, modelID: "synthetic-model")
    private static let standard = Admission(editorMode: .standard, modelID: "synthetic-model")

    @MainActor
    func testLiveUnicodeReviewAndEmptyRecognitionDifferFromEmptyCapture() async throws {
        for text in ["Live controlled λ.\nSecond line 😀", "", "no-capture"] {
            let model = Presentation()
            let request = ControlledRequest()
            let capture = ControlledCapture()
            if text == "no-capture" { capture.streamed = false }
            let controller = DictationController(presentation: model, makeRequest: { request },
                permission: { true }, makeCapture: { _, _ in capture })
            controller.record()
            try await wait { request.admission != nil }
            request.admission?.resume(returning: Self.vim)
            try await wait { model.stage == .recording }
            XCTAssertEqual(model.modelID, "synthetic-model")
            controller.stop()
            if text == "no-capture" {
                XCTAssertFalse(request.finished, "an empty capture never ends the upload body")
                XCTAssertEqual(model.stage, .issue(.microphoneUnavailable))
            } else {
                XCTAssertTrue(request.finished)
                XCTAssertEqual(model.stage, .transcribing)
                try await wait { request.result != nil }
                request.result?.resume(returning: text)
                try await wait { model.stage != .transcribing }
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
    func testCancelDuringAdmissionNeverStartsCaptureAndLateResultNeverCopies() async throws {
        let model = Presentation()
        let request = ControlledRequest()
        var captures = 0
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { true }, makeCapture: { _, _ in captures += 1; return ControlledCapture() })
        controller.record()
        try await wait { request.admission != nil }
        XCTAssertNotNil(request.admission)
        controller.cancel()
        let resumed = expectation(description: "Late admission processed and released")
        request.onClose = { resumed.fulfill() }
        request.admission?.resume(returning: Self.vim)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(request.closed)
        XCTAssertEqual(model.stage, .cancelled)
        XCTAssertNil(model.transcript)
    }

    @MainActor
    func testStopCapConvergeAndCancellationWinsAgainstDelayedResult() async throws {
        for limitFirst in [false, true] {
            let model = Presentation()
            let request = ControlledRequest()
            let capture = ControlledCapture()
            var event: ((MicrophoneCapture.Event) -> Void)?
            let controller = DictationController(presentation: model, makeRequest: { request },
                permission: { true }, makeCapture: { event = $1; return capture })
            controller.record()
            try await wait { request.admission != nil }
            request.admission?.resume(returning: Self.standard)
            try await wait { model.stage == .recording }
            event?(.warning)
            XCTAssertTrue(model.nearLimit)
            if limitFirst { event?(.limit) } else { controller.stop() }
            XCTAssertTrue(request.finished)
            XCTAssertEqual(model.stage, .transcribing)
            // The opposite completion trigger must not start a second completion.
            request.finished = false
            if limitFirst { controller.stop() } else { event?(.limit) }
            XCTAssertFalse(request.finished)
            XCTAssertTrue(capture.stopped)
            try await wait { request.result != nil }
            controller.cancel()
            let resumed = expectation(description: "Late result processed and released")
            request.onClose = { resumed.fulfill() }
            request.result?.resume(returning: "Late controlled text must not appear")
            // No actor suspension occurs between this release callback and the
            // controller's visibility guard/completion. Assert only after it ran.
            await fulfillment(of: [resumed], timeout: 2)
            XCTAssertEqual(model.stage, .cancelled)
            XCTAssertNil(model.transcript)
            var copied = false
            model.copy { _ in copied = true; return true }
            XCTAssertFalse(copied)
            XCTAssertTrue(request.closed)
        }
    }

    @MainActor
    func testEarlyFailureDuringRecordingEndsTheRequest() async throws {
        let model = Presentation()
        let request = ControlledRequest()
        let capture = ControlledCapture()
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { true }, makeCapture: { _, _ in capture })
        controller.record()
        try await wait { request.admission != nil }
        request.admission?.resume(returning: Self.standard)
        try await wait { model.stage == .recording && request.result != nil }
        // The server may answer before the body ends (deadline, stop, DELETE).
        request.result?.resume(throwing: BackendFailure(code: "deadline_exceeded"))
        try await wait { model.stage != .recording }
        XCTAssertEqual(model.stage, .issue(.deadlineExceeded))
        XCTAssertTrue(capture.stopped)
        XCTAssertTrue(request.closed)
        XCTAssertFalse(request.finished)
    }

    @MainActor
    func testPermissionDeniedReleasesReservationAndCanRetry() async throws {
        let model = Presentation()
        let request = ControlledRequest()
        var captures = 0
        let controller = DictationController(presentation: model, makeRequest: { request },
            permission: { false }, makeCapture: { _, _ in captures += 1; return ControlledCapture() })
        controller.record()
        try await wait { request.admission != nil }
        request.admission?.resume(returning: Self.standard)
        try await wait { model.stage != .awaitingAdmission }
        XCTAssertEqual(model.stage, .issue(.microphonePermission))
        XCTAssertTrue(request.closed)
        XCTAssertEqual(captures, 0)
        model.reset()
        XCTAssertEqual(model.stage, .ready)
    }

    @MainActor
    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for controlled boundary")
                throw CaptureFailure.device
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
