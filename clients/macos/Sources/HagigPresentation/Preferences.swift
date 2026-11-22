import Foundation

/// How a paired-helper command ended: its exit status, and its one stderr line
/// when that line is short and plain (the CLI prints only stable codes there).
public struct HelperExit: Sendable, Equatable {
    public let status: Int32
    public let error: String?
    public init(status: Int32, error: String?) { self.status = status; self.error = error }
}

/// Runs the paired helper with arguments, calling `line` for each stdout line as
/// it arrives. Cancelling the calling task interrupts the helper (SIGINT), which
/// the CLI turns into `interrupted` and leaves any earlier installation alone.
public typealias HelperRun = @Sendable (_ arguments: [String], _ input: Data?,
                                        _ line: @escaping @Sendable (String) -> Void) async -> HelperExit

/// One model in the backend's registry (`hagig model list --json`).
public struct ModelEntry: Equatable, Identifiable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let engine: String
    public let publisher: String
    public let repository: String
    public let license: String
    public let downloadBytes: Int64
    public let supported: Bool
    /// `installed`, `missing` or `invalid`.
    public let installed: String

    public init(id: String, name: String, engine: String, publisher: String, repository: String,
                license: String, downloadBytes: Int64, supported: Bool, installed: String) {
        self.id = id; self.name = name; self.engine = engine; self.publisher = publisher
        self.repository = repository; self.license = license; self.downloadBytes = downloadBytes
        self.supported = supported; self.installed = installed
    }
}

/// The settings file as the backend reads it (`hagig settings show`).
public struct StoredSettings: Equatable, Sendable, Codable {
    public var modelId: String
    public var editorMode: String
    public var networkIsolation: String
    public var vocabulary: [String]
    /// Global shortcuts in the config syntax (see `Shortcut`).
    public var recordShortcut: String
    public var cancelShortcut: String
    /// Review's Copy all and Dismiss (`ReviewShortcuts`).
    public var copyShortcut: String
    public var dismissShortcut: String

    public init(modelId: String, editorMode: String = "standard", networkIsolation: String = "required",
                vocabulary: [String] = [], recordShortcut: String = Shortcut.defaultRecord,
                cancelShortcut: String = Shortcut.defaultCancel, copyShortcut: String = Shortcut.defaultCopy,
                dismissShortcut: String = Shortcut.defaultDismiss) {
        self.modelId = modelId; self.editorMode = editorMode
        self.networkIsolation = networkIsolation; self.vocabulary = vocabulary
        self.recordShortcut = recordShortcut; self.cancelShortcut = cancelShortcut
        self.copyShortcut = copyShortcut; self.dismissShortcut = dismissShortcut
    }

    enum CodingKeys: String, CodingKey {
        case modelId, editorMode, networkIsolation, vocabulary, recordShortcut, cancelShortcut
        case copyShortcut, dismissShortcut
    }

    /// Shortcuts default when absent, as from a helper built before them.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try values.decode(String.self, forKey: .modelId)
        editorMode = try values.decode(String.self, forKey: .editorMode)
        networkIsolation = try values.decode(String.self, forKey: .networkIsolation)
        vocabulary = try values.decode([String].self, forKey: .vocabulary)
        recordShortcut = try values.decodeIfPresent(String.self, forKey: .recordShortcut) ?? Shortcut.defaultRecord
        cancelShortcut = try values.decodeIfPresent(String.self, forKey: .cancelShortcut) ?? Shortcut.defaultCancel
        copyShortcut = try values.decodeIfPresent(String.self, forKey: .copyShortcut) ?? Shortcut.defaultCopy
        dismissShortcut = try values.decodeIfPresent(String.self, forKey: .dismissShortcut) ?? Shortcut.defaultDismiss
    }
}

/// Everything set up from the popover: the model registry with one explicit
/// download at a time, and the settings file.
///
/// Nothing here downloads on its own. A download starts only from `confirm()`
/// after `request(_:)` showed what will be fetched, or from `retry()` on that
/// model's failure; both are the user's explicit action. Listing, choosing a
/// model and saving settings are offline. The backend owns the registry,
/// verification and the settings file (`hagig settings show|set`); Swift
/// parses no TOML and keeps no model list of its own.
@MainActor
public final class Preferences: ObservableObject {
    public enum Page: Equatable { case models, settings }
    public struct Download: Equatable {
        public let id: String
        /// `verify`, `download` or `convert` (the CLI's progress events).
        public var step: String
        public var received: Int64
        public var total: Int64
        public init(id: String, step: String, received: Int64, total: Int64) {
            self.id = id; self.step = step; self.received = received; self.total = total
        }
    }

    public struct Failure: Equatable {
        public let id: String
        public let code: String
        public init(id: String, code: String) { self.id = id; self.code = code }
    }

    public enum Listing: Equatable { case idle, loading, failed }

    /// The page shown in place of dictation, or nil for dictation.
    @Published public private(set) var page: Page?
    @Published public private(set) var models: [ModelEntry] = []
    /// The settings file's model, when it has a valid one.
    @Published public private(set) var configured: String?
    /// A stable code when a settings file exists but does not load.
    @Published public private(set) var configIssue: String?
    @Published public private(set) var listing = Listing.idle
    /// A model whose download awaits the user's explicit consent.
    @Published public private(set) var pending: String?
    @Published public private(set) var download: Download?
    @Published public private(set) var failure: Failure?
    /// A model being made the one in use.
    @Published public private(set) var choosing: String?
    /// The settings file, when it loads; nil when it is missing or broken.
    @Published public private(set) var settings: StoredSettings?
    @Published public private(set) var settingsPath: String?
    /// Whether a settings file exists, loaded or not.
    @Published public private(set) var settingsExist = false
    /// Changes each time settings are read, so an editor can start over.
    @Published public private(set) var settingsRevision = 0
    @Published public private(set) var saving = false
    /// The last save's stable failure code, or nil.
    @Published public private(set) var saveFailure: String?
    @Published public private(set) var saved = false
    /// Set by the shell when a global shortcut could not be registered.
    @Published public private(set) var shortcutIssue: String?
    /// The logs folder as the backend computes it (`settings show`'s
    /// `logs_dir`); nil until read, or from a helper built before logs.
    @Published public private(set) var logsDir: String?
    private let run: HelperRun?
    private let log: AppLog
    private var installTask: Task<Void, Never>?

    /// `run` is nil when there is no paired helper; the library then says so.
    /// `log` records saves and downloads; the shell passes the app's log.
    public init(run: HelperRun?, log: AppLog = .inert) { self.run = run; self.log = log }

    public var hasHelper: Bool { run != nil }

    public func open(_ page: Page) {
        self.page = page
        pending = nil
        saved = false
        saveFailure = nil
        refresh()
    }

    /// Back to dictation. A download keeps running; reopening shows it.
    public func close() {
        page = nil
        pending = nil
    }

    /// Read only the settings file (offline), for example at launch.
    public func loadSettings() {
        Task { await readSettings() }
    }

    /// A short line for Settings when registering a shortcut failed, or nil.
    public func report(shortcutIssue: String?) {
        self.shortcutIssue = shortcutIssue
    }

    /// Read the registry and the settings file again.
    public func refresh() {
        guard let run else { listing = .failed; return }
        listing = .loading
        Task {
            let output = Collected()
            let exit = await run(["model", "list", "--json"], nil) { output.append($0) }
            apply(listing: output.text, exit: exit)
            await readSettings()
        }
    }

    private func readSettings() async {
        guard let run else { return }
        struct Shown: Decodable {
            let path: String
            let exists: Bool
            let settings: StoredSettings?
            let logsDir: String?
        }
        let output = Collected()
        let exit = await run(["settings", "show"], nil) { output.append($0) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard exit.status == 0, let data = output.text.data(using: .utf8),
              let shown = try? decoder.decode(Shown.self, from: data) else { return }
        settingsPath = shown.path
        settingsExist = shown.exists
        // Published before the revision, so observers learn where to log first.
        if let logsDir = shown.logsDir, logsDir != self.logsDir { self.logsDir = logsDir }
        settings = shown.settings
        settingsRevision += 1
    }

    /// Write every setting through the backend, which validates them as the
    /// server will. `replace` overwrites a settings file that does not load;
    /// the view asks before passing it. An idle server restarts with them.
    public func save(_ values: StoredSettings, replace: Bool = false) {
        guard let run, !saving else { return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let input = try? encoder.encode(values) else { return }
        saving = true
        saved = false
        saveFailure = nil
        Task {
            let exit = await run(["settings", "set"] + (replace ? ["--replace"] : []), input) { _ in }
            saving = false
            if exit.status == 0 {
                saved = true
                log.record(.settingsSaved)
            } else {
                saveFailure = exit.error ?? "config_write_failed"
                log.record(.settingsSaveFailed, AppLogFields(code: saveFailure))
            }
            let output = Collected()
            let listed = await run(["model", "list", "--json"], nil) { output.append($0) }
            apply(listing: output.text, exit: listed)
            await readSettings()
        }
    }

    private func apply(listing text: String, exit: HelperExit) {
        struct Listed: Decodable {
            let configured: String?
            let configIssue: String?
            let models: [ModelEntry]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard exit.status == 0, let data = text.data(using: .utf8),
              let listed = try? decoder.decode(Listed.self, from: data) else {
            listing = .failed
            return
        }
        models = listed.models
        configured = listed.configured
        configIssue = listed.configIssue
        listing = .idle
    }

    /// Ask before downloading: the view shows what, from where and how much.
    public func request(_ id: String) {
        guard download == nil, let entry = models.first(where: { $0.id == id }),
              entry.supported, entry.installed != "installed" else { return }
        failure = nil
        pending = id
    }

    public func decline() { pending = nil }

    /// The user's explicit consent to the pending download.
    public func confirm() {
        guard let id = pending else { return }
        pending = nil
        install(id)
    }

    /// Try the failed download again: an explicit action on that model.
    public func retry() {
        guard let failure, download == nil else { return }
        install(failure.id)
    }

    public func cancelDownload() { installTask?.cancel() }

    private func install(_ id: String) {
        guard let run, download == nil,
              let entry = models.first(where: { $0.id == id }) else { return }
        failure = nil
        download = Download(id: id, step: "verify", received: 0, total: entry.downloadBytes)
        log.record(.modelDownloadStarted, AppLogFields(model: id))
        installTask = Task {
            var continuation: AsyncStream<String>.Continuation!
            let stream = AsyncStream<String> { continuation = $0 }
            let lines = continuation!
            async let exit = Self.running(run, ["model", "install", id, "--json"], into: lines)
            var done = false
            for await line in stream {
                done = advance(id: id, line: line) || done
            }
            let ended = await exit
            installTask = nil
            download = nil
            if Task.isCancelled {
                failure = Failure(id: id, code: "interrupted")
            } else if ended.status != 0 || !done {
                failure = Failure(id: id, code: ended.error ?? "install_failed")
            } else {
                log.record(.modelDownloadFinished, AppLogFields(model: id))
                await finished(id)
            }
            if let failure = self.failure {
                log.record(.modelDownloadFailed, AppLogFields(code: failure.code, model: id))
            }
        }
    }

    private nonisolated static func running(_ run: HelperRun, _ arguments: [String],
                                            into lines: AsyncStream<String>.Continuation) async -> HelperExit {
        let exit = await run(arguments, nil) { lines.yield($0) }
        lines.finish()
        return exit
    }

    /// One `--json` progress line; true for the final `done`.
    private func advance(id: String, line: String) -> Bool {
        struct Event: Decodable {
            let event: String
            let received: Int64?
            let total: Int64?
        }
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data),
              download?.id == id else { return false }
        if event.event == "done" { return true }
        download?.step = event.event
        if let received = event.received { download?.received = received }
        if let total = event.total, total > 0 { download?.total = total }
        return false
    }

    /// After a download, list again; with no model chosen yet, choose this one,
    /// so a first run needs no hand-written settings file.
    private func finished(_ id: String) async {
        let output = Collected()
        guard let run else { return }
        let exit = await run(["model", "list", "--json"], nil) { output.append($0) }
        apply(listing: output.text, exit: exit)
        await readSettings()
        if configured == nil, configIssue == nil { use(id) }
    }

    /// Make an installed model the one in use, keeping every other setting.
    /// Offline; writes a first settings file when there is none.
    public func use(_ id: String) {
        guard let run, choosing == nil, let input = try? JSONEncoder().encode(["model_id": id]) else { return }
        failure = nil
        choosing = id
        Task {
            let exit = await run(["settings", "set"], input) { _ in }
            choosing = nil
            if exit.status != 0 { failure = Failure(id: id, code: exit.error ?? "config_write_failed") }
            let output = Collected()
            let listed = await run(["model", "list", "--json"], nil) { output.append($0) }
            apply(listing: output.text, exit: listed)
            await readSettings()
        }
    }

    /// Fixed states for the render harness; never used by the shell.
    public func preview(page: Page, models: [ModelEntry], configured: String?, pending: String? = nil,
                        download: Download? = nil, failure: Failure? = nil,
                        settings: StoredSettings? = nil, settingsPath: String? = nil, logsDir: String? = nil) {
        self.page = page
        self.logsDir = logsDir
        listing = .idle
        self.settings = settings
        self.settingsPath = settingsPath
        settingsExist = settings != nil
        settingsRevision += 1
        self.models = models
        self.configured = configured
        self.pending = pending
        self.download = download
        self.failure = failure
    }

    /// What a failure code means for the user. Codes come from the CLI.
    public static func explain(_ code: String) -> String {
        let base = code.split(separator: ":").first.map(String.init) ?? code
        switch base {
        case "interrupted": return "Download cancelled. Nothing was changed."
        case "download_failed": return "The download did not finish. Check the connection, then retry."
        case "download_hash_mismatch", "download_size_mismatch":
            return "A file did not match its pinned checksum and was discarded."
        case "download_origin_refused", "download_redirect_refused":
            return "The download was refused: it left the expected servers."
        case "install_in_progress": return "Another install is running. Wait for it, then retry."
        case "conversion_failed", "conversion_output_invalid":
            return "Converting the model on this Mac failed."
        case "engine_not_installed", "model_unsupported_on_platform":
            return "This model cannot run on this Mac."
        case "model_dir_unsafe": return "The models folder has unsafe permissions."
        case "config_unloadable":
            return "The settings file could not be read. Open Settings to replace it."
        case "model_missing": return "Download this model first."
        case "busy": return "A dictation is in progress. Try again when it ends."
        default: return "The install did not complete."
        }
    }

    // MARK: The paired helper

    /// Runs the bundle's own helper with the app's environment.
    public nonisolated static func helper(_ executable: URL,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperRun {
        { arguments, input, line in
            let child = Child(executable: executable, arguments: arguments, input: input, environment: environment)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: child.run(line: line)) }
                }
            } onCancel: { child.interrupt() }
        }
    }
}

/// Lines collected from a short command.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

/// One helper process. Interrupting before it starts means it never starts.
private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var started = false
    private var cancelled = false
    private static let stderrBytes = 1_024

    private let input: Data?

    init(executable: URL, arguments: [String], input: Data?, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        self.input = input
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if started, process.isRunning { process.interrupt() }
    }

    /// Blocking: run, stream stdout lines, wait. Called off the main thread.
    func run(line: @escaping @Sendable (String) -> Void) -> HelperExit {
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Settings travel on stdin, never in arguments a process list shows.
        let feed = input.map { _ in Pipe() }
        process.standardInput = feed ?? FileHandle.nullDevice
        lock.lock()
        guard !cancelled, FileManager.default.isExecutableFile(atPath: process.executableURL?.path ?? ""),
              (try? process.run()) != nil else {
            lock.unlock()
            return HelperExit(status: -1, error: cancelled ? "interrupted" : nil)
        }
        started = true
        lock.unlock()
        if let feed, let input {
            // Small (settings only), written then closed so the helper sees EOF.
            let writer = feed.fileHandleForWriting
            // A helper that exits early must not take the app down with SIGPIPE.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        // stderr is drained alongside, so a chatty helper cannot block on it.
        var kept = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            kept = data.prefix(Self.stderrBytes + 1)
            drained.leave()
        }
        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                if let text = String(data: buffer[buffer.startIndex..<end], encoding: .utf8) { line(text) }
                buffer.removeSubrange(buffer.startIndex...end)
            }
            // No line the CLI prints is this long; never grow without bound.
            if buffer.count > 1 << 20 { buffer.removeAll() }
        }
        process.waitUntilExit()
        drained.wait()
        let status = process.terminationReason == .exit ? process.terminationStatus : -1
        return HelperExit(status: status, error: Self.firstLine(kept))
    }

    private static func firstLine(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= stderrBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard lines.count == 1, let first = lines.first, first.count <= 400,
              !first.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return String(first)
    }
}
