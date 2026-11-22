import SwiftUI

/// Open at login, as explicit effects. The shell supplies `SMAppService.mainApp`;
/// the render harness and tests supply `inert`, which changes nothing.
public struct LoginItem {
    public enum Status: Equatable { case enabled, disabled, requiresApproval }
    public let status: () -> Status
    /// Register (true) or unregister (false); false when that failed.
    public let set: (Bool) -> Bool
    /// System Settings › Login Items, for approval.
    public let openSettings: () -> Void

    public init(status: @escaping () -> Status, set: @escaping (Bool) -> Bool,
                openSettings: @escaping () -> Void) {
        self.status = status; self.set = set; self.openSettings = openSettings
    }

    public static var inert: LoginItem {
        LoginItem(status: { .disabled }, set: { _ in false }, openSettings: {})
    }
}

/// Every setting in the settings file, edited in the popover and written by
/// the backend (`hagig settings set`), which validates them as the server
/// will. Stock controls and system colours only, like `HagigView`.
@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    /// Nil hides Open at login.
    let loginItem: LoginItem?
    /// Shows the logs folder in Finder; nil hides the button.
    let revealLogs: ((String) -> Void)?
    @State private var draft: Draft
    @State private var loginStatus = LoginItem.Status.disabled
    @State private var loginFailed = false

    /// Vocabulary is edited as one term per line.
    struct Draft: Equatable {
        var modelID: String
        var editorMode: String
        var isolated: Bool
        var vocabulary: String
        var recordShortcut: String
        var cancelShortcut: String
        var copyShortcut: String
        var dismissShortcut: String

        init(_ stored: StoredSettings?, fallbackModel: String?) {
            modelID = stored?.modelId ?? fallbackModel ?? ""
            editorMode = stored?.editorMode ?? "standard"
            isolated = stored?.networkIsolation != "disabled"
            vocabulary = (stored?.vocabulary ?? []).joined(separator: "\n")
            recordShortcut = stored?.recordShortcut ?? Shortcut.defaultRecord
            cancelShortcut = stored?.cancelShortcut ?? Shortcut.defaultCancel
            copyShortcut = stored?.copyShortcut ?? Shortcut.defaultCopy
            dismissShortcut = stored?.dismissShortcut ?? Shortcut.defaultDismiss
        }

        var stored: StoredSettings {
            let terms = vocabulary.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return StoredSettings(modelId: modelID, editorMode: editorMode,
                                  networkIsolation: isolated ? "required" : "disabled", vocabulary: terms,
                                  recordShortcut: recordShortcut, cancelShortcut: cancelShortcut,
                                  copyShortcut: copyShortcut, dismissShortcut: dismissShortcut)
        }

        /// All four parse and differ pairwise, as the backend requires.
        var shortcutsValid: Bool {
            let parsed = [recordShortcut, cancelShortcut, copyShortcut, dismissShortcut].compactMap(Shortcut.init)
            return parsed.count == 4 && Set(parsed).count == 4
        }

        /// Every value parses, but two are the same chord.
        var shortcutsConflict: Bool {
            let parsed = [recordShortcut, cancelShortcut, copyShortcut, dismissShortcut].compactMap(Shortcut.init)
            return parsed.count == 4 && Set(parsed).count < 4
        }
    }

    init(preferences: Preferences, loginItem: LoginItem? = nil, revealLogs: ((String) -> Void)? = nil) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.revealLogs = revealLogs
        _draft = State(initialValue: Draft(preferences.settings, fallbackModel: Self.firstInstalled(preferences)))
    }

    private static func firstInstalled(_ preferences: Preferences) -> String? {
        preferences.models.first { $0.installed == "installed" }?.id
    }

    /// The file exists but does not load: saving replaces it, and says so.
    private var replacing: Bool { preferences.settingsExist && preferences.settings == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.system(size: 21, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
            model
            field("Editor") {
                Picker("Editor", selection: $draft.editorMode) {
                    Text("Standard").tag("standard")
                    Text("Vim").tag("vim")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            field("Vocabulary, one term per line") {
                TextEditor(text: $draft.vocabulary)
                    .font(.system(size: 12))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(HagigView.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Vocabulary, one term per line")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Block the transcription worker's network", isOn: $draft.isolated)
                    .toggleStyle(.checkbox)
                if !draft.isolated {
                    Text("The worker then runs without the macOS network sandbox. Hagig still never uploads or downloads while transcribing.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                shortcuts
                if let loginItem { login(loginItem) }
            }
            if replacing {
                Text("The settings file could not be read. Saving replaces it with these settings.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            status
            if let path = preferences.settingsPath {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle)
                    .accessibilityLabel("Settings file: \(path)")
            }
            if let logs = preferences.logsDir { logsRow(logs) }
            HStack(spacing: 8) {
                Button { preferences.close() } label: { Text("Done").frame(width: 92) }
                    .controlSize(.large).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button { preferences.save(draft.stored, replace: replacing) } label: {
                    Text(replacing ? "Replace and save" : "Save").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft.modelID.isEmpty || !draft.shortcutsValid || preferences.saving || !preferences.hasHelper)
            }
        }
        .onAppear {
            // The system's own answer each time the page shows.
            if let loginItem { loginStatus = loginItem.status() }
        }
        .onChange(of: preferences.settingsRevision) { _ in
            draft = Draft(preferences.settings, fallbackModel: draft.modelID.isEmpty
                          ? Self.firstInstalled(preferences) : draft.modelID)
        }
    }

    @ViewBuilder private var model: some View {
        let installed = preferences.models.filter { $0.installed == "installed" }
        field("Model") {
            if installed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No model is downloaded yet.").foregroundStyle(.secondary)
                    Button("Download a model…") { preferences.open(.models) }
                }
            } else {
                HStack {
                    Picker("Model", selection: $draft.modelID) {
                        ForEach(installed) { Text($0.name).tag($0.id) }
                        if !installed.contains(where: { $0.id == draft.modelID }) {
                            Text(draft.modelID.isEmpty ? "Choose…" : modelDisplayName(draft.modelID) + " (not downloaded)")
                                .tag(draft.modelID)
                        }
                    }
                    .labelsHidden()
                    Button("Models…") { preferences.open(.models) }.controlSize(.small)
                }
            }
        }
    }

    /// Typed in the config syntax, with the parsed chord beside each. Record and
    /// Cancel work from any app; Copy and Dismiss only in review.
    private var shortcuts: some View {
        field("Shortcuts") {
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow("Record", placeholder: Shortcut.defaultRecord, text: $draft.recordShortcut)
                shortcutRow("Cancel", placeholder: Shortcut.defaultCancel, text: $draft.cancelShortcut)
                shortcutRow("Copy", placeholder: Shortcut.defaultCopy, text: $draft.copyShortcut,
                            accessibility: "Copy and close")
                shortcutRow("Dismiss", placeholder: Shortcut.defaultDismiss, text: $draft.dismissShortcut)
                if draft.shortcutsConflict {
                    Text("Each shortcut needs a different chord.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("Hold Record to talk, or tap it to start and again to stop. Copy and Dismiss work only while a transcript is in review; without cmd, the editor (Vim keys) may take them. Modifiers cmd, ctrl, option, shift; keys a–z, 0–9, f1–f12, space, return, tab, escape, by US key position.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let issue = preferences.shortcutIssue {
                    Text(issue).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutRow(_ label: String, placeholder: String, text: Binding<String>,
                             accessibility: String? = nil) -> some View {
        let parsed = Shortcut(text.wrappedValue)
        let name = accessibility ?? label
        return HStack(spacing: 8) {
            Text(label).frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel("\(name) shortcut")
            Text(parsed?.display ?? "Not valid")
                .font(.system(size: 12, weight: parsed == nil ? .regular : .medium))
                .foregroundStyle(parsed == nil ? Color.orange : Color.secondary)
                .frame(width: 64, alignment: .leading)
                .accessibilityLabel(parsed.map { "\(name) shortcut is \($0.display)" } ?? "\(name) shortcut is not valid")
        }
    }

    /// Where `app.log` and `server.log` are; content-free (TDD §10).
    private func logsRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Text("Logs").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Logs folder: \(path)")
            Spacer(minLength: 0)
            if let revealLogs {
                Button("Show in Finder") { revealLogs(path) }.controlSize(.small)
            }
        }
    }

    /// Applies at once, outside the Save draft.
    private func login(_ item: LoginItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(
                get: { loginStatus != .disabled },
                set: { on in
                    loginFailed = !item.set(on)
                    loginStatus = item.status()
                }))
                .toggleStyle(.checkbox)
            if loginStatus == .requiresApproval {
                HStack(spacing: 8) {
                    Text("Allow Hagig in Login Items to finish.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Open Login Items") { item.openSettings() }.controlSize(.small)
                }
            }
            if loginFailed {
                Text("Open at login could not be changed.").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if preferences.saving {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Saving…").font(.system(size: 12, weight: .medium))
            }
        } else if let failure = preferences.saveFailure {
            Text(Self.explain(failure)).font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if preferences.saved {
            Label("Saved. The next recording uses these settings.", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    /// Codes from `settings set`; validation names a field, never a value.
    static func explain(_ code: String) -> String {
        if code.hasPrefix("config_invalid") {
            if code.contains("vocabulary") {
                return "A vocabulary term is not allowed (at most 200 terms of 100 characters, no control characters)."
            }
            return "These settings are not valid: \(code.dropFirst("config_invalid: ".count))."
        }
        return Preferences.explain(code)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
