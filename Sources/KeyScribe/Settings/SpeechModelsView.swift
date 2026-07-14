import SwiftUI
import KeyScribeKit

struct SpeechModelsView: View {
    @ObservedObject var model: SpeechModelsModel
    @ObservedObject var settings: SettingsModel
    @State private var selectedModelID: String?
    @State private var modelBehaviorExpanded = false
    @State private var modelActionsExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if selectedModelID == nil || !model.rows.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = activeRow?.id
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
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        let name = model.rows.first { $0.id == model.pendingDeleteId }?.info.displayName ?? "This model"
        if model.pendingDeleteLeavesNoEngine {
            return "Deleting \(name)'s downloaded files leaves no model for speech recognition. This cannot be undone."
        }
        if model.rows.first(where: { $0.id == model.pendingDeleteId })?.isActive == true {
            return "Deleting \(name)'s downloaded files switches speech recognition to another installed model. This cannot be undone."
        }
        return "Deleting \(name)'s downloaded files removes this model. This cannot be undone."
    }

    // There is no bottom action bar — acquisition is the selected catalog detail's Download button, never
    // a name menu.
    private var listColumn: some View {
        VStack(spacing: 0) {
            performanceControls
            Divider()
            List(selection: $selectedModelID) {
                Section {
                    ForEach(model.onThisMacRows) { modelRow($0) }
                } header: {
                    PaneListSectionHeader("On This Mac")
                }
                if !model.availableRows.isEmpty {
                    Section {
                        ForEach(model.availableRows) { modelRow($0) }
                    } header: {
                        PaneListSectionHeader("Available to Download")
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.Speech.list)
        }
        .frame(width: PaneMetrics.listWidth)
    }

    private var performanceControls: some View {
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
        .padding(10)
    }

    private func modelRow(_ row: SpeechModelsModel.Row) -> some View {
        PaneListRow(title: row.info.displayName, subtitle: listSubtitle(row), status: listStatus(row))
            .tag(row.id)
            .accessibilityIdentifier(AccessibilityID.Settings.Speech.row(row.id))
    }

    private var detail: some View {
        Group {
            if let selectedRow {
                ScrollView {
                    choiceDetail(selectedRow)
                        .id(selectedRow.id)
                }
            } else {
                ContentUnavailableView("Choose a model", systemImage: "waveform")
            }
        }
    }

    private func choiceDetail(_ row: SpeechModelsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !row.isUsable {
                Text("AVAILABLE TO DOWNLOAD")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.catalogLabel(row.id))
            }
            PaneDetailHeader(
                systemImage: row.isActive ? "checkmark.seal.fill" : "waveform",
                symbolStyle: row.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary),
                title: row.info.displayName,
                subtitle: SpeechModelChoiceCopy.bestFor(row.info),
                badges: {
                    if row.info.isDefaultEnglish { PaneBadge("Recommended", kind: .prominent) }
                })

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
                IssueText(error, font: .callout)
            }

            Divider()

            primaryAction(for: row)

            if hasModelActions(row) {
                DisclosureSection("Recognition and maintenance", isExpanded: $modelActionsExpanded) {
                    modelActions(for: row)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Speech.advanced(row.id))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            Label("Current model", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.secondary)
        case .use:
            Button("Use This Model") {
                model.select(row.id)
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
        let canTest = row.isUsable
        let canReinstall = row.verificationFailed && !row.info.systemManaged
        let canDelete = !row.info.systemManaged && (row.isUsable || row.verificationFailed)
        VStack(alignment: .leading, spacing: 12) {
            if row.info.supportsRecognitionBias {
                Toggle("Use dictionary during recognition", isOn: recognitionBiasBinding(for: row))
                    .accessibilityIdentifier(AccessibilityID.Settings.Speech.recognitionBias(row.id))
            }
            if canTest || canReinstall || canDelete {
                HStack(spacing: 10) {
                    if canTest {
                        Button {
                            model.test(row.id)
                        } label: {
                            Label("Test model", systemImage: "waveform.and.magnifyingglass")
                        }
                        .accessibilityIdentifier(AccessibilityID.Settings.Speech.test(row.id))
                        if row.testPassed {
                            Label("Passed", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    if canReinstall {
                        Button {
                            model.reinstall(row.id)
                        } label: {
                            Label("Reinstall model", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.Settings.Speech.reinstall(row.id))
                    }
                    Spacer()
                    if canDelete {
                        PaneDeleteButton(title: "Delete model") { model.requestDelete(row.id) }
                            .accessibilityIdentifier(AccessibilityID.Settings.Speech.delete(row.id))
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var activeRow: SpeechModelsModel.Row? {
        model.rows.first(where: { $0.isActive })
    }

    private var selectedRow: SpeechModelsModel.Row? {
        model.rows.first { $0.id == selectedModelID }
    }

    private func recognitionBiasBinding(for row: SpeechModelsModel.Row) -> Binding<Bool> {
        Binding(
            get: { row.recognitionBiasOn },
            set: { model.setRecognitionBias($0, for: row.id) })
    }

    // Advanced (test / reinstall / delete / recognition bias) belongs only to a real local install — a
    // usable model or a quarantined failure with files still on disk. A pristine catalog preview shows
    // none of it, so recognition-bias alone no longer surfaces the section.
    private func hasModelActions(_ row: SpeechModelsModel.Row) -> Bool {
        row.isUsable || (!row.info.systemManaged && row.verificationFailed)
    }

    // A row carries either a colored state line (installed/in-flight models) or a gray metadata subtitle
    // (a pristine catalog entry — "English · 466 MB", never a redundant "Download available").
    private func listStatus(_ row: SpeechModelsModel.Row) -> PaneRowStatus? {
        if row.isActive {
            return PaneRowStatus(text: "Current", systemImage: "checkmark.seal.fill", style: AnyShapeStyle(.tint))
        }
        if let fraction = row.downloadFraction {
            return PaneRowStatus(
                text: "Downloading \(Int((fraction * 100).rounded()))%",
                systemImage: "arrow.down.circle", style: AnyShapeStyle(.tint))
        }
        if row.verifying {
            return PaneRowStatus(text: "Testing…", systemImage: "ellipsis.circle", style: AnyShapeStyle(.secondary))
        }
        if row.verificationFailed {
            return PaneRowStatus(
                text: "Needs attention", systemImage: "exclamationmark.triangle.fill", style: AnyShapeStyle(.orange))
        }
        if row.isUsable {
            return PaneRowStatus(text: "Ready", systemImage: "checkmark.circle.fill", style: AnyShapeStyle(.green))
        }
        return nil
    }

    private func listSubtitle(_ row: SpeechModelsModel.Row) -> String? {
        guard listStatus(row) == nil else { return nil }
        return "\(languageScope(row.info)) · \(ByteCountFormatter.fileStyle.string(fromByteCount: row.info.approxDownloadBytes))"
    }

    private func languageScope(_ info: SpeechModelInfo?) -> String {
        guard let info else { return "Speech recognition" }
        return info.languageCount <= 1 ? "English" : "\(info.languageCount) languages"
    }

    private func storageLabel(_ row: SpeechModelsModel.Row) -> String {
        if row.info.systemManaged { return "Built into macOS" }
        let bytes = row.installedBytes ?? row.info.approxDownloadBytes
        // A quarantined (verificationFailed) model still has its files on disk even though it isn't
        // usable — "download" would wrongly imply nothing is stored.
        let label = (row.isUsable || row.verificationFailed) ? "on disk" : "download"
        return "\(ByteCountFormatter.fileStyle.string(fromByteCount: bytes)) \(label)"
    }

    private func memoryLabel(_ info: SpeechModelInfo) -> String {
        SpeechModelChoiceCopy.memoryUse(for: info)
    }
}
