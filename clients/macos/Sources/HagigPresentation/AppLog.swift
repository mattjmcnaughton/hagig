import Darwin
import Foundation

/// Every event the app logs. The raw values are the fixed names in `app.log`.
public enum AppEvent: String, CaseIterable, Sendable {
    case appLaunched = "app_launched"
    case appTerminated = "app_terminated"
    /// `count`: shortcuts registered.
    case shortcutsRegistered = "shortcuts_registered"
    /// `stage`: `record` or `cancel`.
    case shortcutRegistrationFailed = "shortcut_registration_failed"
    /// `source`: `button` or `shortcut`.
    case recordingStarted = "recording_started"
    /// `duration_ms` of capture, `bytes` of canonical PCM sent.
    case recordingStopped = "recording_stopped"
    /// The five-minute cap ended capture; same fields as stopped.
    case recordingAutoStopped = "recording_auto_stopped"
    /// `stage`: `admission`, `recording` or `transcribing`.
    case recordingCancelled = "recording_cancelled"
    /// `duration_ms` from Stop to the result.
    case transcriptionCompleted = "transcription_completed"
    case transcriptionNoSpeech = "transcription_no_speech"
    /// `code`: the stable failure code; `stage`: the issue shown.
    case dictationFailed = "dictation_failed"
    case reviewCopied = "review_copied"
    case reviewCopyFailed = "review_copy_failed"
    case reviewDismissed = "review_dismissed"
    case panelShown = "panel_shown"
    case panelHidden = "panel_hidden"
    /// `mode`: `enabled` or `disabled`.
    case loginItemChanged = "login_item_changed"
    /// `mode`: the state that could not be set.
    case loginItemFailed = "login_item_failed"
    case settingsSaved = "settings_saved"
    /// `code`: the helper's stable code.
    case settingsSaveFailed = "settings_save_failed"
    /// `model`: the alias (configuration, not content).
    case modelDownloadStarted = "model_download_started"
    case modelDownloadFinished = "model_download_finished"
    case modelDownloadFailed = "model_download_failed"

    var level: String {
        switch self {
        case .shortcutRegistrationFailed, .dictationFailed, .reviewCopyFailed, .loginItemFailed,
             .settingsSaveFailed, .modelDownloadFailed: return "warning"
        default: return "info"
        }
    }
}

public enum RecordingSource: String, Sendable { case button, shortcut }

/// The closed set of fields an event may carry. Strings must be plain tokens
/// (`[A-Za-z0-9_.-]`, at most 64); anything else is written as `unrecognized`.
/// `code` keeps only what precedes a colon, so a helper's `code: detail` line
/// never brings its detail (a path, a field name) along.
public struct AppLogFields: Equatable, Sendable {
    public var code: String?
    public var stage: String?
    public var source: String?
    public var mode: String?
    public var model: String?
    public var durationMs: Int?
    public var count: Int?
    public var bytes: Int?

    public init(code: String? = nil, stage: String? = nil, source: String? = nil, mode: String? = nil,
                model: String? = nil, durationMs: Int? = nil, count: Int? = nil, bytes: Int? = nil) {
        self.code = code; self.stage = stage; self.source = source; self.mode = mode; self.model = model
        self.durationMs = durationMs; self.count = count; self.bytes = bytes
    }
}

/// Content-free JSON lines in `<logs>/app.log` (TDD §10): one line per
/// `AppEvent` with an ISO timestamp, a level and `AppLogFields`; never
/// transcripts, audio, vocabulary, settings content, paths or OS error text.
///
/// The directory comes from the backend (`hagig settings show`'s `logs_dir`)
/// through `use(directory:)`; until then events are dropped, not buffered.
/// Writes happen on a private serial queue. The directory is created 0700 and
/// the file 0600; an existing one that is a symlink, not ours or open to others
/// is refused untouched. Past `maxBytes` the file becomes `app.log.1`,
/// replacing the previous one. Every failure is silent.
public final class AppLog: @unchecked Sendable {
    public static let fileName = "app.log"
    public static let defaultMaxBytes = 1 << 20
    static let unrecognized = "unrecognized"

    private let enabled: Bool
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.mattjmcnaughton.hagig.app-log")
    // Everything below is used only on `queue`.
    private let formatter: ISO8601DateFormatter
    private var directory: URL?
    private var fd: Int32 = -1

    public convenience init(maxBytes: Int = AppLog.defaultMaxBytes) {
        self.init(enabled: true, maxBytes: maxBytes)
    }

    private init(enabled: Bool, maxBytes: Int) {
        self.enabled = enabled
        self.maxBytes = maxBytes
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Writes nothing: the render harness, synthetic demo and tests.
    public static var inert: AppLog { AppLog(enabled: false, maxBytes: 0) }

    /// The logs directory the backend reported. Earlier events were dropped.
    public func use(directory: URL) {
        guard enabled else { return }
        queue.async { [self] in
            guard self.directory != directory else { return }
            closeFile()
            self.directory = directory
        }
    }

    public func record(_ event: AppEvent, _ fields: AppLogFields = AppLogFields()) {
        guard enabled else { return }
        let date = Date()
        queue.async { [self] in
            guard directory != nil else { return }
            write(Data(line(event, fields, at: date).utf8))
        }
    }

    /// Waits for every event recorded so far, for example before the app exits.
    public func flush() { queue.sync {} }

    // MARK: Rendering

    private func line(_ event: AppEvent, _ fields: AppLogFields, at date: Date) -> String {
        var line = "{\"timestamp\":\"\(formatter.string(from: date))\",\"level\":\"\(event.level)\""
            + ",\"event\":\"\(event.rawValue)\""
        let strings: [(String, String?)] = [("code", fields.code.map(Self.code)), ("stage", fields.stage.map(Self.token)),
                                            ("source", fields.source.map(Self.token)),
                                            ("mode", fields.mode.map(Self.token)), ("model", fields.model.map(Self.token))]
        for case let (key, value?) in strings { line += ",\"\(key)\":\"\(value)\"" }
        let numbers: [(String, Int?)] = [("duration_ms", fields.durationMs), ("count", fields.count),
                                         ("bytes", fields.bytes)]
        for case let (key, value?) in numbers { line += ",\"\(key)\":\(value)" }
        return line + "}\n"
    }

    /// A plain token, or `unrecognized`; never needs JSON escaping.
    static func token(_ value: String) -> String {
        let plain = !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }
        return plain ? value : unrecognized
    }

    static func code(_ value: String) -> String {
        token(String(value.prefix { $0 != ":" }))
    }

    // MARK: The file

    private func write(_ data: Data) {
        guard let directory else { return }
        let path = directory.appendingPathComponent(Self.fileName).path
        if fd < 0 { fd = Self.open(path, in: directory) }
        guard fd >= 0 else { return }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0, Int(info.st_size) + data.count > maxBytes {
            let inode = info.st_ino
            closeFile()
            var current = stat()
            // Only our own file: another writer may already have rotated it.
            if lstat(path, &current) == 0, current.st_ino == inode { _ = rename(path, path + ".1") }
            fd = Self.open(path, in: directory)
            guard fd >= 0 else { return }
        }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written != data.count { closeFile() }
    }

    private func closeFile() {
        if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
    }

    private static func open(_ path: String, in directory: URL) -> Int32 {
        guard prepare(directory) else { return -1 }
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o170000 == 0o100000, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600 else {
            _ = Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// `hagig/` and `logs/` as the backend's `paths.ensure_logs_dir` makes them.
    private static func prepare(_ logs: URL) -> Bool {
        let state = logs.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: state.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        for (url, exposed) in [(state, mode_t(0o022)), (logs, mode_t(0o077))] {
            _ = mkdir(url.path, 0o700)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & 0o170000 == 0o040000,
                  info.st_uid == getuid(), info.st_mode & exposed == 0 else { return false }
        }
        return true
    }
}
