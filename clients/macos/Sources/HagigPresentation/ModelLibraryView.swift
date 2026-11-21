import SwiftUI

/// The registry inside the popover: every model the backend lists, whether it
/// is installed or in use, and one explicit, consented download at a time.
/// Stock controls and system colours only, like `HagigView`.
@MainActor
struct ModelLibraryView: View {
    @ObservedObject var library: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(library.pending == nil ? "Speech models" : "Download a model?")
                .font(.system(size: 21, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
            if let id = library.pending, let entry = library.models.first(where: { $0.id == id }) {
                consent(entry)
            } else {
                list
            }
        }
    }

    @ViewBuilder private var list: some View {
        Text("Models run on this Mac. Hagig downloads one only when you choose Download.")
            .foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        if !library.hasHelper {
            Text("The paired service is not part of this build, so models cannot be listed.")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if library.listing == .failed && library.models.isEmpty {
            Text("The model list could not be read.").foregroundStyle(.orange)
            Button("Try again") { library.refresh() }
        } else if library.listing == .loading && library.models.isEmpty {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Reading the model list").font(.system(size: 12, weight: .medium))
            }
        }
        VStack(spacing: 0) {
            ForEach(Array(library.models.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                row(entry)
            }
        }
        .padding(.horizontal, 12)
        .background(HagigView.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        if library.configIssue != nil {
            Text("The settings file could not be read. Open Settings to replace it.")
                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button { library.open(.settings) } label: { Text("Settings").frame(width: 92) }
                .controlSize(.large).buttonStyle(.bordered)
            Button { library.close() } label: { Text("Done").frame(maxWidth: .infinity) }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold))
                    Text("\(Self.size(entry.downloadBytes)) · \(entry.publisher) · \(entry.license)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing(entry)
            }
            if let download = library.download, download.id == entry.id {
                progress(download)
            } else if let failure = library.failure, failure.id == entry.id {
                HStack(alignment: .firstTextBaseline) {
                    Text(Preferences.explain(failure.code)).font(.system(size: 11))
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if entry.installed != "installed" {
                        Button("Retry") { library.retry() }.controlSize(.small)
                            .disabled(library.download != nil)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("model-\(entry.id)")
    }

    @ViewBuilder private func trailing(_ entry: ModelEntry) -> some View {
        if library.download?.id == entry.id {
            Button("Cancel") { library.cancelDownload() }.controlSize(.small)
                .accessibilityLabel("Cancel download of \(entry.name)")
        } else if entry.installed == "installed" {
            if entry.id == library.configured {
                Label("In use", systemImage: "checkmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(library.choosing == entry.id ? "Switching…" : "Use") { library.use(entry.id) }
                    .controlSize(.small).disabled(library.choosing != nil)
                    .accessibilityLabel("Use \(entry.name)")
            }
        } else if library.failure?.id == entry.id {
            EmptyView() // Retry below is the action.
        } else if !entry.supported {
            Text("Not on this Mac").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            Button(entry.installed == "invalid" ? "Reinstall…" : "Download…") { library.request(entry.id) }
                .controlSize(.small).disabled(library.download != nil)
                .accessibilityLabel("Download \(entry.name)")
        }
    }

    private func progress(_ download: Preferences.Download) -> some View {
        let total = max(download.total, 1)
        let fraction = min(Double(download.received) / Double(total), 1)
        let status: String
        switch download.step {
        case "convert": status = "Converting on this Mac…"
        case "verify": status = "Checking…"
        default: status = "\(Self.size(download.received)) of \(Self.size(download.total))"
        }
        return VStack(alignment: .leading, spacing: 4) {
            if download.step == "convert" {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
            Text(status).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading: \(status)")
    }

    /// What the user agrees to: the model, its source, licence and size, and
    /// that this is the network step. Declining changes nothing.
    @ViewBuilder private func consent(_ entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.system(size: 13, weight: .semibold))
            Text("About \(Self.size(entry.downloadBytes)) from huggingface.co/\(entry.repository)")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("\(entry.publisher) · \(entry.license) licence").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HagigView.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        Text(entry.engine == "mlx-whisper"
             ? "Hagig fetches the pinned files and Apple's pinned converter from GitHub, checks every checksum, then converts the model on this Mac, which takes a few minutes. Transcription never uses the network."
             : "Hagig fetches the pinned files and checks every checksum. This download is the only time Hagig uses the network; transcription stays on this Mac.")
            .foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button { library.decline() } label: { Text("Not now").frame(width: 92) }
                .controlSize(.large).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            Button { library.confirm() } label: {
                Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
