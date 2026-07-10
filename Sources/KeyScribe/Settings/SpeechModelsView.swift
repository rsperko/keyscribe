import SwiftUI
import KeyScribeKit

struct SpeechModelsView: View {
    @ObservedObject var model: SpeechModelsModel

    var body: some View {
        Form {
            Section { activeBanner }
            Section {
                Text("\(Branding.appName) runs one speech model at a time, entirely on this Mac, before any AI step. Pick it here.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.rows) { row in
                    EngineRow(row: row, model: model)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.Speech.list)
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
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.deleteConfirmConfirm)
            Button("Cancel", role: .cancel) { model.cancelDelete() }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.deleteConfirmCancel)
        } message: {
            Text(model.pendingDeleteLeavesNoEngine
                ? "This is your only usable model. Deleting it leaves no model to dictate with."
                : "This is the active model. Deleting it will switch you to another installed model.")
        }
    }

    private var activeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Branding.appName) uses \(model.activeName)").font(.headline)
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

            if row.info.supportsRecognitionBias {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: recognitionBiasBinding) {
                        Text("Use dictionary during recognition").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.recognitionBias(row.id))
                    Text("Guides this model toward your dictionary terms as it listens. Rarely, it may "
                         + "prefer a term over a similar-sounding phrase — turn this off if that happens "
                         + "with your voice.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 36)
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
        .accessibilityIdentifier(AccessibilityID.Settings.Speech.row(row.id))
    }

    private var recognitionBiasBinding: Binding<Bool> {
        Binding(
            get: { row.recognitionBiasOn },
            set: { model.setRecognitionBias($0, for: row.id) })
    }

    private var icon: String {
        switch row.info.kind {
        case .apple: "apple.logo"
        default: "waveform"
        }
    }

    private var languageScope: String {
        row.info.languageCount <= 1 ? "English" : "\(row.info.languageCount) languages"
    }

    @ViewBuilder private var statusFooter: some View {
        if row.verificationFailed {
            if let bytes = row.installedBytes {
                Text("On disk · \(fmt(bytes))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if row.downloadFraction != nil || row.verifying {
            EmptyView()
        } else if row.info.systemManaged {
            if row.isUsable {
                Text("Built into macOS · No download, needs almost no memory")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.sizeStatus(row.id))
            }
        } else {
            sizeAndFit
        }
    }

    // One quiet line: the familiar disk figure, then a plain verdict answering "will this run on my Mac?"
    // computed against this Mac's installed RAM. The exact memory number lives in the hover/VoiceOver detail,
    // so the surface never shows two competing gigabyte counts.
    private var sizeAndFit: some View {
        HStack(spacing: 6) {
            Text(diskLabel).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            fitClause
        }
        .font(.caption2)
        .help(memoryDetailText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
        .accessibilityIdentifier(AccessibilityID.Settings.Speech.sizeStatus(row.id))
    }

    @ViewBuilder private var fitClause: some View {
        switch fitVerdict {
        case .comfortable:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Runs comfortably on your Mac").foregroundStyle(.secondary)
            }
        case .heavy:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Uses ~\(fmt(peakMemoryBytes)) memory — heavy on this Mac")
            }
            .foregroundStyle(.orange)
        }
    }

    private var diskLabel: String {
        if row.isUsable {
            return "\(fmt(row.installedBytes ?? row.info.approxDownloadBytes)) on disk"
        }
        return "~\(fmt(row.info.approxDownloadBytes)) download"
    }

    private var peakMemoryBytes: Int64 { row.info.approxMemoryBytes }

    private var fitVerdict: ModelFitVerdict {
        ModelMemory.verdict(peakBytes: peakMemoryBytes, physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    private var memoryDetailText: String {
        guard row.info.approxMemoryBytes > 0 else { return "" }
        return "Loads into memory only while you dictate — about \(fmt(peakMemoryBytes)) — then releases."
    }

    // VoiceOver can't hover the tooltip, so fold the disk size, the verdict, and the memory detail into one
    // spoken label.
    private var accessibilityStatus: String {
        let verdict = fitVerdict == .comfortable
            ? "Runs comfortably on your Mac."
            : "Uses about \(fmt(peakMemoryBytes)) of memory. Heavy on this Mac."
        return "\(diskLabel). \(verdict) \(memoryDetailText)"
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.fileStyle.string(fromByteCount: bytes)
    }

    @ViewBuilder private var actions: some View {
        if row.downloadFraction != nil {
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        } else if row.verifying {
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        } else if row.verificationFailed {
            Button("Test Again") { model.test(row.id) }
                .help("Re-runs the on-device self-test without re-downloading.")
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.testAgain(row.id))
            if !row.info.systemManaged {
                Button("Reinstall") { model.reinstall(row.id) }
                    .help("Deletes the files and downloads the model again.")
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.reinstall(row.id))
                Button("Delete", role: .destructive) { model.requestDelete(row.id) }
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.delete(row.id))
            }
        } else if row.isUsable {
            if !row.isActive {
                Button("Use This Model") { model.select(row.id) }
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.primaryAction(row.id))
            }
            Button("Test") { model.test(row.id) }
                .help("Runs a quick on-device self-test to confirm this model can transcribe.")
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.test(row.id))
            if !row.info.systemManaged {
                Button("Delete", role: .destructive) { model.requestDelete(row.id) }
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.delete(row.id))
            }
        } else {
            Button("Download") { model.startDownload(row.id) }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.primaryAction(row.id))
        }
    }
}
