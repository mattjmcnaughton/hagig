import Darwin
import Foundation

/// A single request connection. All I/O/close runs on one serial queue; Cancel
/// only shuts down the owned descriptor, so it cannot close a reused fd.
final class UnixChannel {
    private let queue = DispatchQueue(label: "hagig.socket")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    func run<T>(_ operation: @escaping (UnixChannel) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    private func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func connect(path: String, deadline: ContinuousClock.Instant) throws {
        try checkCancellation()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendFailure(issue: .serverUnavailable) }
        lock.lock()
        descriptor = fd
        let alreadyCancelled = cancelled
        lock.unlock()
        guard !alreadyCancelled else { throw CancellationError() }
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= 101 else { throw BackendFailure(issue: .serverUnavailable) }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw BackendFailure(issue: .serverUnavailable) }
            try wait(POLLOUT, deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw BackendFailure(issue: .serverUnavailable)
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw BackendFailure(issue: .serverUnavailable)
        }
    }

    private func wait(_ events: Int32, deadline: ContinuousClock.Instant) throws {
        while true {
            try checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw BackendFailure(issue: .deadlineExceeded) }
            let seconds = remaining.components
            let milliseconds = min(Int64(100), seconds.seconds * 1_000 + seconds.attoseconds / 1_000_000_000_000_000)
            var item = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let status = Darwin.poll(&item, 1, Int32(max(1, milliseconds)))
            if status > 0 {
                guard Int32(item.revents) & POLLNVAL == 0 else { throw BackendFailure(issue: .serverUnavailable) }
                return // read/write/SO_ERROR classifies HUP/ERR, including buffered EOF.
            }
            if status < 0, errno != EINTR { throw BackendFailure(issue: .serverUnavailable) }
        }
    }

    func send(kind: UInt8, payload: Data, deadline: ContinuousClock.Instant) throws {
        guard (kind == 1 && payload.count <= 65_536) ||
              (kind == 2 && payload.count <= 262_144 && payload.count % 4 == 0) else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data([kind])
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        var offset = 0
        while offset < frame.count {
            try wait(POLLOUT, deadline: deadline)
            let count = frame.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset)
            }
            if count > 0 { offset += count }
            else if count == 0 || !(errno == EINTR || errno == EAGAIN) {
                throw BackendFailure(issue: .serverUnavailable)
            }
        }
    }

    private func read(count: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(POLLIN, deadline: deadline)
            let received = result.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if received > 0 { offset += received }
            else if received == 0 || !(errno == EINTR || errno == EAGAIN) {
                throw BackendFailure(issue: .serverUnavailable)
            }
        }
        return result
    }

    func receive(firstByteDeadline: ContinuousClock.Instant,
                 frameDeadline: ContinuousClock.Instant? = nil) throws -> Data {
        let first = try read(count: 1, deadline: firstByteDeadline)
        let partialDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        let assemblyDeadline = min(frameDeadline ?? partialDeadline, partialDeadline)
        let lengthBytes = try read(count: 4, deadline: assemblyDeadline)
        let length = lengthBytes.reduce(0) { $0 * 256 + Int($1) }
        guard first[0] == 1, length > 0, length <= 65_536 else {
            throw BackendFailure(issue: .serverUnavailable)
        }
        return try read(count: length, deadline: assemblyDeadline)
    }
}
