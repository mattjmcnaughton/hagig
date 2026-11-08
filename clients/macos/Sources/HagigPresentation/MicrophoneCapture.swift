import AVFoundation
import Foundation

enum CaptureFailure: Error {
    case permission, device, invalidAudio
}

/// Owns one bounded recording and converter. The engine callback and Stop may
/// race; finishing atomically closes the buffer before returning its contents.
final class PCMRecording {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var bytes = Data()
    private var closed = false
    private static let maximumBytes = 19_200_000

    init(format: AVAudioFormat) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw CaptureFailure.device
        }
        self.converter = converter
        outputFormat = output
    }

    var nearLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return bytes.count >= 285 * 16_000 * 4
    }

    var atLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return bytes.count == Self.maximumBytes
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        var accepted = false
        defer {
            // Invalidate before releasing the lock, not in the later UI event:
            // Stop must never recover a prefix from a failed capture.
            if !accepted { bytes.removeAll(); closed = true }
        }
        guard !closed else { throw CaptureFailure.invalidAudio }
        guard bytes.count < Self.maximumBytes else { accepted = true; return }
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
        let count = min(Int(output.frameLength), (Self.maximumBytes - bytes.count) / 4)
        for index in 0..<count {
            var value = samples[index].bitPattern.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        accepted = true
    }

    func finish() -> Data {
        lock.lock(); defer { lock.unlock() }
        closed = true
        let result = bytes
        bytes = Data()
        return result
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
    private let event: (Event) -> Void

    init(event: @escaping (Event) -> Void) { self.event = event }

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
        let buffer = try PCMRecording(format: format)
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

    func stop() -> Data {
        let buffer = recording
        recording = nil
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        return buffer?.finish() ?? Data()
    }
}
