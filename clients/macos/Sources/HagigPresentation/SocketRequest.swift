import Darwin
import Foundation

/// Implements the #9 v1 public contract, not its private inference wire.
@MainActor
final class SocketRequest: DictationRequest {
    private let channel = UnixChannel()
    private let helper: URL
    private let environment: [String: String]
    private var admitted: UUID?
    private var reservationDeadline: ContinuousClock.Instant?

    init(helper: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.helper = helper
        self.environment = environment
    }

    func reserve(id: UUID) async throws -> EditorMode {
        let helper = helper
        let environment = environment
        let mode = try await channel.run { channel in
            let base = try Self.runtimeBase(environment)
            let socket = base + "/hagig/server.sock"
            guard socket.utf8.count <= 100 else { throw BackendFailure(issue: .serverUnavailable) }
            // The helper owns startup locking/stale-socket recovery and attaches
            // to an existing winner; Swift never removes or repairs runtime files.
            try Self.start(helper: helper, environment: environment, channel: channel)
            try Self.validate(base + "/hagig", mode: 0o700, kind: S_IFDIR)
            try Self.validate(socket, mode: 0o600, kind: S_IFSOCK)
            try channel.connect(path: socket, deadline: .now.advanced(by: .seconds(5)))
            let hello = try Self.exchange(channel, type: "hello", id: nil, expected: "hello_ok")
            let mode = try hello.validateHello()
            let accepted = try Self.exchange(channel, type: "begin", id: id.uuidString, expected: "accepted")
            guard accepted.config_generation == hello.config_generation,
                  accepted.model_id == hello.settings?.model_id else {
                throw BackendFailure(issue: .serverUnavailable)
            }
            return mode
        }
        admitted = id
        reservationDeadline = .now.advanced(by: .seconds(330))
        return mode
    }

    func transcribe(_ audio: Data, id: UUID) async throws -> String {
        guard admitted == id, let deadline = reservationDeadline,
              !audio.isEmpty, audio.count % 4 == 0, audio.count <= 19_200_000 else {
            throw BackendFailure(issue: .microphoneUnavailable)
        }
        admitted = nil // Only one upload/completion per admission.
        return try await channel.run { channel in
            for offset in stride(from: 0, to: audio.count, by: 4) {
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(audio[offset + $1]) << (8 * $1) }
                let sample = Float(bitPattern: bits)
                guard sample.isFinite, (-1...1).contains(sample) else {
                    throw BackendFailure(issue: .microphoneUnavailable)
                }
            }
            let uploadDeadline = min(deadline, .now.advanced(by: .seconds(30)))
            for start in stride(from: 0, to: audio.count, by: 262_144) {
                let chunk = audio.subdata(in: start..<min(start + 262_144, audio.count))
                try channel.send(kind: 2, payload: chunk,
                                 deadline: min(uploadDeadline, .now.advanced(by: .seconds(5))))
            }
            try Self.send(channel, type: "end_audio", id: id.uuidString,
                          deadline: min(uploadDeadline, .now.advanced(by: .seconds(5))))
            let result = try Self.response(channel, id: id.uuidString, expected: "result",
                                          deadline: .now.advanced(by: .seconds(125)))
            guard let text = result.text else { throw BackendFailure(issue: .serverUnavailable) }
            return text
        }
    }

    func cancel() {
        admitted = nil
        channel.cancel() // Disconnect cancels only this owned reservation/inference.
    }

    private nonisolated static func runtimeBase(_ environment: [String: String]) throws -> String {
        guard let supplied = environment["XDG_RUNTIME_DIR"] ?? environment["TMPDIR"],
              supplied.hasPrefix("/"), !supplied.utf8.contains(0) else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        // Strip trailing slashes only, not symlinks or Foundation's temp-root rewrite.
        let base = String(supplied.reversed().drop(while: { $0 == "/" }).reversed())
        guard !base.isEmpty else { throw BackendFailure(issue: .serverUnavailable) }
        try validate(base, mode: 0o700, kind: S_IFDIR)
        return base
    }

    private nonisolated static func validate(_ path: String, mode: mode_t, kind: mode_t) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & 0o7777 == mode, metadata.st_mode & S_IFMT == kind else {
            throw BackendFailure(issue: .serverUnavailable)
        }
    }

    private nonisolated static func start(helper: URL, environment: [String: String], channel: UnixChannel) throws {
        guard !channel.isCancelled else { throw CancellationError() }
        guard helper.isFileURL, helper.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["start"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < deadline && !channel.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate() // Only the owned startup helper, never a shared service PID.
            let cleanup = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning && ContinuousClock.now < cleanup { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw BackendFailure(issue: .serverUnavailable)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw BackendFailure(issue: process.terminationStatus == 2 ? .configuration : .serverUnavailable)
        }
    }

    private struct Control: Encodable {
        let version = 1
        let type: String
        let request_id: String?
    }

    private nonisolated static func send(_ channel: UnixChannel, type: String, id: String?,
                                        deadline: ContinuousClock.Instant) throws {
        let payload = try JSONEncoder().encode(Control(type: type, request_id: id))
        try channel.send(kind: 1, payload: payload, deadline: deadline)
    }

    private nonisolated static func exchange(_ channel: UnixChannel, type: String, id: String?,
                                            expected: String) throws -> Reply {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try send(channel, type: type, id: id, deadline: deadline)
        return try response(channel, id: id, expected: expected, deadline: deadline)
    }

    private nonisolated static func response(_ channel: UnixChannel, id: String?, expected: String,
                                            deadline: ContinuousClock.Instant) throws -> Reply {
        let data = try channel.receive(firstByteDeadline: deadline,
                                       frameDeadline: expected == "result" ? nil : deadline)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        try rejectDuplicateKeys(data)
        guard reply.version == 1, reply.request_id == id else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        if reply.type == "error" {
            let issue: DemoIssue
            switch reply.code {
            case "busy": issue = .busy
            case "model_missing", "model_invalid": issue = .modelMissing
            case "worker_failed", "result_too_large": issue = .workerFailed
            case "deadline_exceeded": issue = .deadlineExceeded
            case "invalid_audio": issue = .microphoneUnavailable
            default: issue = .serverUnavailable
            }
            throw BackendFailure(issue: issue)
        }
        guard reply.type == expected else { throw BackendFailure(issue: .serverUnavailable) }
        return reply
    }

    /// Foundation accepts duplicate JSON members. After syntax/type decoding,
    /// scan only object keys, unescaping them so "type" and "\u{005C}u0074ype"
    /// cannot override each other. Values (including transcript text) are skipped.
    private nonisolated static func rejectDuplicateKeys(_ data: Data) throws {
        var objects: [Set<String>?] = []
        var index = 0
        while index < data.count {
            switch data[index] {
            case 123: objects.append(Set<String>()) // {
            case 91: objects.append(nil) // [
            case 125, 93: objects.removeLast()
            case 34:
                let start = index
                index += 1
                while index < data.count {
                    if data[index] == 92 { index += 2; continue }
                    if data[index] == 34 { break }
                    index += 1
                }
                var next = index + 1
                while next < data.count, [9, 10, 13, 32].contains(data[next]) { next += 1 }
                if next < data.count, data[next] == 58, !objects.isEmpty {
                    let key = try JSONDecoder().decode(String.self, from: data.subdata(in: start..<(index + 1)))
                    if objects[objects.count - 1]?.insert(key).inserted == false {
                        throw BackendFailure(issue: .serverUnavailable)
                    }
                }
            default: break
            }
            index += 1
        }
    }

    private struct Reply: Decodable {
        let version: Int
        let type: String
        let request_id: String?
        let code: String?
        let text: String?
        let worker: String?
        let network_isolation: String?
        let config_generation: String?
        let model_id: String?
        let settings: Settings?
        let audio: Audio?
        let limits: [String: Int]?
        let deadlines: [String: Int]?
        struct Settings: Decodable {
            let editor_mode: String
            let model_id: String
            let model_revision: String
            let language: String
        }
        struct Audio: Decodable {
            let encoding: String
            let sample_rate_hz: Int
            let channels: Int
        }
        func validateHello() throws -> EditorMode {
            guard worker == "inference", network_isolation == "required" || network_isolation == "disabled",
                  let generation = config_generation, (1...128).contains(generation.utf8.count),
                  generation.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  let settings, let mode = EditorMode(rawValue: settings.editor_mode),
                  settings.model_id == "parakeet-tdt-0.6b-v2-int8-v1",
                  settings.model_revision == "1ab9323565ddb038682214b292f588070a538ce2",
                  settings.language == "en", audio?.encoding == "f32le",
                  audio?.sample_rate_hz == 16_000, audio?.channels == 1,
                  limits == ["control_bytes": 65_536, "audio_chunk_bytes": 262_144,
                             "audio_total_bytes": 19_200_000, "recording_seconds": 300,
                             "warning_seconds": 285, "request_id_bytes": 128],
                  deadlines == ["control_seconds": 5, "reservation_seconds": 330, "computation_seconds": 120] else {
                throw BackendFailure(issue: .serverUnavailable)
            }
            return mode
        }
    }
}
