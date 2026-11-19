import XCTest
@testable import HagigPresentation

final class PresentationTests: XCTestCase {
    func testAdmissionCancellationAndSingleStopBoundary() async {
        await MainActor.run {
            let model = Presentation()
            let cancelled = model.reserve()
            XCTAssertEqual(model.stage, .awaitingAdmission)
            model.cancel()
            XCTAssertFalse(model.admit(requestID: cancelled, editorMode: .vim, modelID: "synthetic-model"))
            XCTAssertEqual(model.stage, .cancelled)
            XCTAssertNil(model.requestID)
            let live = model.reserve()
            XCTAssertFalse(model.admit(requestID: cancelled, editorMode: .vim, modelID: "synthetic-model"))
            XCTAssertTrue(model.admit(requestID: live, editorMode: .standard, modelID: "synthetic-model"))
            model.warnNearLimit(requestID: cancelled)
            XCTAssertFalse(model.nearLimit)
            model.warnNearLimit(requestID: live)
            XCTAssertTrue(model.nearLimit)
            model.release()
            model.release() // Stop and cap converge, not a second generation.
            model.complete(requestID: live, text: "Current request only")
            XCTAssertEqual(model.transcript, "Current request only")
            model.cancel()
            model.complete(requestID: live, text: "Late repeated completion")
            var writes = 0
            model.copy { _ in writes += 1; return true }
            XCTAssertEqual(writes, 0)
        }
    }

    func testSyntheticJourneyAndExplicitCopy() async {
        await MainActor.run {
            let model = Presentation()
            model.begin()
            let id = model.requestID!
            var clipboard = "Existing clipboard"
            model.copy { clipboard = $0; return true }
            XCTAssertEqual(clipboard, "Existing clipboard")
            model.release()
            model.complete(requestID: id, text: "Synthetic asymmetric fixture: cancel request 47.")
            XCTAssertEqual(model.stage, .fallback)
            XCTAssertFalse(model.copied)
            model.copy { clipboard = $0; return true }
            XCTAssertEqual(clipboard, "Synthetic asymmetric fixture: cancel request 47.")
            XCTAssertTrue(model.copied)
            model.reset()
            XCTAssertNil(model.transcript)
            model.copy { clipboard = $0; return true }
            XCTAssertEqual(clipboard, "Synthetic asymmetric fixture: cancel request 47.")
        }
    }

    func testCancellationAndOldGenerationCannotDeliver() async {
        await MainActor.run {
            for releaseBeforeCancel in [false, true] {
                let model = Presentation()
                model.begin()
                let oldID = model.requestID!
                if releaseBeforeCancel { model.release() }
                model.cancel()
                model.complete(requestID: oldID, text: "Late cancelled result")
                XCTAssertEqual(model.stage, .cancelled)
                XCTAssertNil(model.transcript)
                var clipboard = "Retained clipboard"
                model.copy { clipboard = $0; return true }
                XCTAssertEqual(clipboard, "Retained clipboard")
                model.begin()
                model.release()
                model.complete(requestID: oldID, text: "Stale generation")
                XCTAssertEqual(model.stage, .transcribing)
                XCTAssertNil(model.transcript)
                model.complete(requestID: model.requestID!, text: "Current generation")
                XCTAssertEqual(model.transcript, "Current generation")
                model.cancel()
                XCTAssertNil(model.transcript)
                XCTAssertFalse(model.copied)
            }
        }
    }

    func testEmptyResultErrorsAndFailedCopy() async {
        await MainActor.run {
            let model = Presentation()
            model.begin()
            let id = model.requestID!
            model.complete(requestID: id, text: "Premature result")
            XCTAssertEqual(model.stage, .recording)
            model.release()
            model.complete(requestID: id, text: "") // The server maps whitespace-only text to "".
            XCTAssertEqual(model.stage, .noSpeech)
            XCTAssertNil(model.transcript)
            model.begin()
            model.release()
            model.complete(requestID: model.requestID!, text: Presentation.fixture)
            model.copy { _ in false }
            XCTAssertFalse(model.copied)
            for issue in DemoIssue.allCases {
                model.show(issue: issue)
                XCTAssertEqual(model.stage, .issue(issue))
                XCTAssertNil(model.transcript)
                XCTAssertNil(model.requestID)
                model.reset()
                XCTAssertEqual(model.stage, .ready)
            }
        }
    }

    func testLevelsFollowOnlyTheLiveRecordingAndLeaveWithIt() async {
        await MainActor.run {
            let model = Presentation()
            let stale = model.reserve()
            model.recordLevel(0.5, requestID: stale) // Admission has not started capture.
            XCTAssertEqual(model.levels, [])
            model.cancel()
            let live = model.reserve()
            let started = Date(timeIntervalSinceReferenceDate: 1_000)
            XCTAssertTrue(model.admit(requestID: live, editorMode: .standard, modelID: "synthetic-model",
                                      language: "en", started: started))
            XCTAssertEqual(model.recordingStarted, started)
            XCTAssertEqual(model.language, "en")
            model.recordLevel(0.9, requestID: stale)
            model.recordLevel(.nan, requestID: live)
            XCTAssertEqual(model.levels, [])
            for level: Float in [-1, 0.25, 7] { model.recordLevel(level, requestID: live) }
            XCTAssertEqual(model.levels, [0, 0.25, 1], "levels are clamped to the display range")
            for step in 0..<100 { model.recordLevel(Float(step) / 100, requestID: live) }
            XCTAssertEqual(model.levels.count, Presentation.levelCount)
            XCTAssertEqual(model.levels.first, Float(100 - Presentation.levelCount) / 100)
            XCTAssertEqual(model.levels.last, 0.99)
            model.release()
            model.recordLevel(0.5, requestID: live) // Capture is over; the trace is frozen.
            XCTAssertEqual(model.levels.last, 0.99)
            model.complete(requestID: live, text: "Synthetic result")
            XCTAssertEqual(model.levels, [])
            XCTAssertNil(model.recordingStarted)
        }
    }

    func testIssueDetailAndSetupInstructions() async {
        await MainActor.run {
            let model = Presentation()
            model.show(issue: .configuration, detail: "config_invalid: synthetic detail")
            XCTAssertEqual(model.issueDetail, "config_invalid: synthetic detail")
            model.show(issue: .busy)
            XCTAssertNil(model.issueDetail, "a detail never outlives its own issue")
            model.show(issue: .configuration, detail: "config_invalid: synthetic detail")
            model.reset()
            XCTAssertNil(model.issueDetail)
        }
        // The command is pasted into a shell: one quoted word for the helper,
        // and only a plain alias after it.
        let guide = SetupGuide(helperPath: "/Apps/My Hagig's.app/Contents/Helpers/hagig")
        XCTAssertEqual(guide.installCommand(modelID: "qwen3-asr-0.6b"),
                       "'/Apps/My Hagig'\\''s.app/Contents/Helpers/hagig' model install qwen3-asr-0.6b")
        for unusable in ["", "x; rm -rf ~", "a b", "$(id)", "mod\u{e9}l"] {
            XCTAssertNil(guide.installCommand(modelID: unusable), unusable)
        }
        XCTAssertNil(guide.installCommand(modelID: nil))
        XCTAssertNil(SetupGuide().installCommand(modelID: "qwen3-asr-0.6b"))
        XCTAssertEqual(modelDisplayName("whisper-large-v3-turbo"), "Whisper large-v3 turbo")
        XCTAssertEqual(modelDisplayName("future-model-9"), "future-model-9")
    }
}
