import XCTest
@testable import HagigPresentation

final class PresentationTests: XCTestCase {
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
            model.complete(requestID: id, text: " \t\n")
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
}
