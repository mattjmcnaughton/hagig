import Darwin
import XCTest
import HagigPresentation

/// `AppLog` through its public interface, on a real temporary directory.
final class AppLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("applog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    /// `<root>/state/hagig/logs`, as the backend reports it.
    private var logs: URL { root.appendingPathComponent("state/hagig/logs") }

    private func records(_ name: String = AppLog.fileName) throws -> [[String: Any]] {
        let text = try String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    func testWritesOnlyTheClosedFieldsInPrivateFiles() throws {
        let log = AppLog()
        log.record(.appLaunched) // Before the folder is known: dropped, not buffered.
        log.use(directory: logs)
        log.record(.recordingStopped, AppLogFields(durationMs: 1234, bytes: 64_000))
        // A helper line with a path after the code, and a value that is not a token.
        log.record(.settingsSaveFailed, AppLogFields(code: "config_unloadable: fix or replace /Users/SENTINEL/config.toml"))
        log.record(.modelDownloadFailed, AppLogFields(code: "download_failed", model: "SENTINEL \"quoted\"\n"))
        log.flush()
        let raw = try String(contentsOf: logs.appendingPathComponent(AppLog.fileName), encoding: .utf8)
        XCTAssertFalse(raw.contains("SENTINEL"))
        XCTAssertFalse(raw.contains("app_launched"))
        let lines = try records()
        XCTAssertEqual(lines.count, 3)
        let allowed: Set<String> = ["timestamp", "level", "event", "code", "stage", "source", "mode", "model",
                                    "duration_ms", "count", "bytes"]
        for line in lines { XCTAssertTrue(Set(line.keys).isSubset(of: allowed), "\(line.keys)") }
        XCTAssertEqual(lines[0]["event"] as? String, "recording_stopped")
        XCTAssertEqual(lines[0]["level"] as? String, "info")
        XCTAssertEqual(lines[0]["duration_ms"] as? Int, 1234)
        XCTAssertEqual(lines[0]["bytes"] as? Int, 64_000)
        XCTAssertNotNil(ISO8601DateFormatter.withFractionalSeconds.date(from: lines[0]["timestamp"] as? String ?? ""))
        XCTAssertEqual(lines[1]["code"] as? String, "config_unloadable")
        XCTAssertEqual(lines[1]["level"] as? String, "warning")
        XCTAssertEqual(lines[2]["model"] as? String, "unrecognized")
        XCTAssertEqual(mode(logs.appendingPathComponent(AppLog.fileName)), 0o600)
        XCTAssertEqual(mode(logs), 0o700)
        XCTAssertEqual(mode(logs.deletingLastPathComponent()), 0o700)
    }

    func testRotatesAtTheBoundKeepingOnePreviousFile() throws {
        let log = AppLog(maxBytes: 300)
        log.use(directory: logs)
        for _ in 0..<12 { log.record(.panelShown) }
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        XCTAssertEqual(names, ["app.log", "app.log.1"])
        for name in names {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logs.appendingPathComponent(name).path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, 300, name)
        }
        let kept = try records() + records("app.log.1")
        XCTAssertLessThan(kept.count, 12) // The oldest went with the replaced previous file.
        XCTAssertTrue(kept.allSatisfy { $0["event"] as? String == "panel_shown" })
        XCTAssertEqual(mode(logs.appendingPathComponent("app.log")), 0o600)
    }

    func testAnUnwritableOrSymlinkedFolderIsSilentAndUntouched() throws {
        // Unwritable: the state base cannot hold `hagig/`.
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(state.path, 0o500), 0)
        let log = AppLog()
        log.use(directory: logs)
        log.record(.appLaunched)
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
        XCTAssertEqual(chmod(state.path, 0o700), 0)

        // Symlinked `logs/`: refused, its target stays empty.
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = chmod(logs.deletingLastPathComponent().path, 0o700)
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: target)
        let linked = AppLog()
        linked.use(directory: logs)
        linked.record(.appLaunched)
        linked.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testInertWritesNothing() throws {
        let log = AppLog.inert
        log.use(directory: logs)
        log.record(.appLaunched)
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
