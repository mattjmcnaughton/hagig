import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import HagigPresentation

/// Opt-in signed/relocated integration, never a normal-operation capture source.
/// Uses #9's existing synthetic WAV and explicitly installed pinned model.
@MainActor
private final class SuppliedCapture: NativeCapture {
    let audio: Data
    init(audio: Data) { self.audio = audio }
    func start() throws {}
    func stop() -> Data { audio }
}

final class RealBackendTests: XCTestCase {
    @MainActor
    func testRealAdmissionSpeechReviewExplicitCopyBusyAndCancellation() async throws {
        let supplied = ProcessInfo.processInfo.environment
        let keys = ["HAGIG_INTEGRATION_HELPER", "HAGIG_INTEGRATION_DATA_HOME", "HAGIG_INTEGRATION_WAV"]
        if keys.allSatisfy({ supplied[$0] == nil }) {
            throw XCTSkip("Requires explicitly prepared real helper, model data and synthetic WAV")
        }
        let executable = try XCTUnwrap(supplied[keys[0]])
        let data = try XCTUnwrap(supplied[keys[1]])
        let wav = try XCTUnwrap(supplied[keys[2]])
        guard [executable, data, wav].allSatisfy({ $0.hasPrefix("/") }) else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        let helper = URL(fileURLWithPath: executable)
        let root = URL(fileURLWithPath: "/private/tmp/hg21-" + String(UUID().uuidString.prefix(8)))
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var serviceMayExist = false
        defer { if !serviceMayExist { try? files.removeItem(at: root) } }
        let config = root.appendingPathComponent("config/hagig")
        try files.createDirectory(at: config, withIntermediateDirectories: true)
        try "[editor]\nmode='vim'\n".write(to: config.appendingPathComponent("config.toml"),
                                           atomically: false, encoding: .utf8)
        var environment = supplied.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_") }
        environment["XDG_RUNTIME_DIR"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = data
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = LocalClipboard(pasteboard: board)
        XCTAssertTrue(writer.write("Existing isolated clipboard"))

        // Decode only the supplied test file, then exercise the production converter.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        let recording = try PCMRecording(format: file.processingFormat)
        let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        while file.framePosition < file.length {
            try file.read(into: chunk)
            if chunk.frameLength > 0 { try recording.append(chunk) }
        }
        let audio = recording.finish()
        guard !audio.isEmpty else { throw CaptureFailure.invalidAudio }
        var captureAudio = audio
        let model = Presentation()
        let controller = DictationController(presentation: model,
            makeRequest: { SocketRequest(helper: helper, environment: environment) },
            permission: { true }, makeCapture: { _ in SuppliedCapture(audio: captureAudio) })

        // Even an assertion failure must stop/reap the isolated service before
        // deleting its runtime. Retain on stop failure for the CI cleanup gate.
        do {
            serviceMayExist = true
            controller.record()
            try await wait { model.stage != .awaitingAdmission }
            XCTAssertEqual(model.stage, .recording)
            XCTAssertEqual(model.editorMode, .vim)
            let busy = try await call(helper, ["transcribe", wav], environment)
            XCTAssertEqual(busy.status, 3)
            XCTAssertTrue(busy.output.isEmpty)
            controller.stop()
            try await wait(seconds: 135) { model.stage != .transcribing }
            XCTAssertEqual(model.stage, .fallback, "Real backend must reach review, not fake success/error")
            let text = try XCTUnwrap(model.transcript)
            let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
            XCTAssertTrue(Set(["open", "project", "run"]).isSubset(of: words), "Supplied speech must be distinguished")
            // Known singular/plural quality failure is not hidden by an exact-text oracle.
            XCTAssertFalse(model.copied)
            XCTAssertEqual(board.string(forType: .string), "Existing isolated clipboard")
            model.copy(using: writer.write)
            XCTAssertEqual(board.string(forType: .string), text)
            controller.cancel()
            XCTAssertNil(model.transcript)
            XCTAssertEqual(board.string(forType: .string), text) // Cannot undo explicit Copy.

            controller.record()
            try await wait { model.stage != .awaitingAdmission }
            XCTAssertEqual(model.stage, .recording)
            controller.cancel()
            XCTAssertEqual(model.stage, .cancelled)
            XCTAssertNil(model.transcript)
            let reservationDeadline = ContinuousClock.now.advanced(by: .seconds(8))
            while true {
                let current = try await status(helper, environment)
                if current["state"] as? String == "idle" { break }
                guard ContinuousClock.now < reservationDeadline else { throw BackendFailure(issue: .deadlineExceeded) }
                try await Task.sleep(for: .milliseconds(20))
            }

            // Repeat only supplied synthetic PCM in memory, bounded to 60s.
            // Busy alone also includes upload, so reuse #9's tested observation:
            // post-end_audio exchange thread plus same native child's CPU progress.
            let idle = try await status(helper, environment)
            let server = try XCTUnwrap(idle["server_pid"] as? Int)
            let worker = try XCTUnwrap(idle["worker_pid"] as? Int)
            let baseline = try await observation(server: server, worker: worker, environment)
            captureAudio = Data()
            while captureAudio.count < 3_840_000 { captureAudio.append(audio) }
            captureAudio = Data(captureAudio.prefix(3_840_000))
            controller.record()
            try await wait { model.stage != .awaitingAdmission }
            XCTAssertEqual(model.stage, .recording)
            controller.stop()
            let uploadDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var computationDeadline: ContinuousClock.Instant?
            while true {
                let current = try await status(helper, environment)
                let activity = try await observation(server: server, worker: worker, environment)
                guard model.stage == .transcribing else { throw BackendFailure(issue: .workerFailed) }
                if activity.threads > baseline.threads, computationDeadline == nil {
                    computationDeadline = .now.advanced(by: .seconds(8))
                }
                if current["state"] as? String == "busy", current["worker_pid"] as? Int == worker,
                   activity.threads > baseline.threads, activity.cpu - baseline.cpu > 0.02 { break }
                guard ContinuousClock.now < (computationDeadline ?? uploadDeadline) else {
                    throw BackendFailure(issue: .deadlineExceeded)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            controller.cancel()
            let reapDeadline = ContinuousClock.now.advanced(by: .seconds(8))
            while true {
                let current = try await status(helper, environment)
                if current["state"] as? String == "idle" { break }
                guard ContinuousClock.now < reapDeadline else { throw BackendFailure(issue: .deadlineExceeded) }
                try await Task.sleep(for: .milliseconds(20))
            }
            let reaped = Darwin.kill(pid_t(worker), 0) == -1 && errno == ESRCH
            XCTAssertTrue(reaped, "Cancelled native child must be reaped before idle")
            XCTAssertEqual(model.stage, .cancelled)
            XCTAssertNil(model.transcript)
            XCTAssertEqual(board.string(forType: .string), text)
            captureAudio = audio
            controller.record()
            try await wait { model.stage != .awaitingAdmission }
            XCTAssertEqual(model.stage, .recording)
            controller.stop()
            try await wait(seconds: 135) { model.stage != .transcribing }
            XCTAssertEqual(model.stage, .fallback, "Real backend must recover after active cancellation")
            XCTAssertFalse(model.copied)
            XCTAssertEqual(board.string(forType: .string), text)
            controller.cancel()
        } catch {
            controller.cancel()
            let stopped = try await call(helper, ["stop"], environment)
            if stopped.status == 0 {
                try files.removeItem(at: root)
                print("REAL_BACKEND_CLEANUP_COMPLETE")
            }
            throw error
        }
        controller.cancel()
        let stopped = try await call(helper, ["stop"], environment)
        XCTAssertEqual(stopped.status, 0, "Owned service cleanup must complete")
        if stopped.status == 0 {
            try files.removeItem(at: root)
            print("REAL_BACKEND_CLEANUP_COMPLETE")
        }
    }

    @MainActor
    private func wait(seconds: Int = 10, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BackendFailure(issue: .deadlineExceeded) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func status(_ helper: URL, _ environment: [String: String]) async throws -> [String: Any] {
        let result = try await call(helper, ["status"], environment)
        XCTAssertEqual(result.status, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }

    @MainActor
    private func observation(server: Int, worker: Int, _ environment: [String: String]) async throws -> (threads: Int, cpu: Double) {
        let ps = URL(fileURLWithPath: "/bin/ps")
        let threads = try await call(ps, ["-M", "-p", String(server), "-o", "pid="], environment)
        let cpu = try await call(ps, ["-p", String(worker), "-o", "time="], environment)
        guard threads.status == 0, cpu.status == 0 else { throw BackendFailure(issue: .workerFailed) }
        var seconds = 0.0
        for part in String(decoding: cpu.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":") {
            seconds = seconds * 60 + (try XCTUnwrap(Double(part)))
        }
        return (String(decoding: threads.output, as: UTF8.self).split(separator: "\n").count, seconds)
    }

    @MainActor
    private func call(_ helper: URL, _ arguments: [String], _ environment: [String: String]) async throws -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else {
            process.terminate()
            let cleanup = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < cleanup {
                try await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                let reap = ContinuousClock.now.advanced(by: .seconds(1))
                while process.isRunning, ContinuousClock.now < reap {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            throw BackendFailure(issue: .deadlineExceeded)
        }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
}
