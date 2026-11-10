import AVFoundation
import XCTest
@testable import HagigPresentation

/// Collects what a recording streams, standing in for the open upload.
private final class Streamed: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class CaptureTests: XCTestCase {
    func testCanonicalConversionAndFiniteValidation() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let streamed = Streamed()
        let recording = try PCMRecording(format: format, sink: streamed.append)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        input.frameLength = 4_800
        for i in 0..<4_800 { input.floatChannelData![0][i] = 0.25 }
        try recording.append(input)
        // Streamed during capture, before Stop: no recording buffer waits for finish.
        let bytes = streamed.bytes
        XCTAssertGreaterThan(bytes.count, 5_000)
        XCTAssertLessThanOrEqual(bytes.count, 6_400)
        XCTAssertEqual(bytes.count % 4, 0)
        // Independently decode little-endian samples, not converter internals.
        let middle = bytes.count / 8 * 4
        let bits = bytes[middle..<(middle + 4)].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * $1.offset)
        }
        XCTAssertEqual(Float(bitPattern: bits), 0.25, accuracy: 0.001)
        XCTAssertEqual(recording.finish(), bytes.count)
        XCTAssertThrowsError(try recording.append(input))
        XCTAssertEqual(streamed.bytes, bytes, "a finished recording streams nothing more")

        let changedFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let changed = AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4_800)!
        changed.frameLength = 4_800
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_385)!
        oversized.frameLength = 16_385
        for rejected in [changed, empty, oversized] {
            let interruptedStream = Streamed()
            let interrupted = try PCMRecording(format: format, sink: interruptedStream.append)
            try interrupted.append(input)
            let prefix = interruptedStream.bytes
            XCTAssertThrowsError(try interrupted.append(rejected))
            // Stop can win against the queued main-actor failure event. The
            // recording itself must already report the failure so Stop cancels
            // the upload instead of ending its body.
            XCTAssertEqual(interrupted.finish(), 0, "failed capture never completes its upload")
            XCTAssertThrowsError(try interrupted.append(input))
            XCTAssertEqual(interrupted.finish(), 0)
            XCTAssertEqual(interruptedStream.bytes, prefix, "nothing is streamed after the failure")
        }

        let invalidStream = Streamed()
        let invalid = try PCMRecording(format: format, sink: invalidStream.append)
        input.floatChannelData![0][100] = .nan
        XCTAssertThrowsError(try invalid.append(input))
        XCTAssertEqual(invalid.finish(), 0)
        XCTAssertTrue(invalidStream.bytes.isEmpty, "an invalid chunk is never partly streamed")
    }

    func testWarningCapAndStopAreBounded() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        input.frameLength = 16_000
        input.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let streamed = Streamed()
        let recording = try PCMRecording(format: format, sink: streamed.append)
        for _ in 0..<284 { try recording.append(input) }
        XCTAssertFalse(recording.nearLimit)
        try recording.append(input)
        XCTAssertTrue(recording.nearLimit)
        XCTAssertFalse(recording.atLimit)
        for _ in 285..<300 { try recording.append(input) }
        XCTAssertTrue(recording.atLimit)
        try recording.append(input) // Already capped input cannot grow the upload.
        XCTAssertEqual(streamed.bytes.count, 19_200_000)
        XCTAssertEqual(recording.finish(), 19_200_000)

        let stoppedStream = Streamed()
        let stopped = try PCMRecording(format: format, sink: stoppedStream.append)
        try stopped.append(input)
        XCTAssertEqual(stopped.finish(), 64_000)
        XCTAssertThrowsError(try stopped.append(input))
        XCTAssertEqual(stoppedStream.bytes.count, 64_000)
    }
}
