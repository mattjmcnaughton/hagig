import AVFoundation
import Foundation

enum CaptureFailure: Error {
    case permission, device, invalidAudio
}

/// Owns one bounded recording and converter. Each converted chunk goes to `sink`
/// (the open upload) as capture produces it; no recording buffer is kept. The
/// engine callback and Stop may race; finishing atomically closes the recording.
final class PCMRecording {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sink: (Data) -> Void
    private var sent = 0
    private var failed = false
    private var closed = false
    private static let maximumBytes = 19_200_000

    init(format: AVAudioFormat, sink: @escaping (Data) -> Void) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw CaptureFailure.device
        }
        self.converter = converter
        outputFormat = output
        self.sink = sink
    }

    var nearLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return sent >= 285 * 16_000 * 4
    }

    var atLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return sent == Self.maximumBytes
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        var accepted = false
        defer {
            // Invalidate before releasing the lock, not in the later UI event:
            // Stop must never end an upload whose capture failed.
            if !accepted { failed = true; closed = true }
        }
        guard !closed else { throw CaptureFailure.invalidAudio }
        guard sent < Self.maximumBytes else { accepted = true; return }
        // Bound converter allocation independently of a changing input device.
        guard input.frameLength > 0, input.frameLength <= 16_384,
              input.format == converter.inputFormat else { throw CaptureFailure.device }
        let frames = ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32
        guard frames <= 262_144,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            throw CaptureFailure.device
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let samples = output.floatChannelData?[0] else {
            throw CaptureFailure.invalidAudio
        }
        // Validate the entire converted chunk before accepting any of it.
        for index in 0..<Int(output.frameLength) where !samples[index].isFinite || abs(samples[index]) > 1 {
            throw CaptureFailure.invalidAudio
        }
        let count = min(Int(output.frameLength), (Self.maximumBytes - sent) / 4)
        var chunk = Data(capacity: count * 4)
        for index in 0..<count {
            var value = samples[index].bitPattern.littleEndian
            withUnsafeBytes(of: &value) { chunk.append(contentsOf: $0) }
        }
        if !chunk.isEmpty { sink(chunk) }
        sent += chunk.count
        accepted = true
    }

    /// Closes the recording and returns the bytes streamed, or 0 after a failure.
    func finish() -> Int {
        lock.lock(); defer { lock.unlock() }
        closed = true
        return failed ? 0 : sent
    }
}

/// Microphone permission and engine lifetime belong to the main actor. No file
/// writer or system clipboard is involved. Instantiate only after admission.
@MainActor
final class MicrophoneCapture {
    enum Event { case warning, limit, failed }
    private let engine = AVAudioEngine()
    private var recording: PCMRecording?
    private var observer: NSObjectProtocol?
    private var tapped = false
    private var timer: Timer?
    private let sink: @Sendable (Data) -> Void
    private let event: (Event) -> Void

    init(sink: @escaping @Sendable (Data) -> Void, event: @escaping (Event) -> Void) {
        self.sink = sink
        self.event = event
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureFailure.permission
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let buffer = try PCMRecording(format: format, sink: sink)
        recording = buffer
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] pcm, _ in
            do {
                try buffer.append(pcm)
                let capped = buffer.atLimit
                Task { @MainActor [weak self] in
                    guard let self, self.recording === buffer else { return }
                    if buffer.nearLimit { self.event(.warning) }
                    if capped { self.event(.limit) }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.recording === buffer else { return }
                    self.event(.failed)
                }
            }
        }
        tapped = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.event(.failed) }
        }
        do { try engine.start() } catch { _ = stop(); throw CaptureFailure.device }
        let started = ContinuousClock.now
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recording != nil else { return }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      self.engine.isRunning else { self.event(.failed); return }
                let elapsed = started.duration(to: .now)
                if elapsed >= .seconds(285) { self.event(.warning) }
                if elapsed >= .seconds(300) { self.event(.limit) }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// True only when the recording streamed audio and did not fail.
    @discardableResult func stop() -> Bool {
        let buffer = recording
        recording = nil
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        return (buffer?.finish() ?? 0) > 0
    }
}
