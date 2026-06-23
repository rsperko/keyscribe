import SwiftUI
import KeyScribeKit

struct SpeechModelsView: View {
    @ObservedObject var model: SpeechModelsModel

    var body: some View {
        Form {
            Section { activeBanner }
            Section {
                Text("KeyScribe runs one speech engine at a time, entirely on this Mac, before any AI step. Pick it here.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.rows) { row in
                    EngineRow(row: row, model: model)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Delete this speech model?",
            isPresented: Binding(
                get: { model.pendingDeleteId != nil },
                set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text(model.pendingDeleteLeavesNoEngine
                ? "This is your only usable engine. Deleting it leaves no engine to dictate with."
                : "This is the active engine. Deleting it will switch you to another installed engine.")
        }
    }

    private var activeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("KeyScribe uses \(model.activeName)").font(.headline)
                Text("Used for every dictation, before any AI step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeechBadge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(prominent ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

private struct EngineRow: View {
    let row: SpeechModelsModel.Row
    @ObservedObject var model: SpeechModelsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.info.displayName).font(.headline)
                        if row.info.isDefaultEnglish { SpeechBadge(text: "Recommended", prominent: true) }
                        SpeechBadge(text: row.info.languageCount <= 1 ? "English" : "Multilingual")
                        SpeechBadge(text: sizeClass)
                        if !row.info.supportsRecognitionBias {
                            SpeechBadge(text: "No dictionary bias")
                                .help("Runs fully on-device, but can't bias recognition toward your dictionary terms.")
                        }
                        Spacer(minLength: 0)
                        if row.isActive {
                            Label("In use", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.tint).labelStyle(.titleAndIcon)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.info.summary).font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(languageScope).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if let frac = row.downloadFraction {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: frac).controlSize(.small)
                    HStack {
                        Text(row.downloadPhase ?? "Downloading…")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((frac * 100).rounded()))%")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if row.verifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing model…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if row.verificationFailed {
                Label("Failed its self-test", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if row.testPassed {
                Label("Passed its self-test", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let err = row.errorText {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                statusFooter
                Spacer()
                actions
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if row.isActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .offset(x: -8)
            }
        }
    }

    private var icon: String {
        switch row.info.kind {
        case .apple: "apple.logo"
        default: "waveform"
        }
    }

    private var sizeClass: String {
        if row.info.systemManaged { return "Standard" }
        return row.info.approxDownloadBytes <= 500_000_000 ? "Compact" : "Large"
    }

    private var languageScope: String {
        row.info.languageCount <= 1 ? "English" : "\(row.info.languageCount) languages"
    }

    @ViewBuilder private var statusFooter: some View {
        if let status = installStatus {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        } else if !row.info.systemManaged, !row.isUsable, row.downloadFraction == nil {
            Text("~\(ByteCountFormatter.string(fromByteCount: row.info.approxDownloadBytes, countStyle: .file)) download")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var installStatus: String? {
        guard row.downloadFraction == nil, !row.verifying else { return nil }
        if row.info.systemManaged {
            return row.isUsable ? "Available · managed by macOS" : nil
        }
        guard row.isUsable else { return nil }
        if let bytes = row.installedBytes {
            return "Installed · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        return "Installed"
    }

    @ViewBuilder private var actions: some View {
        if row.downloadFraction != nil {
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        } else if row.verifying {
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        } else if row.verificationFailed {
            if row.info.systemManaged {
                Button("Test Again") { model.test(row.id) }
            } else {
                Button("Reinstall") { model.reinstall(row.id) }
            }
        } else if row.isUsable {
            if !row.isActive {
                Button("Use This Engine") { model.select(row.id) }
            }
            Button("Test") { model.test(row.id) }
                .help("Runs a quick on-device self-test to confirm this model can transcribe.")
            if !row.info.systemManaged {
                Button("Delete", role: .destructive) { model.requestDelete(row.id) }
            }
        } else {
            Button("Download") { model.startDownload(row.id) }
        }
    }
}
