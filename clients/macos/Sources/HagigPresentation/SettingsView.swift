import SwiftUI

/// Every setting in the settings file, edited in the popover and written by
/// the backend (`hagig settings set`), which validates them as the server
/// will. Stock controls and system colours only, like `HagigView`.
@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var draft: Draft

    /// Vocabulary is edited as one term per line.
    struct Draft: Equatable {
        var modelID: String
        var editorMode: String
        var isolated: Bool
        var vocabulary: String

        init(_ stored: StoredSettings?, fallbackModel: String?) {
            modelID = stored?.modelId ?? fallbackModel ?? ""
            editorMode = stored?.editorMode ?? "standard"
            isolated = stored?.networkIsolation != "disabled"
            vocabulary = (stored?.vocabulary ?? []).joined(separator: "\n")
        }

        var stored: StoredSettings {
            let terms = vocabulary.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return StoredSettings(modelId: modelID, editorMode: editorMode,
                                  networkIsolation: isolated ? "required" : "disabled", vocabulary: terms)
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
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
            HStack(spacing: 8) {
                Button { preferences.close() } label: { Text("Done").frame(width: 92) }
                    .controlSize(.large).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button { preferences.save(draft.stored, replace: replacing) } label: {
                    Text(replacing ? "Replace and save" : "Save").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft.modelID.isEmpty || preferences.saving || !preferences.hasHelper)
            }
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
