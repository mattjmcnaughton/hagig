import Darwin
import Foundation
import XCTest
@testable import HagigPresentation

/// Streams one synthetic chunk through the real request sink when started.
@MainActor
private final class StreamingCapture: NativeCapture {
    let sink: @Sendable (Data) -> Void
    let chunk: Data
    init(sink: @escaping @Sendable (Data) -> Void, chunk: Data) { self.sink = sink; self.chunk = chunk }
    func start() throws { sink(chunk) }
    func stop() -> Bool { true }
}

private struct TimedOut: Error {}

final class SocketTests: XCTestCase {
    /// Never started: every test socket exists, so the launch seam is not reached.
    private let noHelper = URL(fileURLWithPath: "/usr/bin/false")
    /// Synthetic canonical samples 0.125 and -0.75, not recorded audio.
    private let chunk = Data([0, 0, 0, 0x3e, 0, 0, 0x40, 0xbf])

    private struct Outcome: Equatable {
        var outcome: String
        var code: String?
        var text: String?
    }

    @MainActor
    private func run(_ request: SocketRequest, early: Bool = false) async -> (Outcome, Admission?) {
        var admission: Admission?
        do {
            admission = try await request.reserve()
            request.sink(chunk)
            if !early { request.finish() }
            let text = try await request.result()
            return (Outcome(outcome: text.isEmpty ? "empty" : "text", text: text.isEmpty ? nil : text), admission)
        } catch let failure as BackendFailure {
            switch failure.code {
            case "generic_failure", "incompatible_api": return (Outcome(outcome: failure.code), admission)
            default: return (Outcome(outcome: "failure", code: failure.code), admission)
            }
        } catch {
            return (Outcome(outcome: "unexpected \(error)"), admission)
        }
    }

    private func expected(_ exchange: Exchange) -> Outcome {
        Outcome(outcome: exchange.outcome, code: exchange.code, text: exchange.text)
    }

    @MainActor
    private func finished(_ peers: Peer..., file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !peers.allSatisfy(\.done) {
            guard ContinuousClock.now < deadline else { XCTFail("Peer did not finish", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        for peer in peers { XCTAssertEqual(peer.failures, [], file: file, line: line) }
    }

    @MainActor
    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(what)")
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testClientErrorTableMatchesSharedFixtures() throws {
        let document = try Fixtures.document()
        let table = try XCTUnwrap(document["error_codes"] as? [[String: Any]])
        var fixture: [String: Set<UInt>] = [:]
        for row in table {
            let code = try XCTUnwrap(row["code"] as? String)
            fixture[code] = Set(try XCTUnwrap(row["statuses"] as? [Int]).map(UInt.init))
        }
        XCTAssertEqual(SocketRequest.errorStatuses, fixture)
        XCTAssertEqual(document["api_version"] as? Int, 1)
        XCTAssertEqual(Set(try XCTUnwrap(document["client_local_codes"] as? [String])),
                       ["incompatible_api", "deadline_exceeded"])
    }

    /// Every client exchange in the shared fixtures, served byte for byte over a
    /// Unix socket in the order the app sends its requests.
    @MainActor
    func testEveryClientFixtureExchange() async throws {
        let excluded = [
            "stop": "the app never stops the shared server",
            "stop_repeated": "the app never stops the shared server",
            "upload_content_length_text": "Content-Length uploads are the CLI's framing",
            "cancel_unknown": "the app only cancels IDs the server issued to it",
        ]
        let status = try Fixtures["status_idle"]
        let admit = try Fixtures["admit"]
        let text = try Fixtures["upload_chunked_text"]
        let release = try Fixtures["cancel_reserved"]
        let upload = "/v1/requests/\(try XCTUnwrap(admit.json?["request_id"] as? String))/audio"
        var covered: Set<String> = []
        for exchange in try Fixtures.all() where exchange.consumers.contains("client") {
            guard excluded[exchange.name] == nil else { continue }
            var steps: [Exchange]
            var want = expected(exchange)
            switch exchange.method {
            case "GET":
                steps = exchange.outcome == "compatible" ? [exchange, admit, text] : [exchange]
                if exchange.outcome == "compatible" { want = expected(text) }
            case "POST":
                steps = [status, exchange]
                if exchange.outcome == "admitted" { steps.append(text); want = expected(text) }
                if exchange.then == "cancel_admitted" { steps.append(release) }
            case "PUT":
                steps = [status, admit, exchange]
            case "DELETE":
                // Served for the DELETE the client sends after a mismatched admission;
                // the client ignores the acknowledgment.
                let mismatch = try Fixtures["admit_config_changed"]
                steps = [status, mismatch, exchange]
                want = expected(mismatch)
            default:
                XCTFail("\(exchange.name): unhandled method"); continue
            }
            let base = try Base()
            let peer = try Peer(directory: try base.directory())
            // upload_unknown_request names an ID the server never issued; the
            // client uploads to the ID admission gave it and gets that response.
            let served = steps.map { Peer.Step(exchange: $0, target: $0.method == "PUT" ? upload : nil) }
            peer.serve(served)
            let request = SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path])
            let (outcome, admission) = await run(request, early: exchange.open)
            XCTAssertEqual(outcome, want, exchange.name)
            try await finished(peer)
            XCTAssertEqual(peer.requests.map { "\($0.method) \($0.target)" },
                           served.map { "\($0.exchange.method) \($0.target ?? $0.exchange.target)" }, exchange.name)
            if exchange.method == "GET", exchange.outcome == "compatible" {
                let settings = exchange.json?["settings"] as? [String: Any]
                XCTAssertEqual(admission?.editorMode.rawValue, settings?["editor_mode"] as? String, exchange.name)
                XCTAssertEqual(admission?.modelID, settings?["model_id"] as? String, exchange.name)
            }
            covered.insert(exchange.name)
        }
        let client = Set(try Fixtures.all().filter { $0.consumers.contains("client") }.map(\.name))
        XCTAssertEqual(covered.union(excluded.keys), client)
        XCTAssertTrue(covered.isSuperset(of: ["status_api_version_2", "admit_busy", "upload_empty_text",
                                               "upload_unknown_code", "upload_cancelled", "cancel_reserved"]))
    }

    /// The fixtures change only `config_generation`; the rule also covers `model_id`.
    @MainActor
    func testAdmissionForAnotherModelIsReleased() async throws {
        let admit = try Fixtures["admit"]
        let wire = String(decoding: admit.wire, as: UTF8.self)
        XCTAssertTrue(wire.contains("\"model_id\":\"qwen3-asr-0.6b\""))
        // Same length, so the fixture's content-length still holds.
        let other = Exchange(name: "admit_model_changed", consumers: ["client"], method: admit.method,
                             target: admit.target, open: false,
                             wire: Data(wire.replacingOccurrences(of: "qwen3-asr-0.6b", with: "qwen3-asr-1.7b").utf8),
                             json: nil, outcome: "generic_failure", code: nil, text: nil, then: "cancel_admitted")
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: other),
                    Peer.Step(exchange: try Fixtures["cancel_reserved"])])
        let (outcome, _) = await run(SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path]))
        XCTAssertEqual(outcome, Outcome(outcome: "generic_failure"))
        try await finished(peer)
        XCTAssertEqual(peer.requests.map { "\($0.method) \($0.target)" },
                       ["GET /v1/status", "POST /v1/requests", "DELETE /v1/requests/fixture-request-1"])
    }

    @MainActor
    func testDisconnectBeforeAResponseIsAGenericFailure() async throws {
        let status = try Fixtures["status_idle"]
        let admit = try Fixtures["admit"]
        let upload = try Fixtures["upload_chunked_text"]
        for steps in [[Peer.Step(exchange: status, respond: false)],
                      [Peer.Step(exchange: status), Peer.Step(exchange: admit),
                       Peer.Step(exchange: upload, respond: false, early: true)]] {
            let base = try Base()
            let peer = try Peer(directory: try base.directory())
            peer.serve(steps)
            let request = SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path])
            let (outcome, _) = await run(request, early: true)
            XCTAssertEqual(outcome, Outcome(outcome: "generic_failure"))
            try await finished(peer)
        }
    }

    @MainActor
    func testUnansweredStatusFailsAtTheFiveSecondExchangeBound() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        // Hold longer than the bound, then close without answering. A longer
        // client bound would instead fail at the peer's close.
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"], respond: false,
                              hold: { Thread.sleep(forTimeInterval: 7.5) })])
        let request = SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path])
        let started = ContinuousClock.now
        let (outcome, _) = await run(request)
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(outcome, Outcome(outcome: "generic_failure"))
        XCTAssertGreaterThan(elapsed, .milliseconds(4_500))
        XCTAssertLessThan(elapsed, .milliseconds(6_500))
        try await finished(peer)
    }

    @MainActor
    func testResultWaitOutlastsTheExchangeBound() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        let upload = try Fixtures["upload_chunked_text"]
        // Inference may take longer than the five-second exchange bound.
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: try Fixtures["admit"]),
                    Peer.Step(exchange: upload, hold: { Thread.sleep(forTimeInterval: 6) })])
        let request = SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path])
        let (outcome, _) = await run(request)
        XCTAssertEqual(outcome, expected(upload))
        try await finished(peer)
        XCTAssertEqual(peer.requests.last?.body, chunk)
        XCTAssertEqual(peer.requests.last?.ended, true)
    }

    /// The result wait runs from the end of the body, not from opening the upload,
    /// and a server that never answers fails with `deadline_exceeded`.
    @MainActor
    func testResultWaitStartsWhenTheBodyEnds() async throws {
        let wait: Duration = .milliseconds(1_500)
        let upload = try Fixtures["upload_chunked_text"]
        for answers in [true, false] {
            let base = try Base()
            let peer = try Peer(directory: try base.directory())
            peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: try Fixtures["admit"]),
                        Peer.Step(exchange: upload, respond: answers,
                                  hold: { Thread.sleep(forTimeInterval: answers ? 0.5 : 4) })])
            let request = SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path], resultWait: wait)
            _ = try await request.reserve()
            request.sink(chunk)
            // Record for longer than the wait before Stop.
            try await Task.sleep(for: .milliseconds(2_500))
            let ended = ContinuousClock.now
            request.finish()
            let outcome: Outcome
            do {
                outcome = Outcome(outcome: "text", text: try await request.result())
            } catch let failure as BackendFailure {
                outcome = Outcome(outcome: "failure", code: failure.code)
            }
            let elapsed = ended.duration(to: .now)
            if answers {
                XCTAssertEqual(outcome, expected(upload))
            } else {
                XCTAssertEqual(outcome, Outcome(outcome: "failure", code: "deadline_exceeded"))
                XCTAssertGreaterThan(elapsed, .milliseconds(1_300))
                XCTAssertLessThan(elapsed, .milliseconds(3_000))
            }
            try await finished(peer)
        }
    }

    // MARK: Runtime location (R32)

    @MainActor
    func testFallbackIsTheDarwinTempDirNotTMPDIR() async throws {
        let stopping = try Fixtures["status_stopping"]
        let temp = try Base()
        let tmpdir = try Base()
        let unsafeXDG = try Base(mode: 0o755)
        let peer = try Peer(directory: try temp.directory())
        let tmpdirDecoy = try Peer(directory: try tmpdir.directory())
        let xdgDecoy = try Peer(directory: try unsafeXDG.directory())
        tmpdirDecoy.serve([], idle: 3_000)
        xdgDecoy.serve([], idle: 3_000)
        peer.serve([Peer.Step(exchange: stopping)])
        let confstr = temp.path + "/" // The OS returns the directory with a trailing slash.
        let request = SocketRequest(helper: noHelper,
                                    environment: ["TMPDIR": tmpdir.path, "XDG_RUNTIME_DIR": unsafeXDG.path],
                                    darwinTempDir: { confstr })
        let (outcome, _) = await run(request)
        XCTAssertEqual(outcome, expected(stopping))
        try await finished(peer, tmpdirDecoy, xdgDecoy)
        XCTAssertEqual(tmpdirDecoy.requests.count + xdgDecoy.requests.count, 0)
    }

    @MainActor
    func testValidXDGWinsAndAMissingOrUnsafeTempDirFailsClosed() async throws {
        let stopping = try Fixtures["status_stopping"]
        let xdg = try Base()
        let temp = try Base()
        let open = try Base(mode: 0o755)
        let peer = try Peer(directory: try xdg.directory())
        let decoy = try Peer(directory: try temp.directory())
        let openDecoy = try Peer(directory: try open.directory())
        decoy.serve([], idle: 3_000)
        openDecoy.serve([], idle: 3_000)
        peer.serve([Peer.Step(exchange: stopping)])
        let tempPath = temp.path
        let (outcome, _) = await run(SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": xdg.path],
                                                   darwinTempDir: { tempPath }))
        XCTAssertEqual(outcome, expected(stopping))
        let openPath = open.path
        for lookup in [{ nil }, { "relative/T/" }, { openPath }] as [@Sendable () -> String?] {
            let (refused, _) = await run(SocketRequest(helper: noHelper, environment: [:], darwinTempDir: lookup))
            XCTAssertEqual(refused, Outcome(outcome: "generic_failure"))
        }
        try await finished(peer, decoy, openDecoy)
        XCTAssertEqual(decoy.requests.count + openDecoy.requests.count, 0)
    }

    @MainActor
    func testUnsafeRuntimeObjectsAreRefusedWithoutConnecting() async throws {
        let symlinked = try Base()
        let target = try symlinked.directory("real")
        XCTAssertEqual(symlink(target, symlinked.path + "/hagig"), 0)
        let world = try Base()
        let openRuntime = try world.directory("hagig", mode: 0o755)
        let readable = try Base()
        let readableRuntime = try readable.directory()
        let peers = [try Peer(directory: target), try Peer(directory: openRuntime), try Peer(directory: readableRuntime)]
        XCTAssertEqual(chmod(readableRuntime + "/server.sock", 0o644), 0)
        for peer in peers { peer.serve([], idle: 2_000) }
        for base in [symlinked, world, readable] {
            let (outcome, _) = await run(SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": base.path]))
            XCTAssertEqual(outcome, Outcome(outcome: "generic_failure"), base.path)
        }
        try await finished(peers[0], peers[1], peers[2])
        XCTAssertEqual(peers.map(\.requests.count), [0, 0, 0])
    }

    @MainActor
    func testSocketPathLengthIsMeasuredLikeTheServer() async throws {
        // pathlib drops the trailing "/" and "." components: this socket path is
        // 103 bytes, the longest macOS accepts, though the raw value is longer.
        let stopping = try Fixtures["status_stopping"]
        let base = try Base(name: "hg-" + String(repeating: "x", count: 69))
        let socket = base.path + "/hagig/server.sock"
        XCTAssertEqual(socket.utf8.count, 103)
        let peer = try Peer(directory: try base.directory())
        peer.serve([Peer.Step(exchange: stopping), Peer.Step(exchange: stopping)])
        for xdg in [base.path + "/", base.path + "/./"] {
            let (outcome, _) = await run(SocketRequest(helper: noHelper, environment: ["XDG_RUNTIME_DIR": xdg]))
            XCTAssertEqual(outcome, expected(stopping), xdg)
        }
        try await finished(peer)
        // One byte longer is refused before any helper start or connection.
        let long = try Base(name: "hg-" + String(repeating: "x", count: 70))
        _ = try long.directory()
        let helper = try long.helper(exit: 0)
        let (refused, _) = await run(SocketRequest(helper: helper.url, environment: ["XDG_RUNTIME_DIR": long.path]))
        XCTAssertEqual(refused, Outcome(outcome: "generic_failure"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.marker))
    }

    @MainActor
    func testLaunchHelperRunsOnlyWhenNoServerAnswers() async throws {
        let base = try Base()
        let runtime = try base.directory()
        let environment = ["XDG_RUNTIME_DIR": base.path]
        // No socket: the helper is asked to start the server. Its TDD §9
        // configuration exit (2) is reported as a configuration problem.
        let configuration = try base.helper(exit: 2)
        let (absent, _) = await run(SocketRequest(helper: configuration.url, environment: environment))
        XCTAssertEqual(absent, Outcome(outcome: "failure", code: "configuration"))
        XCTAssertEqual(try String(contentsOfFile: configuration.marker, encoding: .utf8), "start")
        // A stale socket left by a crashed server refuses connections; the helper
        // (whose server lock owns stale-socket cleanup) is asked to start again.
        let failing = try base.helper(exit: 1)
        let stale = try Peer.stale(directory: runtime)
        let (refused, _) = await run(SocketRequest(helper: failing.url, environment: environment))
        XCTAssertEqual(refused, Outcome(outcome: "generic_failure"))
        XCTAssertEqual(try String(contentsOfFile: failing.marker, encoding: .utf8), "start")
        XCTAssertEqual(unlink(stale), 0)
        try FileManager.default.removeItem(atPath: failing.marker)
        // A live server answers: the helper never runs.
        let stopping = try Fixtures["status_stopping"]
        let peer = try Peer(directory: runtime)
        peer.serve([Peer.Step(exchange: stopping)])
        let (present, _) = await run(SocketRequest(helper: failing.url, environment: environment))
        XCTAssertEqual(present, expected(stopping))
        try await finished(peer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failing.marker))
    }

    // MARK: Controller flow and cancellation at the delivery boundary (TDD §7)

    @MainActor
    private func controller(_ model: Presentation, _ base: Base, captures: @escaping () -> Void = {},
                            permission: @escaping () async -> Bool = { true }) -> DictationController {
        let environment = ["XDG_RUNTIME_DIR": base.path]
        let helper = noHelper
        let chunk = self.chunk
        return DictationController(presentation: model,
            makeRequest: { SocketRequest(helper: helper, environment: environment) },
            permission: permission,
            makeCapture: { sink, _ in captures(); return StreamingCapture(sink: sink, chunk: chunk) })
    }

    @MainActor
    func testUploadOpensBeforePermissionAndStreamsBeforeStop() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        let status = try Fixtures["status_idle"]
        let text = try Fixtures["upload_chunked_text"]
        peer.serve([Peer.Step(exchange: status), Peer.Step(exchange: try Fixtures["admit"]), Peer.Step(exchange: text)])
        let model = Presentation()
        var uploadOpenAtPermission = false
        let dictation = controller(model, base, permission: {
            // A permission prompt can take arbitrarily long; the upload must already be open.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !peer.requests.contains(where: { $0.method == "PUT" }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            uploadOpenAtPermission = peer.requests.contains { $0.method == "PUT" }
            return true
        })
        dictation.record()
        try await wait("recording") { model.stage == .recording }
        XCTAssertTrue(uploadOpenAtPermission)
        // Capture output reaches the server while recording, before Stop.
        try await wait("streamed chunk") { peer.requests.last?.body == chunk }
        XCTAssertEqual(peer.requests.last?.ended, false)
        let requests = peer.requests
        XCTAssertLessThan(requests[1].at.duration(to: requests[2].at), .seconds(5))
        dictation.stop()
        try await wait("review") { model.stage == .fallback }
        XCTAssertEqual(model.transcript, text.text)
        let settings = status.json?["settings"] as? [String: Any]
        XCTAssertEqual(model.modelID, settings?["model_id"] as? String)
        XCTAssertEqual(model.editorMode.rawValue, settings?["editor_mode"] as? String)
        try await finished(peer)
        XCTAssertEqual(peer.requests.last?.ended, true)
    }

    @MainActor
    func testAdmissionGrantedAfterCancelIsReleasedWithoutUploadOrCapture() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        let gate = DispatchSemaphore(value: 0)
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]),
                    Peer.Step(exchange: try Fixtures["admit"], hold: { _ = gate.wait(timeout: .now() + 5) }),
                    Peer.Step(exchange: try Fixtures["cancel_reserved"])], idle: 1_000)
        let model = Presentation()
        var captures = 0
        let dictation = controller(model, base, captures: { captures += 1 })
        dictation.record()
        try await wait("admission request") { peer.requests.contains { $0.method == "POST" } }
        dictation.cancel()
        XCTAssertEqual(model.stage, .cancelled)
        gate.signal()
        try await finished(peer)
        XCTAssertEqual(peer.requests.map(\.method), ["GET", "POST", "DELETE"])
        XCTAssertEqual(peer.requests.last?.target, "/v1/requests/fixture-request-1")
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(model.stage, .cancelled)
    }

    @MainActor
    func testCancelWhileRecordingClosesTheUploadWithoutEndingTheBody() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: try Fixtures["admit"]),
                    Peer.Step(exchange: try Fixtures["upload_chunked_text"], respond: false)])
        let model = Presentation()
        let dictation = controller(model, base)
        dictation.record()
        try await wait("streamed chunk") { model.stage == .recording && peer.requests.last?.body == chunk }
        dictation.cancel()
        XCTAssertEqual(model.stage, .cancelled)
        try await finished(peer)
        // The terminating chunk would start inference on the partial recording.
        XCTAssertEqual(peer.requests.last?.ended, false)
        XCTAssertEqual(peer.requests.last?.eof, true)
    }

    /// Cancellation wins before display: a result already in flight is discarded.
    @MainActor
    func testCancelBeforeADelayedResultPreventsDisplayAndCopy() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        let gate = DispatchSemaphore(value: 0)
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: try Fixtures["admit"]),
                    Peer.Step(exchange: try Fixtures["upload_chunked_text"],
                              hold: { _ = gate.wait(timeout: .now() + 5) })])
        let model = Presentation()
        let dictation = controller(model, base)
        dictation.record()
        try await wait("recording") { model.stage == .recording && peer.requests.last?.body == chunk }
        dictation.stop()
        try await wait("body end") { peer.requests.last?.ended == true }
        XCTAssertEqual(model.stage, .transcribing)
        dictation.cancel() // Synchronous: no acknowledgment is awaited.
        XCTAssertEqual(model.stage, .cancelled)
        try await Task.sleep(for: .milliseconds(200))
        gate.signal()
        try await finished(peer)
        XCTAssertEqual(peer.requests.last?.closedBeforeResponse, true, "cancel closes the upload connection")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.stage, .cancelled)
        XCTAssertNil(model.transcript)
        var copied = false
        model.copy { _ in copied = true; return true }
        XCTAssertFalse(copied)
    }

    /// Delivery wins: an explicit Copy made before Cancel cannot be undone.
    @MainActor
    func testCopyBeforeCancelCannotBeRecalled() async throws {
        let base = try Base()
        let peer = try Peer(directory: try base.directory())
        let text = try Fixtures["upload_chunked_text"]
        peer.serve([Peer.Step(exchange: try Fixtures["status_idle"]), Peer.Step(exchange: try Fixtures["admit"]),
                    Peer.Step(exchange: text)], idle: 1_000)
        let model = Presentation()
        let dictation = controller(model, base)
        dictation.record()
        try await wait("recording") { model.stage == .recording }
        dictation.stop()
        try await wait("review") { model.stage == .fallback }
        var clipboard = ""
        model.copy { clipboard = $0; return true }
        dictation.cancel()
        XCTAssertEqual(model.stage, .cancelled)
        XCTAssertNil(model.transcript)
        XCTAssertEqual(clipboard, text.text)
        try await finished(peer) // No DELETE or further request after delivery.
    }
}
