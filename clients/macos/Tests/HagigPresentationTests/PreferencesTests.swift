import XCTest
@testable import HagigPresentation

/// A scripted paired helper: records every command and answers from a table.
private final class ScriptedHelper: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    private(set) var inputs: [String] = []
    var listing: String
    var shown = #"{"path":"/x/config.toml","exists":false,"issue":null,"settings":null}"#
    var install: (lines: [String], exit: HelperExit) = ([], HelperExit(status: 0, error: nil))
    var set = HelperExit(status: 0, error: nil)
    /// Holds `model install` until released, to observe progress and cancel.
    var gate: CheckedContinuation<Void, Never>?
    var holdInstall = false

    init(installed: Set<String> = []) {
        listing = Self.list(installed: installed, configured: nil)
    }

    static func list(installed: Set<String>, configured: String?) -> String {
        let models = ["qwen3-asr-0.6b", "whisper-large-v3-turbo"].map { id in
            #"{"id":"\#(id)","name":"N \#(id)","engine":"e","publisher":"P","repository":"o/r","license":"L","download_bytes":1000,"supported":true,"installed":"\#(installed.contains(id) ? "installed" : "missing")"}"#
        }
        let chosen = configured.map { "\"\($0)\"" } ?? "null"
        return #"{"configured":\#(chosen),"config_issue":null,"models":[\#(models.joined(separator: ","))]}"#
    }

    var commands: [String] { lock.lock(); defer { lock.unlock() }; return calls.map { $0.prefix(2).joined(separator: " ") } }

    var run: HelperRun {
        { [self] arguments, input, line in
            lock.withLock {
                calls.append(arguments)
                if let input { inputs.append(String(decoding: input, as: UTF8.self)) }
            }
            switch Array(arguments.prefix(2)) {
            case ["model", "list"]: line(listing); return HelperExit(status: 0, error: nil)
            case ["settings", "show"]: line(shown); return HelperExit(status: 0, error: nil)
            case ["settings", "set"]: return set
            case ["model", "install"]:
                for item in install.lines { line(item) }
                if holdInstall {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { self.gate = $0 }
                    } onCancel: { [self] in self.gate?.resume(); self.gate = nil }
                    if Task.isCancelled { return HelperExit(status: 130, error: "interrupted") }
                }
                return install.exit
            default: return HelperExit(status: 2, error: "unexpected")
            }
        }
    }
}

@MainActor
final class PreferencesTests: XCTestCase {
    private func settle(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testListingNeverDownloadsAndRequestAloneDownloadsNothing() async {
        let helper = ScriptedHelper()
        let preferences = Preferences(run: helper.run)
        preferences.open(.models)
        await settle { preferences.models.count == 2 && preferences.settingsRevision > 0 }
        preferences.request("qwen3-asr-0.6b")
        XCTAssertEqual(preferences.pending, "qwen3-asr-0.6b")
        preferences.decline()
        XCTAssertNil(preferences.pending)
        // Without confirm, nothing ran but reads.
        XCTAssertEqual(Set(helper.commands), ["model list", "settings show"])
        XCTAssertNil(preferences.download)
    }

    func testConfirmedDownloadShowsProgressThenChoosesTheModelWhenNoneIsSet() async {
        let helper = ScriptedHelper()
        helper.install = ([#"{"event":"download","file":"a","received":250,"total":1000}"#,
                           #"{"event":"done","result":"installed"}"#], HelperExit(status: 0, error: nil))
        helper.holdInstall = true
        let preferences = Preferences(run: helper.run)
        preferences.open(.models)
        await settle { preferences.models.count == 2 }
        preferences.request("qwen3-asr-0.6b")
        preferences.confirm()
        await settle { preferences.download?.received == 250 }
        XCTAssertEqual(preferences.download?.total, 1000)
        helper.listing = ScriptedHelper.list(installed: ["qwen3-asr-0.6b"], configured: nil)
        helper.gate?.resume()
        await settle { helper.inputs.count == 1 && preferences.choosing == nil && preferences.download == nil }
        XCTAssertEqual(helper.calls.first { $0.starts(with: ["model", "install"]) },
                       ["model", "install", "qwen3-asr-0.6b", "--json"])
        // First run: the downloaded model becomes the one in use, through stdin.
        XCTAssertEqual(helper.inputs, [#"{"model_id":"qwen3-asr-0.6b"}"#])
        XCTAssertNil(preferences.failure)
    }

    func testFailureThenRetryRunsTheSameInstall() async {
        let helper = ScriptedHelper()
        helper.install = ([], HelperExit(status: 1, error: "download_failed: model.safetensors"))
        let preferences = Preferences(run: helper.run)
        preferences.open(.models)
        await settle { preferences.models.count == 2 }
        preferences.request("whisper-large-v3-turbo")
        preferences.confirm()
        await settle { preferences.failure != nil }
        XCTAssertEqual(preferences.failure, .init(id: "whisper-large-v3-turbo", code: "download_failed: model.safetensors"))
        XCTAssertEqual(Preferences.explain(preferences.failure!.code),
                       "The download did not finish. Check the connection, then retry.")
        helper.install = ([#"{"event":"done","result":"installed"}"#], HelperExit(status: 0, error: nil))
        preferences.retry()
        await settle { preferences.failure == nil && preferences.download == nil && helper.inputs.count == 1 }
        XCTAssertEqual(helper.calls.filter { $0.starts(with: ["model", "install"]) }.count, 2)
        // A zero exit without the final `done` line is never success.
        helper.install = ([], HelperExit(status: 0, error: nil))
        preferences.request("whisper-large-v3-turbo")
        preferences.confirm()
        await settle { preferences.failure?.code == "install_failed" }
    }

    func testCancelInterruptsAndReportsNothingChanged() async {
        let helper = ScriptedHelper()
        helper.holdInstall = true
        let preferences = Preferences(run: helper.run)
        preferences.open(.models)
        await settle { preferences.models.count == 2 }
        preferences.request("qwen3-asr-0.6b")
        preferences.confirm()
        await settle { helper.gate != nil }
        preferences.cancelDownload()
        await settle { preferences.failure != nil }
        XCTAssertEqual(preferences.failure?.code, "interrupted")
        XCTAssertNil(preferences.download)
        XCTAssertTrue(helper.inputs.isEmpty) // nothing chosen after a cancel
    }

    func testSaveSendsEverySettingOnStdinAndReportsFailures() async {
        let helper = ScriptedHelper(installed: ["qwen3-asr-0.6b"])
        let preferences = Preferences(run: helper.run)
        preferences.open(.settings)
        await settle { preferences.settingsRevision > 0 }
        preferences.save(StoredSettings(modelId: "qwen3-asr-0.6b", editorMode: "vim",
                                        networkIsolation: "required", vocabulary: ["Hagig", "日本語"]))
        await settle { preferences.saved }
        let object = try? JSONSerialization.jsonObject(with: Data(helper.inputs[0].utf8)) as? [String: Any]
        XCTAssertEqual(object.map { Set($0.keys) }, ["model_id", "editor_mode", "network_isolation", "vocabulary",
                                                     "record_shortcut", "cancel_shortcut",
                                                     "copy_shortcut", "dismiss_shortcut"])
        XCTAssertEqual(object?["record_shortcut"] as? String, "ctrl+option+space")
        XCTAssertEqual(object?["copy_shortcut"] as? String, "cmd+shift+c")
        XCTAssertEqual(object?["dismiss_shortcut"] as? String, "cmd+shift+d")
        XCTAssertEqual(object?["editor_mode"] as? String, "vim")
        XCTAssertEqual(object?["vocabulary"] as? [String], ["Hagig", "日本語"])
        XCTAssertFalse(helper.calls.contains { $0.contains("Hagig") }, "vocabulary never in arguments")
        helper.set = HelperExit(status: 1, error: "config_unloadable: fix or replace /x/config.toml")
        preferences.save(StoredSettings(modelId: "qwen3-asr-0.6b"))
        await settle { preferences.saveFailure != nil }
        XCTAssertFalse(preferences.saved)
        preferences.save(StoredSettings(modelId: "qwen3-asr-0.6b"), replace: true)
        await settle { helper.calls.contains(["settings", "set", "--replace"]) }
    }

    func testSettingsShowDecodesShortcutsAndDefaultsThemWhenAbsent() async {
        let helper = ScriptedHelper()
        helper.shown = #"{"path":"/x/config.toml","exists":true,"issue":null,"settings":{"model_id":"qwen3-asr-0.6b","editor_mode":"standard","network_isolation":"required","vocabulary":[],"record_shortcut":"cmd+shift+space","cancel_shortcut":"cmd+shift+escape"}}"#
        let preferences = Preferences(run: helper.run)
        preferences.loadSettings()
        await settle { preferences.settings != nil }
        XCTAssertEqual(preferences.settings?.recordShortcut, "cmd+shift+space")
        XCTAssertEqual(preferences.settings?.cancelShortcut, "cmd+shift+escape")
        // Only the offline settings read ran.
        XCTAssertEqual(helper.commands, ["settings show"])
        helper.shown = #"{"path":"/x/config.toml","exists":true,"issue":null,"settings":{"model_id":"qwen3-asr-0.6b","editor_mode":"standard","network_isolation":"required","vocabulary":[]}}"#
        let revision = preferences.settingsRevision
        preferences.loadSettings()
        await settle { preferences.settingsRevision > revision }
        XCTAssertEqual(preferences.settings?.recordShortcut, Shortcut.defaultRecord)
        XCTAssertEqual(preferences.settings?.cancelShortcut, Shortcut.defaultCancel)
        XCTAssertEqual(preferences.settings?.copyShortcut, Shortcut.defaultCopy)
        XCTAssertEqual(preferences.settings?.dismissShortcut, Shortcut.defaultDismiss)
    }

    func testSettingsShowDecodesReviewShortcutsAndTheLogsFolder() async {
        let helper = ScriptedHelper()
        XCTAssertNil(Preferences(run: helper.run).logsDir)
        helper.shown = #"{"path":"/x/config.toml","exists":true,"issue":null,"settings":{"model_id":"qwen3-asr-0.6b","editor_mode":"standard","network_isolation":"required","vocabulary":[],"record_shortcut":"ctrl+option+space","cancel_shortcut":"ctrl+option+escape","copy_shortcut":"option+return","dismiss_shortcut":"ctrl+f5"},"logs_dir":"/x/state/hagig/logs"}"#
        let preferences = Preferences(run: helper.run)
        preferences.loadSettings()
        await settle { preferences.settings != nil }
        XCTAssertEqual(preferences.settings?.copyShortcut, "option+return")
        XCTAssertEqual(preferences.settings?.dismissShortcut, "ctrl+f5")
        XCTAssertEqual(preferences.logsDir, "/x/state/hagig/logs")
        // A settings file that does not load still reports where logs go.
        helper.shown = #"{"path":"/x/config.toml","exists":true,"issue":"config_syntax","settings":null,"logs_dir":"/y/logs"}"#
        let revision = preferences.settingsRevision
        preferences.loadSettings()
        await settle { preferences.settingsRevision > revision }
        XCTAssertNil(preferences.settings)
        XCTAssertEqual(preferences.logsDir, "/y/logs")
    }

    func testSettingsWriteAllFourShortcutsAsFlatKeys() async throws {
        let helper = ScriptedHelper()
        let preferences = Preferences(run: helper.run)
        preferences.save(StoredSettings(modelId: "qwen3-asr-0.6b", copyShortcut: "option+return", dismissShortcut: "ctrl+f5"))
        await settle { !helper.inputs.isEmpty }
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(helper.inputs[0].utf8)) as? [String: Any])
        XCTAssertEqual(sent["copy_shortcut"] as? String, "option+return")
        XCTAssertEqual(sent["dismiss_shortcut"] as? String, "ctrl+f5")
        XCTAssertEqual(sent["record_shortcut"] as? String, Shortcut.defaultRecord)
    }

    func testWithoutAHelperNothingRuns() {
        let preferences = Preferences(run: nil)
        preferences.open(.models)
        XCTAssertEqual(preferences.listing, .failed)
        XCTAssertFalse(preferences.hasHelper)
    }
}
