import AsyncHTTPClient
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Settings the app takes from `GET /v1/status` for one admitted request.
struct Admission: Equatable {
    let editorMode: EditorMode
    let modelID: String
}

/// A request outcome other than text (backend/PROTOCOL.md, Client rules). `code`
/// is a stable server code, a client-local code, or `generic_failure`.
struct BackendFailure: Error, Equatable {
    let code: String
    static let generic = BackendFailure(code: "generic_failure")
    /// The paired helper's TDD §9 usage/configuration exit (2).
    static let configuration = BackendFailure(code: "configuration")

    var issue: DemoIssue {
        switch code {
        case "busy": return .busy
        case "model_missing", "model_invalid": return .modelMissing
        case "worker_failed", "result_too_large": return .workerFailed
        case "deadline_exceeded": return .deadlineExceeded
        case "invalid_audio": return .microphoneUnavailable
        case "isolation_unavailable", "configuration": return .configuration
        default: return .serverUnavailable // incompatible_api, server_stopping, cancelled, generic...
        }
    }
}

/// One dictation request against the REST v1 contract (`backend/PROTOCOL.md`)
/// over the private Unix socket. Status, admission and the streamed upload use
/// separate connections; the upload connection owns the request.
@MainActor
final class SocketRequest: DictationRequest {
    /// Every code the server may send, with the statuses it may arrive with.
    nonisolated static let errorStatuses: [String: Set<UInt>] = [
        "invalid_request": [400], "invalid_audio": [400, 413], "request_not_found": [404],
        "busy": [409], "cancelled": [409], "model_missing": [503], "model_invalid": [503],
        "isolation_unavailable": [503], "server_stopping": [503], "worker_failed": [500],
        "result_too_large": [500], "deadline_exceeded": [504],
    ]
    /// Startup/connect and every exchange other than the upload.
    private nonisolated static let exchangeBound: Duration = .seconds(5)
    private nonisolated static let client: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.timeout = .init(connect: .seconds(5))
        configuration.httpVersion = .http1Only
        // A refused connect (no server, or a stale socket) fails at once instead of
        // retrying with backoff until the bound, so the helper can still start it.
        configuration.connectionPool.retryConnectionEstablishment = false
        // POSIX sockets for http+unix. App-lifetime: static storage is never deinitialized.
        return HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, configuration: configuration)
    }()

    private let helper: URL
    private let environment: [String: String]
    private let darwinTempDir: @Sendable () -> String?
    private let resultWait: Duration
    /// The upload body. Only `finish()` ends it normally; Cancel ends it with an
    /// error, so a cancelled upload never sends the chunk that starts inference.
    private nonisolated let body: AsyncThrowingStream<ByteBuffer, Error>
    private nonisolated let feed: AsyncThrowingStream<ByteBuffer, Error>.Continuation
    /// Yields once when `finish()` ends the body; the result wait starts then.
    private let bodyEnded: AsyncStream<Void>
    private let endBody: AsyncStream<Void>.Continuation
    private var upload: Task<String, Error>?

    nonisolated var sink: @Sendable (Data) -> Void {
        let feed = self.feed
        return { data in if !data.isEmpty { feed.yield(ByteBuffer(bytes: data)) } }
    }

    init(helper: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         darwinTempDir: @escaping @Sendable () -> String? = SocketRequest.darwinUserTempDir,
         resultWait: Duration = .seconds(125)) {
        self.helper = helper
        self.environment = environment
        self.darwinTempDir = darwinTempDir
        self.resultWait = resultWait
        let stream = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        body = stream.stream
        feed = stream.continuation
        let ended = AsyncStream<Void>.makeStream()
        bodyEnded = ended.stream
        endBody = ended.continuation
    }

    func reserve() async throws -> Admission {
        let startup = ContinuousClock.now.advanced(by: Self.exchangeBound)
        let (socket, reply) = try await Self.connect(environment: environment, darwinTempDir: darwinTempDir,
                                                     helper: helper, deadline: startup)
        let status = try Self.status(reply)
        try Task.checkCancellation()
        // Not cancelled with the caller: a 201 that arrives after Cancel is released below.
        let admission = try await Task {
            try await Self.exchange(.POST, socket, "/v1/requests", deadline: .now.advanced(by: Self.exchangeBound))
        }.value
        let admitted = try Self.admission(admission)
        guard admitted.config_generation == status.config_generation,
              admitted.model_id == status.settings.model_id else {
            Self.release(socket, admitted.request_id) // The server restarted between status and admission.
            throw BackendFailure.generic
        }
        guard !Task.isCancelled else {
            Self.release(socket, admitted.request_id) // Granted after the user cancelled.
            throw CancellationError()
        }
        let body = self.body, ended = bodyEnded, wait = resultWait
        upload = Task { try await Self.upload(socket, admitted.request_id, body, ended: ended, wait: wait) }
        return Admission(editorMode: status.settings.editor_mode, modelID: status.settings.model_id)
    }

    func finish() {
        feed.finish()
        endBody.yield()
        endBody.finish()
    }

    func result() async throws -> String {
        guard let upload else { throw CancellationError() }
        return try await upload.value
    }

    /// Closes the upload without ending its body and never waits for a reply.
    func cancel() {
        feed.finish(throwing: CancellationError())
        upload?.cancel()
    }

    // MARK: Runtime location (R32, identical to backend/src/hagig/paths.py)

    nonisolated static func darwinUserTempDir() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `pathlib.Path(base) / name`: drops empty and "." components, keeping
    /// POSIX's distinct leading "//".
    private nonisolated static func join(_ base: String, _ name: String) -> String {
        let parts = base.split(separator: "/").filter { $0 != "." }.map(String.init) + [name]
        let root = base.hasPrefix("//") && !base.hasPrefix("///") ? "//" : "/"
        return root + parts.joined(separator: "/")
    }

    /// `$XDG_RUNTIME_DIR/hagig` when that base is a private directory, otherwise
    /// `hagig` in the OS per-user temporary directory, never `$TMPDIR`.
    private nonisolated static func socketPath(environment: [String: String],
                                               darwinTempDir: () -> String?) throws -> String {
        let base: String
        if let xdg = environment["XDG_RUNTIME_DIR"], xdg.hasPrefix("/"),
           isPrivate(xdg, kind: S_IFDIR, mode: 0o700, followSymlinks: true) {
            base = xdg
        } else {
            guard let temp = darwinTempDir(), temp.hasPrefix("/"),
                  isPrivate(temp, kind: S_IFDIR, mode: 0o700, followSymlinks: true) else {
                throw BackendFailure.generic // runtime_dir_unavailable / runtime_dir_unsafe
            }
            base = temp
        }
        let socket = join(join(base, "hagig"), "server.sock")
        // sizeof(sockaddr_un.sun_path) on macOS, including the terminating NUL.
        guard socket.utf8.count < 104 else { throw BackendFailure.generic }
        return socket
    }

    private nonisolated static func isPrivate(_ path: String, kind: mode_t, mode: mode_t,
                                             followSymlinks: Bool) -> Bool {
        guard !path.utf8.contains(0) else { return false }
        var info = stat()
        let result: Int32
        if followSymlinks { result = stat(path, &info) } else { result = lstat(path, &info) }
        return result == 0 && info.st_mode & S_IFMT == kind && info.st_uid == getuid() && info.st_mode & 0o7777 == mode
    }

    private nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    /// Reads `GET /v1/status` from a validated private socket. When no server
    /// answers (no socket, or a stale one), the paired helper starts it once
    /// (bundle wiring is #48). Swift never removes or repairs runtime files.
    private nonisolated static func connect(environment: [String: String], darwinTempDir: @Sendable () -> String?,
                                            helper: URL, deadline: ContinuousClock.Instant) async throws -> (String, Reply) {
        let socket = try socketPath(environment: environment, darwinTempDir: darwinTempDir)
        var started = false
        while true {
            if exists(socket) {
                let runtime = (socket as NSString).deletingLastPathComponent
                guard isPrivate(runtime, kind: S_IFDIR, mode: 0o700, followSymlinks: false),
                      isPrivate(socket, kind: S_IFSOCK, mode: 0o600, followSymlinks: false) else {
                    throw BackendFailure.generic
                }
                do {
                    return (socket, try await exchange(.GET, socket, "/v1/status", deadline: deadline))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // No response: refused (stale socket), closed, or the bound ran out.
                }
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BackendFailure.generic }
            if started {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                started = true
                try await start(helper: helper, environment: environment, deadline: deadline)
            }
        }
    }

    private nonisolated static func start(helper: URL, environment: [String: String],
                                          deadline: ContinuousClock.Instant) async throws {
        guard helper.isFileURL, helper.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw BackendFailure.generic }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["start"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            // Only the owned startup helper, never a shared server PID.
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
            try Task.checkCancellation()
            throw BackendFailure.generic
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let usage = process.terminationReason == .exit && process.terminationStatus == 2
            throw usage ? BackendFailure.configuration : BackendFailure.generic
        }
    }

    // MARK: Exchanges

    private struct Reply: Sendable {
        let status: UInt
        /// nil when the body exceeds the JSON limit or cannot be read.
        let body: Data?
    }

    private nonisolated static func prepare(_ method: HTTPMethod, _ socket: String, _ path: String) throws -> HTTPClientRequest {
        guard let url = URL(httpURLWithSocketPath: socket, uri: path) else { throw BackendFailure.generic }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        // HTTP/1.1 requires Host; AsyncHTTPClient adds none for Unix sockets. One
        // request per connection, so a pooled connection is never reused.
        request.headers.add(name: "Host", value: "localhost")
        request.headers.add(name: "Connection", value: "close")
        return request
    }

    private nonisolated static func read(_ response: HTTPClientResponse) async throws -> Reply {
        let body = try? await response.body.collect(upTo: 65_536)
        try Task.checkCancellation()
        return Reply(status: response.status.code, body: body.map { Data($0.readableBytesView) })
    }

    /// A status, admission or DELETE exchange, bounded at five seconds.
    private nonisolated static func exchange(_ method: HTTPMethod, _ socket: String, _ path: String,
                                            deadline: ContinuousClock.Instant) async throws -> Reply {
        let request = try prepare(method, socket, path)
        return try await bounded {
            try await Self.read(try await Self.client.execute(request, deadline: .distantFuture))
        } expiry: {
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    /// Runs `operation` until `expiry` returns; then cancels it (closing its
    /// connection) and fails with `code`. Errors other than outcomes are generic.
    private nonisolated static func bounded<T: Sendable>(
        code: String = BackendFailure.generic.code,
        _ operation: @escaping @Sendable () async throws -> T,
        expiry: @escaping @Sendable () async throws -> Void
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask { try await operation() }
                group.addTask { try await expiry(); return nil }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let value = first else { throw BackendFailure(code: code) }
                return value
            }
        } catch let failure as BackendFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BackendFailure.generic
        }
    }

    /// Sends a best-effort `DELETE` for an admitted request this client will not use.
    private nonisolated static func release(_ socket: String, _ id: String) {
        Task {
            _ = try? await Self.exchange(.DELETE, socket, "/v1/requests/\(id)",
                                         deadline: .now.advanced(by: Self.exchangeBound))
        }
    }

    /// Streams `body` on the open upload, then waits up to `wait` after the
    /// body ends. The server may answer before that.
    private nonisolated static func upload(_ socket: String, _ id: String, _ body: AsyncThrowingStream<ByteBuffer, Error>,
                                           ended: AsyncStream<Void>, wait: Duration) async throws -> String {
        var request = try prepare(.PUT, socket, "/v1/requests/\(id)/audio")
        request.headers.add(name: "Content-Type", value: "application/octet-stream")
        request.body = .stream(body, length: .unknown) // Transfer-Encoding: chunked
        let prepared = request
        let reply = try await bounded(code: "deadline_exceeded") {
            try await Self.read(try await Self.client.execute(prepared, deadline: .distantFuture))
        } expiry: {
            for await _ in ended { break }
            try Task.checkCancellation()
            try await Task.sleep(for: wait)
        }
        guard reply.status == 200 else { throw failure(reply) }
        guard let data = reply.body, let result = try? JSONDecoder().decode(Text.self, from: data) else {
            throw BackendFailure.generic
        }
        return result.text
    }

    // MARK: Classification (PROTOCOL.md Client rules)

    private struct Status: Decodable {
        enum State: String, Decodable { case idle, busy }
        enum Worker: String, Decodable { case absent, running }
        enum Isolation: String, Decodable { case required, disabled }
        struct Settings: Decodable { let editor_mode: EditorMode; let model_id: String; let language: String }
        struct Audio: Decodable { let encoding: String; let sample_rate_hz: Int; let channels: Int }
        struct Limits: Decodable { let json_body_bytes: Int; let result_body_bytes: Int; let audio_bytes: Int }
        struct Deadlines: Decodable {
            let upload_start_seconds: Int, reservation_seconds: Int, computation_seconds: Int, client_wait_seconds: Int
        }
        let api_version: Int
        let state: State
        let worker: Worker
        let network_isolation: Isolation
        let config_generation: String
        let settings: Settings
        let audio: Audio
        let limits: Limits
        let deadlines: Deadlines
    }

    private struct Admitted: Decodable { let request_id: String; let config_generation: String; let model_id: String }
    private struct Text: Decodable { let text: String }
    private struct ErrorBody: Decodable { let code: String }

    /// Only a complete v1 status and `503 server_stopping` are not `incompatible_api`.
    private nonisolated static func status(_ reply: Reply) throws -> Status {
        if reply.status == 200, let data = reply.body,
           let status = try? JSONDecoder().decode(Status.self, from: data), status.api_version == 1 {
            return status
        }
        if reply.status == 503, failure(reply).code == "server_stopping" { throw failure(reply) }
        throw BackendFailure(code: "incompatible_api")
    }

    private nonisolated static func admission(_ reply: Reply) throws -> Admitted {
        guard reply.status == 201 else { throw failure(reply) }
        guard let data = reply.body, let admitted = try? JSONDecoder().decode(Admitted.self, from: data),
              isRequestID(admitted.request_id) else {
            throw BackendFailure.generic
        }
        return admitted
    }

    /// 1–128 characters of `[A-Za-z0-9_-]`, so the ID is safe in a URL path.
    private nonisolated static func isRequestID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ||
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// A listed code with a status the table allows for it; anything else is generic.
    private nonisolated static func failure(_ reply: Reply) -> BackendFailure {
        guard let data = reply.body, let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
              errorStatuses[error.code]?.contains(reply.status) == true else { return .generic }
        return BackendFailure(code: error.code)
    }
}

extension EditorMode: Decodable {}
