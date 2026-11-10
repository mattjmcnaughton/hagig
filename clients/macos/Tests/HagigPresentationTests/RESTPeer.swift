import Darwin
import Foundation

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

    /// A startup helper stand-in that appends its argument and a newline to
    /// `marker` on every run, waits `seconds`, then exits with `status`.
    func helper(exit status: Int32, after seconds: Int = 0) throws -> (url: URL, marker: String) {
        let marker = path + "/helper-ran-\(status)-\(seconds)"
        let script = path + "/helper-\(status)-\(seconds)"
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(marker)'\nsleep \(seconds)\nexit \(status)\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        guard chmod(script, 0o700) == 0 else { throw NSError(domain: "test.helper", code: 1) }
        return (URL(fileURLWithPath: script), marker)
    }

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

    /// Leaves a 0600 socket in `directory` that nobody listens on, as a crashed
    /// server would. Returns its path.
    static func stale(directory: String) throws -> String {
        let socket = try Peer(directory: directory).socket
        // The peer's deinit unlinked it; bind again and close without unlinking.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socket.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)
        guard bound == 0, chmod(socket, 0o600) == 0 else { throw NSError(domain: "test.stale", code: 1) }
        return socket
    }

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

