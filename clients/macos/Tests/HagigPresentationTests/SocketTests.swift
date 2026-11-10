import Darwin
import Foundation
import XCTest
@testable import HagigPresentation

/// One exchange of the shared REST fixtures (backend/PROTOCOL.md, Shared fixtures).
struct Exchange {
    let name: String
    let consumers: [String]
    let method: String
    let target: String
    let open: Bool
    /// The response's wire bytes, exactly as the fixture gives them.
    let wire: Data
    let json: [String: Any]?
    let outcome: String
    let code: String?
    let text: String?
    let then: String?
}

/// Reads `backend/tests/fixtures/rest-v1-fixtures.json`, resolved from this
/// package's location. No fixture bytes are copied into Swift.
enum Fixtures {
    static let url = URL(fileURLWithPath: #filePath) // .../clients/macos/Tests/HagigPresentationTests/
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("backend/tests/fixtures/rest-v1-fixtures.json")
    private static let loaded = Result { try load() }

    static func document() throws -> [String: Any] { try loaded.get().document }
    static func all() throws -> [Exchange] { try loaded.get().exchanges }
    static subscript(name: String) -> Exchange {
        get throws {
            guard let exchange = try all().first(where: { $0.name == name }) else {
                throw NSError(domain: "fixture.missing", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            return exchange
        }
    }

    private static func load() throws -> (document: [String: Any], exchanges: [Exchange]) {
        guard let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let exchanges = document["exchanges"] as? [[String: Any]] else {
            throw NSError(domain: "fixture.shape", code: 1)
        }
        return (document, try exchanges.map(exchange))
    }

    private static func exchange(_ item: [String: Any]) throws -> Exchange {
        guard let name = item["name"] as? String, let consumers = item["consumers"] as? [String],
              let request = item["request"] as? [String: Any], let method = request["method"] as? String,
              let target = request["target"] as? String, let requestBody = request["body"] as? [String: Any],
              let response = item["response"] as? [String: Any], let status = response["status"] as? Int,
              let reason = response["reason"] as? String, let headers = response["headers"] as? [[String]],
              let body = response["body"] as? [String: Any], let client = item["client"] as? [String: Any],
              let outcome = client["outcome"] as? String else {
            throw NSError(domain: "fixture.exchange", code: 1)
        }
        var wire = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        for header in headers { wire.append(Data("\(header[0]): \(header[1])\r\n".utf8)) }
        wire.append(Data("\r\n".utf8))
        if let hex = body["hex"] as? String { wire.append(try bytes(hex)) }
        return Exchange(name: name, consumers: consumers, method: method, target: target,
                        open: requestBody["open"] as? Bool ?? false, wire: wire,
                        json: body["json"] as? [String: Any], outcome: outcome,
                        code: client["code"] as? String, text: client["text"] as? String,
                        then: client["then"] as? String)
    }

    static func bytes(_ hex: String) throws -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw NSError(domain: "fixture.hex", code: 1) }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// A private 0700 directory under /private/tmp (short enough for sun_path),
/// standing in for `$XDG_RUNTIME_DIR` or the per-user temporary directory.
final class Base {
    let path: String
    init(name: String = "hg-" + String(UUID().uuidString.prefix(8)), mode: mode_t = 0o700) throws {
        path = "/private/tmp/" + name
        guard mkdir(path, 0o700) == 0, chmod(path, mode) == 0 else { throw NSError(domain: "test.base", code: 1) }
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    /// Creates `<base>/<name>` as a 0700 directory and returns its path.
    func directory(_ name: String = "hagig", mode: mode_t = 0o700) throws -> String {
        let directory = path + "/" + name
        guard mkdir(directory, 0o700) == 0, chmod(directory, mode) == 0 else {
            throw NSError(domain: "test.directory", code: 1)
        }
        return directory
    }
}

/// Explicit test-only HTTP/1.1 peer on a real Unix socket, not a production
/// server selection. It answers one request per connection with fixture bytes,
/// checking only what PROTOCOL.md lets a client peer check.
final class Peer: @unchecked Sendable {
    struct Step {
        var exchange: Exchange
        /// The target the client must send, when it differs from the fixture's
        /// (the client only uploads to the ID its admission returned).
        var target: String?
        /// false: close the connection instead of answering.
        var respond = true
        /// Answer (or close) after the request head and first chunk.
        var early: Bool?
        /// Runs after the request is read, before answering.
        var hold: (@Sendable () -> Void)?
    }

    struct Received {
        var method = ""
        var target = ""
        var headers: [String: String] = [:]
        var body = Data()
        var ended = false
        var eof = false
        var closedBeforeResponse = false
        var at = ContinuousClock.now
    }

    let socket: String
    private let listener: Int32
    private let lock = NSLock()
    private var received: [Received] = []
    private var problems: [String] = []
    private var finished = false

    init(directory: String) throws {
        socket = directory + "/server.sock"
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: "test.socket", code: 1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socket.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "test.path", code: 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0, chmod(socket, 0o600) == 0 else {
            Darwin.close(listener)
            throw NSError(domain: "test.bind", code: 1)
        }
    }
    deinit { Darwin.close(listener); unlink(socket) }

    var requests: [Received] { lock.lock(); defer { lock.unlock() }; return received }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return problems }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    /// Serves `steps` in order, then reports any further connection within `idle`
    /// seconds as unexpected (for example an upload after a refusal).
    func serve(_ steps: [Step], idle: Int32 = 300) {
        Thread.detachNewThread { [self] in
            for step in steps {
                guard let fd = accept(timeout: 10_000) else { problem("no connection for \(step.exchange.name)"); break }
                handle(fd, step)
                Darwin.close(fd)
            }
            if let fd = accept(timeout: idle) {
                var extra = Received()
                if let connection = try? Connection(fd), let head = try? connection.head() {
                    extra = head
                }
                record(extra)
                problem("unexpected request \(extra.method) \(extra.target)")
                Darwin.close(fd)
            }
            lock.lock(); finished = true; lock.unlock()
        }
    }

    private func problem(_ text: String) { lock.lock(); problems.append(text); lock.unlock() }
    private func record(_ request: Received) { lock.lock(); received.append(request); lock.unlock() }
    private func update(_ change: (inout Received) -> Void) {
        lock.lock(); change(&received[received.count - 1]); lock.unlock()
    }

    private func accept(timeout: Int32) -> Int32? {
        var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&item, 1, timeout) > 0 else { return nil }
        let fd = Darwin.accept(listener, nil, nil)
        return fd >= 0 ? fd : nil
    }

    private func handle(_ fd: Int32, _ step: Peer.Step) {
        let exchange = step.exchange
        guard let connection = try? Connection(fd), let head = try? connection.head() else {
            problem("no request head for \(exchange.name)"); return
        }
        record(head)
        if head.method != exchange.method || head.target != (step.target ?? exchange.target) {
            problem("\(exchange.name): got \(head.method) \(head.target)")
        }
        // HTTP/1.1 requires Host (uvicorn rejects requests without one); no Expect.
        if head.headers["host"] == nil { problem("\(exchange.name): no Host header") }
        if head.headers["expect"] != nil { problem("\(exchange.name): Expect header") }
        if head.method == "PUT" {
            if head.headers["content-type"] != "application/octet-stream" { problem("\(exchange.name): content-type") }
            if head.headers["transfer-encoding"]?.lowercased() != "chunked" { problem("\(exchange.name): not chunked") }
            connection.chunks(early: step.early ?? exchange.open) { data, ended, eof in
                update { $0.body.append(data); $0.ended = ended; $0.eof = eof }
            }
        } else if let length = head.headers["content-length"].flatMap({ Int($0) }), length > 0 {
            problem("\(exchange.name): unexpected request body")
        }
        step.hold?()
        guard step.respond else { return }
        let closed = connection.closedByClient()
        update { $0.closedBeforeResponse = closed }
        connection.write(exchange.wire)
    }
}

/// Buffered blocking reads on one accepted peer connection.
private final class Connection {
    let fd: Int32
    private var buffer = Data()

    init(_ fd: Int32) throws {
        self.fd = fd
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw NSError(domain: "test.connection", code: 1)
        }
    }

    /// Reads more bytes; false at end of stream or on error.
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }

    private func until(_ separator: String) -> Data? {
        let marker = Data(separator.utf8)
        while true {
            if let range = buffer.range(of: marker) {
                let data = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return data
            }
            guard fill() else { return nil }
        }
    }

    private func exact(_ count: Int) -> Data? {
        while buffer.count < count { guard fill() else { return nil } }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    func head() throws -> Peer.Received {
        guard let data = until("\r\n\r\n"), let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "test.head", code: 1)
        }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2] == "HTTP/1.1" else { throw NSError(domain: "test.start", code: 1) }
        var request = Peer.Received()
        request.method = String(start[0])
        request.target = String(start[1])
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return request
    }

    /// Reads a chunked body until its terminator, end of stream or, when `early`,
    /// the first nonempty chunk. Reports each chunk as it arrives.
    func chunks(early: Bool, _ report: (Data, Bool, Bool) -> Void) {
        while true {
            guard let line = until("\r\n").flatMap({ String(data: $0, encoding: .ascii) }),
                  let size = Int(line.split(separator: ";").first ?? "", radix: 16) else {
                report(Data(), false, true); return
            }
            if size == 0 {
                while let trailer = until("\r\n"), !trailer.isEmpty {}
                report(Data(), true, false); return
            }
            guard let data = exact(size), until("\r\n") != nil else { report(Data(), false, true); return }
            report(data, false, false)
            if early { return }
        }
    }

    /// True when the client has already closed its side of the connection.
    func closedByClient() -> Bool {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&item, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    func write(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard count > 0 else { return } // The client may already have closed.
            offset += count
        }
    }
}

/// Streams one synthetic chunk through the real request sink when started.
@MainActor
private final class StreamingCapture: NativeCapture {
    let sink: @Sendable (Data) -> Void
    let chunk: Data
    var stopped = false
    init(sink: @escaping @Sendable (Data) -> Void, chunk: Data) { self.sink = sink; self.chunk = chunk }
    func start() throws { sink(chunk) }
    func stop() -> Bool { stopped = true; return true }
}

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
                throw CaptureFailure.device
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
    }

    @MainActor
    func testLaunchHelperRunsOnlyWhenTheSocketIsAbsent() async throws {
        let base = try Base()
        let runtime = try base.directory()
        let marker = base.path + "/helper-ran"
        let helper = base.path + "/helper"
        try "#!/bin/sh\nprintf '%s' \"$1\" > '\(marker)'\nexit 1\n".write(toFile: helper, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(helper, 0o700), 0)
        let helperURL = URL(fileURLWithPath: helper)
        let (absent, _) = await run(SocketRequest(helper: helperURL, environment: ["XDG_RUNTIME_DIR": base.path]))
        XCTAssertEqual(absent, Outcome(outcome: "generic_failure"))
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "start")
        try FileManager.default.removeItem(atPath: marker)
        let stopping = try Fixtures["status_stopping"]
        let peer = try Peer(directory: runtime)
        peer.serve([Peer.Step(exchange: stopping)])
        let (present, _) = await run(SocketRequest(helper: helperURL, environment: ["XDG_RUNTIME_DIR": base.path]))
        XCTAssertEqual(present, expected(stopping))
        try await finished(peer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
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
