import AVFoundation
import Darwin
import XCTest
@testable import HagigPresentation

/// Streams a supplied WAV through the production converter into the open upload,
/// standing in for the microphone. Never a normal-operation capture source.
@MainActor
private final class FileCapture: NativeCapture {
    private let url: URL
    private let sink: @Sendable (Data) -> Void
    private var recording: PCMRecording?
    init(url: URL, sink: @escaping @Sendable (Data) -> Void) { self.url = url; self.sink = sink }

    func start() throws {
        let file = try AVAudioFile(forReading: url)
        let recording = try PCMRecording(format: file.processingFormat, sink: sink)
        self.recording = recording
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw CaptureFailure.device
        }
        while file.framePosition < file.length {
            try file.read(into: chunk)
            if chunk.frameLength > 0 { try recording.append(chunk) }
        }
    }

    func stop() -> Bool { (recording?.finish() ?? 0) > 0 }
}

/// The app against the bundled Python server, through `Contents/Helpers/hagig`
/// of a built, relocated Hagig.app (#48). Opt-in: set the absolute
/// `HAGIG_BUNDLED_APP` and `HAGIG_INTEGRATION_WAV`; both unset skips, one fails.
/// Without a model a request must end in `model_missing`. With
/// `HAGIG_BUNDLED_DATA` (an XDG data directory where the bundle's own helper
/// installed `qwen3-asr-0.6b`), a request must end in a real transcript (#49).
final class BundledBackendTests: XCTestCase {
    private struct Setup {
        let helper: URL
        let environment: [String: String]
        let controller: DictationController
    }

    /// A private short runtime and config for one test, and a controller whose
    /// requests use the bundled helper. Teardown stops only this test's server,
    /// also after a failure, and keeps the runtime directory if stop fails.
    @MainActor
    private func prepare(config: String, presentation: Presentation,
                         data: String? = nil) throws -> Setup {
        let supplied = ProcessInfo.processInfo.environment
        let app = supplied["HAGIG_BUNDLED_APP"], wav = supplied["HAGIG_INTEGRATION_WAV"]
        if app == nil, wav == nil { throw XCTSkip("Requires a built, relocated Hagig.app and a WAV") }
        let appPath = try XCTUnwrap(app), wavPath = try XCTUnwrap(wav)
        XCTAssertTrue(appPath.hasPrefix("/") && wavPath.hasPrefix("/"))
        // Short and private, so the socket path fits sun_path.
        let root = URL(fileURLWithPath: "/private/tmp/hgb-" + String(UUID().uuidString.prefix(8)))
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        for name in ["home", "config/hagig", "data"] {
            try files.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try config.write(to: root.appendingPathComponent("config/hagig/config.toml"), atomically: false, encoding: .utf8)
        // No PATH, uv, PYTHONPATH or developer variables reach the helper.
        let environment = ["HOME": root.appendingPathComponent("home").path,
                           "XDG_RUNTIME_DIR": root.path,
                           "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "XDG_DATA_HOME": data ?? root.appendingPathComponent("data").path]
        let helper = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Helpers/hagig")
        let wavURL = URL(fileURLWithPath: wavPath)
        let controller = DictationController(presentation: presentation,
            makeRequest: { SocketRequest(helper: helper, environment: environment) },
            permission: { true }, makeCapture: { sink, _ in FileCapture(url: wavURL, sink: sink) })
        addTeardownBlock { @MainActor in
            controller.cancel()
            let stopped = try await Self.call(helper, ["stop"], environment)
            XCTAssertEqual(stopped.status, 0, "owned service cleanup must complete")
            guard stopped.status == 0 else { return }
            try FileManager.default.removeItem(at: root)
            print("BUNDLED_BACKEND_CLEANUP_COMPLETE")
        }
        return Setup(helper: helper, environment: environment, controller: controller)
    }

    @MainActor
    func testRecordingReachesTheBundledServerAndShowsModelMissing() async throws {
        let model = Presentation()
        let setup = try prepare(config: "[model]\nid = \"qwen3-asr-0.6b\"\n", presentation: model)
        let initial = try await Self.call(setup.helper, ["status"], setup.environment)
        XCTAssertEqual(initial.status, 0)
        XCTAssertEqual(initial.text, "stopped\n", "the app's helper start must launch the server")
        setup.controller.record()
        try await wait(seconds: 10) { model.stage != .awaitingAdmission }
        XCTAssertEqual(model.stage, .recording)
        XCTAssertEqual(model.modelID, "qwen3-asr-0.6b")
        let busy = try await statusJSON(setup)
        XCTAssertEqual(busy["state"] as? String, "busy")
        XCTAssertEqual(busy["network_isolation"] as? String, "required")
        setup.controller.stop()
        try await wait(seconds: 30) { model.stage != .transcribing }
        XCTAssertEqual(model.stage, .issue(.modelMissing))
        XCTAssertNil(model.transcript)
        XCTAssertFalse(model.copied)
        let idle = try await statusJSON(setup)
        XCTAssertEqual(idle["state"] as? String, "idle")
        XCTAssertEqual(idle["worker"] as? String, "absent")
    }

    /// Real inference: the bundled server launches its worker under Seatbelt and
    /// Qwen3-ASR 0.6B transcribes speech.wav ("Open the project and run the
    /// tests") into review. Never copied: review is explicit-Copy only.
    @MainActor
    func testRecordingGetsATranscriptFromAnInstalledModel() async throws {
        guard let data = ProcessInfo.processInfo.environment["HAGIG_BUNDLED_DATA"] else {
            throw XCTSkip("Requires HAGIG_BUNDLED_DATA with qwen3-asr-0.6b installed")
        }
        XCTAssertTrue(data.hasPrefix("/"))
        let model = Presentation()
        let setup = try prepare(config: "[model]\nid = \"qwen3-asr-0.6b\"\n",
                                presentation: model, data: data)
        setup.controller.record()
        try await wait(seconds: 10) { model.stage != .awaitingAdmission }
        XCTAssertEqual(model.stage, .recording)
        setup.controller.stop()
        // Cold: server start, worker launch, hashing about 1.5 GB, load, decode.
        try await wait(seconds: 150) { model.stage != .transcribing }
        XCTAssertEqual(model.stage, .fallback)
        let text = try XCTUnwrap(model.transcript)
        XCTAssertTrue(text.lowercased().contains("project"), "expected speech.wav's words")
        XCTAssertFalse(model.copied)
        let status = try await statusJSON(setup)
        XCTAssertEqual(status["network_isolation"] as? String, "required")
        XCTAssertEqual(status["worker"] as? String, "running")
        XCTAssertEqual(status["state"] as? String, "idle")
        print("BUNDLED_TRANSCRIPT_RECEIVED")
    }

    @MainActor
    func testMissingModelIDShowsConfigurationWithoutStartingAServer() async throws {
        let model = Presentation()
        let setup = try prepare(config: "[editor]\nmode = \"standard\"\n", presentation: model)
        setup.controller.record()
        try await wait(seconds: 10) { model.stage != .awaitingAdmission }
        XCTAssertEqual(model.stage, .issue(.configuration), "helper exit 2 is a configuration issue")
        let status = try await Self.call(setup.helper, ["status"], setup.environment)
        XCTAssertEqual(status.text, "stopped\n")
    }

    @MainActor
    private func statusJSON(_ setup: Setup) async throws -> [String: Any] {
        let result = try await Self.call(setup.helper, ["status"], setup.environment)
        XCTAssertEqual(result.status, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    }

    @MainActor
    private func wait(seconds: Int, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BackendFailure(code: "test_timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func call(_ helper: URL, _ arguments: [String],
                             _ environment: [String: String]) async throws -> (status: Int32, text: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else {
            process.terminate()
            throw BackendFailure(code: "test_timeout")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
