import AVFoundation
import XCTest
@testable import HagigPresentation

final class CaptureTests: XCTestCase {
    func testCanonicalConversionAndFiniteValidation() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let recording = try PCMRecording(format: format)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        input.frameLength = 4_800
        for i in 0..<4_800 { input.floatChannelData![0][i] = 0.25 }
        try recording.append(input)
        let bytes = recording.finish()
        XCTAssertGreaterThan(bytes.count, 5_000)
        XCTAssertLessThanOrEqual(bytes.count, 6_400)
        XCTAssertEqual(bytes.count % 4, 0)
        // Independently decode little-endian samples, not converter internals.
        let middle = bytes.count / 8 * 4
        let bits = bytes[middle..<(middle + 4)].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * $1.offset)
        }
        XCTAssertEqual(Float(bitPattern: bits), 0.25, accuracy: 0.001)
        XCTAssertThrowsError(try recording.append(input))

        let changedFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let changed = AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4_800)!
        changed.frameLength = 4_800
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_385)!
        oversized.frameLength = 16_385
        for rejected in [changed, empty, oversized] {
            let interrupted = try PCMRecording(format: format)
            try interrupted.append(input)
            XCTAssertThrowsError(try interrupted.append(rejected))
            // Stop can win against the queued main-actor failure event. The
            // recording itself must already have discarded the valid prefix.
            XCTAssertTrue(interrupted.finish().isEmpty, "failed capture discards prior PCM before Stop")
            XCTAssertThrowsError(try interrupted.append(input))
            XCTAssertTrue(interrupted.finish().isEmpty)
        }

        let invalid = try PCMRecording(format: format)
        input.floatChannelData![0][100] = .nan
        XCTAssertThrowsError(try invalid.append(input))
        XCTAssertTrue(invalid.finish().isEmpty)
    }

    func testWarningCapAndStopAreBounded() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        input.frameLength = 16_000
        input.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let recording = try PCMRecording(format: format)
        for _ in 0..<284 { try recording.append(input) }
        XCTAssertFalse(recording.nearLimit)
        try recording.append(input)
        XCTAssertTrue(recording.nearLimit)
        XCTAssertFalse(recording.atLimit)
        for _ in 285..<300 { try recording.append(input) }
        XCTAssertTrue(recording.atLimit)
        try recording.append(input) // Already capped input cannot grow the buffer.
        XCTAssertEqual(recording.finish().count, 19_200_000)
        XCTAssertTrue(recording.finish().isEmpty)

        let stopped = try PCMRecording(format: format)
        try stopped.append(input)
        XCTAssertEqual(stopped.finish().count, 64_000)
        XCTAssertThrowsError(try stopped.append(input))
        XCTAssertTrue(stopped.finish().isEmpty)
    }
}
