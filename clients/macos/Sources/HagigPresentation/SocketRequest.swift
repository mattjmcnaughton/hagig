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

    var issue: DemoIssue {
        switch code {
        case "busy": return .busy
        case "model_missing", "model_invalid": return .modelMissing
        case "worker_failed", "result_too_large": return .workerFailed
        case "deadline_exceeded": return .deadlineExceeded
        case "invalid_audio": return .microphoneUnavailable
        case "isolation_unavailable": return .configuration
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
    private nonisolated static let exchangeBound: Duration = .seconds(5)
    private nonisolated static let resultWait: Duration = .seconds(125)
    private nonisolated static let client: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.timeout = .init(connect: .seconds(5))
        configuration.httpVersion = .http1Only
        // POSIX sockets for http+unix. App-lifetime: static storage is never deinitialized.
        return HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, configuration: configuration)
    }()

    private let helper: URL
    private let environment: [String: String]
    private let darwinTempDir: @Sendable () -> String?
    private nonisolated let body = UploadBody()
    private var upload: Task<String, Error>?
    private var cancelled = false

    nonisolated var sink: @Sendable (Data) -> Void {
        let body = self.body
        return { body.send($0) }
    }

    init(helper: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         darwinTempDir: @escaping @Sendable () -> String? = SocketRequest.darwinUserTempDir) {
        self.helper = helper
        self.environment = environment
        self.darwinTempDir = darwinTempDir
    }

    func reserve() async throws -> Admission {
        let startup = ContinuousClock.now.advanced(by: Self.exchangeBound)
        let socket = try await Self.locate(environment: environment, darwinTempDir: darwinTempDir,
                                           helper: helper, deadline: startup)
        let status = try Self.status(try await Self.exchange(.GET, socket, "/v1/status", deadline: startup))
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        // Not cancelled with the caller: a 201 that arrives after Cancel is released below.
        let reply = try await Task {
            try await Self.exchange(.POST, socket, "/v1/requests", deadline: .now.advanced(by: Self.exchangeBound))
        }.value
        let admitted = try Self.admission(reply)
        guard admitted.config_generation == status.config_generation,
              admitted.model_id == status.settings.model_id else {
            Self.release(socket, admitted.request_id) // The server restarted between status and admission.
            throw BackendFailure.generic
        }
        guard !cancelled, !Task.isCancelled else {
            Self.release(socket, admitted.request_id) // Granted after the user cancelled.
            throw CancellationError()
        }
        let body = self.body
        upload = Task { try await Self.upload(socket, admitted.request_id, body) }
        return Admission(editorMode: status.settings.editor_mode, modelID: status.settings.model_id)
    }

    func finish() { body.finish() }

    func result() async throws -> String {
        guard let upload else { throw CancellationError() }
        return try await upload.value
    }

    /// Closes the upload without ending its body and never waits for a reply.
    func cancel() {
        cancelled = true
        body.fail()
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
        var info = stat()
        guard !path.utf8.contains(0),
              (followSymlinks ? Darwin.stat(path, &info) : lstat(path, &info)) == 0 else { return false }
        return info.st_mode & S_IFMT == kind && info.st_uid == getuid() && info.st_mode & 0o7777 == mode
    }

    private nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    /// Validates the private runtime directory and socket. Only when the socket
    /// is absent does the paired helper start the server (bundle wiring is #48);
    /// Swift never removes or repairs runtime files.
    private nonisolated static func locate(environment: [String: String], darwinTempDir: @Sendable () -> String?,
                                           helper: URL, deadline: ContinuousClock.Instant) async throws -> String {
        let socket = try socketPath(environment: environment, darwinTempDir: darwinTempDir)
        if !exists(socket) {
            try await start(helper: helper, environment: environment, deadline: deadline)
            while !exists(socket) {
                guard ContinuousClock.now < deadline else { throw BackendFailure.generic }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let runtime = (socket as NSString).deletingLastPathComponent
        guard isPrivate(runtime, kind: S_IFDIR, mode: 0o700, followSymlinks: false),
              isPrivate(socket, kind: S_IFSOCK, mode: 0o600, followSymlinks: false) else {
            throw BackendFailure.generic
        }
        return socket
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
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            process.terminate() // Only the owned startup helper, never a shared server PID.
            let cleanup = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning && ContinuousClock.now < cleanup { try? await Task.sleep(for: .milliseconds(10)) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw BackendFailure.generic
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw BackendFailure.generic
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

    /// Streams the body from the open upload until `finish`, then waits up to
    /// 125 seconds after the body ends. The server may answer early.
    private nonisolated static func upload(_ socket: String, _ id: String, _ body: UploadBody) async throws -> String {
        var request = try prepare(.PUT, socket, "/v1/requests/\(id)/audio")
        request.headers.add(name: "Content-Type", value: "application/octet-stream")
        request.body = .stream(body, length: .unknown) // Transfer-Encoding: chunked
        let prepared = request
        let reply = try await bounded(code: "deadline_exceeded") {
            try await Self.read(try await Self.client.execute(prepared, deadline: .distantFuture))
        } expiry: {
            var end = body.endedAt
            while end == nil {
                try await Task.sleep(for: .milliseconds(50))
                end = body.endedAt
            }
            try await Task.sleep(until: end!.advanced(by: Self.resultWait), clock: .continuous)
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
              (1...128).contains(admitted.request_id.utf8.count),
              admitted.request_id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw BackendFailure.generic
        }
        return admitted
    }

    /// A listed code with a status the table allows for it; anything else is generic.
    private nonisolated static func failure(_ reply: Reply) -> BackendFailure {
        guard let data = reply.body, let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
              errorStatuses[error.code]?.contains(reply.status) == true else { return .generic }
        return BackendFailure(code: error.code)
    }
}

extension EditorMode: Decodable {}

/// The streamed upload body. It ends normally only through `finish()`; `fail()`
/// or a cancelled consumer throws instead, so a cancelled upload never sends the
/// final chunk that would start inference on partial audio.
final class UploadBody: AsyncSequence, @unchecked Sendable {
    typealias Element = ByteBuffer
    private let lock = NSLock()
    private var chunks: [ByteBuffer] = []
    private var finished = false
    private var failed = false
    private var waiter: CheckedContinuation<ByteBuffer?, Error>?
    private var ended: ContinuousClock.Instant?

    /// When the consumer received the end of the body, if it has.
    var endedAt: ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    func send(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !failed, !data.isEmpty else { return }
        let chunk = ByteBuffer(bytes: data)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !failed else { return }
        finished = true
        if let waiter {
            self.waiter = nil
            ended = .now
            waiter.resume(returning: nil)
        }
    }

    func fail() {
        lock.lock(); defer { lock.unlock() }
        failed = true
        chunks.removeAll()
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    private func next() async throws -> ByteBuffer? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if failed {
                    continuation.resume(throwing: CancellationError())
                } else if !chunks.isEmpty {
                    continuation.resume(returning: chunks.removeFirst())
                } else if finished {
                    ended = .now
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            self.fail()
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let body: UploadBody
        func next() async throws -> ByteBuffer? { try await body.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(body: self) }
}
