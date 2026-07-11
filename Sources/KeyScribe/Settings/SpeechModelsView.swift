import SwiftUI
import KeyScribeKit

struct SpeechModelsView: View {
    @ObservedObject var model: SpeechModelsModel
    @ObservedObject var settings: SettingsModel
    @State private var choosingModel = false
    @State private var selectedModelID: String?
    @State private var modelBehaviorExpanded = false
    @State private var modelActionsExpanded = false

    var body: some View {
        Group {
            if choosingModel {
                chooser
            } else {
                overview
            }
        }
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

    private var overview: some View {
        Form {
            Section("Speech recognition") {
                activeModel
            }
            Section("Performance") {
                DisclosureSection(isExpanded: $modelBehaviorExpanded) {
                    DisclosureSummaryLabel(title: "Keep speech recognition ready", summary: settings.evictionSummary)
                } content: {
                    Picker("When idle", selection: $settings.eviction) {
                        ForEach(settings.evictions, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.eviction)
                    Text(settings.evictionFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.advancedModelBehavior)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var activeModel: some View {
        let row = activeRow
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(row?.info.displayName ?? model.activeName).font(.headline)
                Text("\(languageScope(row?.info)) · Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let row {
                    Text(SpeechModelChoiceCopy.bestFor(row.info))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Change…") {
                selectedModelID = activeRow?.id
                choosingModel = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.Settings.Speech.change)
        }
        .padding(.vertical, 4)
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back") { choosingModel = false }
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.back)
                Text("Choose a speech model")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 0) {
                List(selection: $selectedModelID) {
                    Section("Recommended") {
                        choiceListRow(recommendedRow)
                    }
                    Section("Other models") {
                        ForEach(otherRows) { choiceListRow($0) }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.list)
                .frame(width: 240)

                Divider()

                Group {
                    if let selectedRow {
                        choiceDetail(selectedRow)
                            .id(selectedRow.id)
                    } else {
                        ContentUnavailableView("Choose a model", systemImage: "waveform")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            if selectedModelID == nil { selectedModelID = activeRow?.id }
        }
    }

    private func choiceListRow(_ row: SpeechModelsModel.Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.info.displayName)
                Text(listStatus(row))
                    .font(.caption)
                    .foregroundStyle(row.isActive
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            if row.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Current model")
            }
        }
        .tag(row.id)
        .accessibilityIdentifier(AccessibilityID.Settings.Speech.row(row.id))
    }

    private func choiceDetail(_ row: SpeechModelsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.isActive ? "checkmark.seal.fill" : "waveform")
                    .font(.title2)
                    .foregroundStyle(row.isActive
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.info.displayName).font(.title2.bold())
                        if row.info.isDefaultEnglish { SpeechBadge(text: "Recommended", prominent: true) }
                    }
                    Text(SpeechModelChoiceCopy.bestFor(row.info))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Languages").foregroundStyle(.secondary)
                    Text(languageScope(row.info))
                }
                GridRow {
                    Text("Storage").foregroundStyle(.secondary)
                    Text(storageLabel(row))
                }
                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text(memoryLabel(row.info))
                }
            }
            .font(.callout)

            if let error = row.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            primaryAction(for: row)

            if hasModelActions(row) {
                DisclosureGroup("Advanced", isExpanded: $modelActionsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        modelActions(for: row)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .padding(28)
    }

    @ViewBuilder private func primaryAction(for row: SpeechModelsModel.Row) -> some View {
        switch SpeechModelChoiceCopy.primaryAction(
            isActive: row.isActive,
            isUsable: row.isUsable,
            isDownloading: row.downloadFraction != nil,
            isVerifying: row.verifying,
            verificationFailed: row.verificationFailed
        ) {
        case .current:
            Label("Current model", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        case .use:
            Button("Use This Model") {
                model.select(row.id)
                choosingModel = false
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.Settings.Speech.primaryAction(row.id))
        case .download:
            Button("Download") { model.startDownload(row.id) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.primaryAction(row.id))
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(row.downloadPhase ?? "Downloading…")
            }
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing model…")
            }
        case .testAgain:
            Button("Test Again") { model.test(row.id) }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.testAgain(row.id))
        }
    }

    @ViewBuilder private func modelActions(for row: SpeechModelsModel.Row) -> some View {
        if row.info.supportsRecognitionBias {
            Toggle("Use dictionary during recognition", isOn: recognitionBiasBinding(for: row))
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.recognitionBias(row.id))
        }
        if row.isUsable {
            Button("Test model") { model.test(row.id) }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.test(row.id))
        }
        if row.verificationFailed && !row.info.systemManaged {
            Button("Reinstall model") { model.reinstall(row.id) }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.reinstall(row.id))
        }
        if !row.info.systemManaged && (row.isUsable || row.verificationFailed) {
            Button("Delete model", role: .destructive) { model.requestDelete(row.id) }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.delete(row.id))
        }
    }

    private var activeRow: SpeechModelsModel.Row? {
        model.rows.first(where: { $0.isActive })
    }

    private var selectedRow: SpeechModelsModel.Row? {
        model.rows.first { $0.id == selectedModelID }
    }

    private var recommendedRow: SpeechModelsModel.Row {
        model.rows.first(where: { $0.info.isDefaultEnglish }) ?? model.rows[0]
    }

    private var otherRows: [SpeechModelsModel.Row] {
        model.rows.filter { $0.id != recommendedRow.id }
    }

    private func recognitionBiasBinding(for row: SpeechModelsModel.Row) -> Binding<Bool> {
        Binding(
            get: { row.recognitionBiasOn },
            set: { model.setRecognitionBias($0, for: row.id) })
    }

    private func hasModelActions(_ row: SpeechModelsModel.Row) -> Bool {
        row.info.supportsRecognitionBias || row.isUsable || (!row.info.systemManaged && row.verificationFailed)
    }

    private func listStatus(_ row: SpeechModelsModel.Row) -> String {
        if row.isActive { return "Current" }
        if row.downloadFraction != nil { return "Downloading" }
        if row.verifying { return "Testing" }
        if row.verificationFailed { return "Needs attention" }
        return row.isUsable ? "Ready" : "Download available"
    }

    private func languageScope(_ info: SpeechModelInfo?) -> String {
        guard let info else { return "Speech recognition" }
        return info.languageCount <= 1 ? "English" : "\(info.languageCount) languages"
    }

    private func storageLabel(_ row: SpeechModelsModel.Row) -> String {
        if row.info.systemManaged { return "Built into macOS" }
        let bytes = row.installedBytes ?? row.info.approxDownloadBytes
        let label = row.isUsable ? "on disk" : "download"
        return "\(ByteCountFormatter.fileStyle.string(fromByteCount: bytes)) \(label)"
    }

    private func memoryLabel(_ info: SpeechModelInfo) -> String {
        SpeechModelChoiceCopy.memoryUse(for: info)
    }
}

private struct SpeechBadge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(prominent ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}
