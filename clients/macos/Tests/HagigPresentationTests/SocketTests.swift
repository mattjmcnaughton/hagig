import Darwin
import Foundation
import XCTest
@testable import HagigPresentation

/// Explicit test peer, not a production server selection. Uses only synthetic
/// bytes from #9 protocol fixtures at 791f99c; no model or microphone.
private final class Peer {
    let root = "/private/tmp/hagig-" + String(UUID().uuidString.prefix(8))
    let listener: Int32
    let done = DispatchSemaphore(value: 0)
    init() throws {
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: "test.socket", code: 1) }
        try FileManager.default.createDirectory(atPath: root + "/hagig", withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array((root + "/hagig/server.sock").utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0,
              chmod(root + "/hagig/server.sock", 0o600) == 0 else {
            throw NSError(domain: "test.socket", code: 2)
        }
    }
    deinit { Darwin.close(listener); try? FileManager.default.removeItem(atPath: root) }

    func serve(_ action: @escaping (Int32) throws -> Void) {
        DispatchQueue.global().async {
            defer { self.done.signal() }
            var listening = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&listening, 1, 5_000) > 0 else { XCTFail("Peer accept deadline"); return }
            let fd = Darwin.accept(self.listener, nil, nil)
            guard fd >= 0 else { XCTFail("Peer accept"); return }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            do { try action(fd) } catch { XCTFail("Controlled peer failed") }
        }
    }

    static func read(_ fd: Int32) throws -> (UInt8, Data) {
        func exact(_ count: Int) throws -> Data {
            var bytes = Data(count: count)
            var offset = 0
            while offset < count {
                let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
                guard n > 0 else { throw NSError(domain: "test.eof", code: 1) }
                offset += n
            }
            return bytes
        }
        let header = try exact(5)
        let length = header.dropFirst().reduce(0) { $0 * 256 + Int($1) }
        guard length <= 262_144 else { throw NSError(domain: "test.cap", code: 1) }
        return (header[0], try exact(length))
    }

    static func send(_ fd: Int32, _ payload: String) throws {
        let bytes = Data(payload.utf8)
        var length = UInt32(bytes.count).bigEndian
        var frame = Data([1])
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(bytes)
        // Fragment header/body deliberately, unlike a codec-only round trip.
        for byte in frame {
            var value = byte
            guard Darwin.write(fd, &value, 1) == 1 else { throw NSError(domain: "test.write", code: 1) }
        }
    }

    static let hello = #"{"version":1,"type":"hello_ok","worker":"inference","network_isolation":"required","config_generation":"server-1","settings":{"editor_mode":"vim","model_id":"parakeet-tdt-0.6b-v2-int8-v1","model_revision":"1ab9323565ddb038682214b292f588070a538ce2","language":"en"},"audio":{"encoding":"f32le","sample_rate_hz":16000,"channels":1},"limits":{"control_bytes":65536,"audio_chunk_bytes":262144,"audio_total_bytes":19200000,"recording_seconds":300,"warning_seconds":285,"request_id_bytes":128},"deadlines":{"control_seconds":5,"reservation_seconds":330,"computation_seconds":120}}"#
}

final class SocketTests: XCTestCase {
    @MainActor
    func testFragmentedHandshakeAndDelayedUnicodeResult() async throws {
        let peer = try Peer()
        let id = UUID()
        let pcm = Data([0, 0, 0, 0x3e, 0, 0, 0x40, 0xbf, 0, 0, 0x80, 0x3f])
        peer.serve { fd in
            let hello = try JSONSerialization.jsonObject(with: Peer.read(fd).1) as! [String: Any]
            XCTAssertEqual(hello["type"] as? String, "hello")
            try Peer.send(fd, Peer.hello)
            let begin = try JSONSerialization.jsonObject(with: Peer.read(fd).1) as! [String: Any]
            XCTAssertEqual(begin["request_id"] as? String, id.uuidString)
            try Peer.send(fd, "{\"version\":1,\"type\":\"accepted\",\"request_id\":\"\(id.uuidString)\",\"config_generation\":\"server-1\",\"model_id\":\"parakeet-tdt-0.6b-v2-int8-v1\"}")
            let audio = try Peer.read(fd)
            XCTAssertEqual(audio.0, 2)
            XCTAssertEqual(audio.1, pcm)
            let end = try JSONSerialization.jsonObject(with: Peer.read(fd).1) as! [String: Any]
            XCTAssertEqual(end["type"] as? String, "end_audio")
            Thread.sleep(forTimeInterval: 6) // Distinguishes inference wait from five-second control I/O.
            try Peer.send(fd, "{\"version\":1,\"type\":\"result\",\"request_id\":\"\(id.uuidString)\",\"text\":\"Fixture λ.\\nNext.\"}")
        }
        let request = SocketRequest(helper: URL(fileURLWithPath: "/usr/bin/true"), environment: ["XDG_RUNTIME_DIR": peer.root])
        defer { request.cancel() }
        let mode = try await request.reserve(id: id)
        XCTAssertEqual(mode, .vim)
        let text = try await request.transcribe(pcm, id: id)
        XCTAssertEqual(text, "Fixture λ.\nNext.")
        XCTAssertEqual(peer.done.wait(timeout: .now() + 1), .success)
    }

    @MainActor
    func testFakeMalformedCapabilitiesAndDuplicateKeysAreRejected() async throws {
        let variants = [
            Peer.hello.replacingOccurrences(of: "inference", with: "controlled_fake"),
            Peer.hello.replacingOccurrences(of: "16000", with: "48000"),
            Peer.hello.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            Peer.hello.replacingOccurrences(of: "\"type\":\"hello_ok\"", with: #""type":"hello_ok","\u0074ype":"hello_ok""#),
        ]
        for response in variants {
            let peer = try Peer()
            let id = UUID()
            peer.serve { fd in
                _ = try Peer.read(fd)
                try Peer.send(fd, response)
                // Stay functional if validation is accidentally removed: EOF
                // after the bad hello must not mask an erroneously sent begin.
                do {
                    _ = try Peer.read(fd)
                    XCTFail("Client sent begin after incompatible hello")
                    try Peer.send(fd, "{\"version\":1,\"type\":\"accepted\",\"request_id\":\"\(id.uuidString)\",\"config_generation\":\"server-1\",\"model_id\":\"parakeet-tdt-0.6b-v2-int8-v1\"}")
                } catch { /* Expected owner disconnect before begin. */ }
            }
            let request = SocketRequest(helper: URL(fileURLWithPath: "/usr/bin/true"), environment: ["XDG_RUNTIME_DIR": peer.root])
            do { _ = try await request.reserve(id: id); XCTFail("Incompatible peer accepted") }
            catch { /* Rejected before begin/capture. */ }
            request.cancel()
            XCTAssertEqual(peer.done.wait(timeout: .now() + 1), .success)
        }
    }

    @MainActor
    func testBlockedUploadUsesFiveSecondFrameDeadline() async throws {
        let peer = try Peer()
        let id = UUID()
        peer.serve { fd in
            _ = try Peer.read(fd)
            try Peer.send(fd, Peer.hello)
            _ = try Peer.read(fd)
            try Peer.send(fd, "{\"version\":1,\"type\":\"accepted\",\"request_id\":\"\(id.uuidString)\",\"config_generation\":\"server-1\",\"model_id\":\"parakeet-tdt-0.6b-v2-int8-v1\"}")
            // Never consume the audio. With a30s write budget the peer's later
            // EOF masks the required5s deadline and gives the wrong error.
            Thread.sleep(forTimeInterval: 6.5)
        }
        let request = SocketRequest(helper: URL(fileURLWithPath: "/usr/bin/true"), environment: ["XDG_RUNTIME_DIR": peer.root])
        _ = try await request.reserve(id: id)
        do {
            _ = try await request.transcribe(Data(repeating: 0, count: 1_048_576), id: id)
            XCTFail("Blocked upload succeeded")
        } catch let failure as BackendFailure { XCTAssertEqual(failure.issue, .deadlineExceeded) }
        request.cancel()
        XCTAssertEqual(peer.done.wait(timeout: .now() + 3), .success)
    }

    @MainActor
    func testBusyIsSafeAndOversizedHeaderNeedsNoPayload() async throws {
        for oversized in [false, true] {
            let peer = try Peer()
            let id = UUID()
            peer.serve { fd in
                _ = try Peer.read(fd)
                if oversized {
                    var header: [UInt8] = [1, 0, 1, 0, 1] // 65,537: no body follows.
                    _ = Darwin.write(fd, &header, header.count)
                } else {
                    try Peer.send(fd, Peer.hello)
                    _ = try Peer.read(fd)
                    try Peer.send(fd, "{\"version\":1,\"type\":\"error\",\"request_id\":\"\(id.uuidString)\",\"code\":\"busy\"}")
                }
            }
            let request = SocketRequest(helper: URL(fileURLWithPath: "/usr/bin/true"), environment: ["XDG_RUNTIME_DIR": peer.root])
            do { _ = try await request.reserve(id: id); XCTFail("Rejected response accepted") }
            catch let error as BackendFailure { XCTAssertEqual(error.issue, oversized ? .serverUnavailable : .busy) }
            request.cancel()
            XCTAssertEqual(peer.done.wait(timeout: .now() + 1), .success)
        }
    }
}
