import AppKit
import SwiftUI
import KeyScribeKit

struct ModesSettingsView: View {
    @ObservedObject var model: ModesSettingsModel
    var brokenConnectionIds: Set<String> = []
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    @EnvironmentObject private var recordingState: HotkeyRecordingState
    @State private var modePendingDelete: Mode?

    var body: some View {
        VStack(spacing: 0) {
            if !model.loadFailures.isEmpty {
                ModeLoadFailureBanner(failures: model.loadFailures)
                Divider()
            }
            if let error = model.error {
                IssueText(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            paneBody
        }
    }

    private var paneBody: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                Section {
                    ForEach(model.modes) { mode in
                        ModeSummaryRow(mode: mode, issue: issue(for: mode))
                            .tag(mode.id)
                            .accessibilityIdentifier(AccessibilityID.Mode.List.row(mode.id))
                    }
                } header: {
                    PaneListSectionHeader("Your Modes")
                }
                if !model.starterTemplates.isEmpty {
                    Section {
                        ForEach(model.starterTemplates) { template in
                            ModeStarterRow(template: template)
                                .tag(template.id)
                                .accessibilityIdentifier(AccessibilityID.Mode.List.starterRow(template.id))
                        }
                    } header: {
                        PaneListSectionHeader("Start from a Template")
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.List.list)
            .paneListActionBar {
                Button("New Blank Mode", systemImage: "plus", action: model.create)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.Mode.List.addBlank)
            }
            .disabled(recordingState.isRecording)
            .frame(width: PaneMetrics.listWidth)

            Divider()

            Group {
                if let mode = model.selected {
                    ModeEditorView(
                        mode: mode, allModes: model.modes, actionShortcuts: actionShortcuts,
                        connections: model.connections, fragmentIds: model.fragmentIds,
                        fragmentNames: model.fragmentNames,
                        autofocusName: model.lastCreatedId == mode.id,
                        onUpdate: model.update,
                        onAddFragmentFile: model.addFragmentFile(named:),
                        onLoadFragmentBody: model.fragmentBody,
                        onSaveFragmentBody: model.saveFragmentBody,
                        onCloseFragment: model.closeFragment(_:fromMode:),
                        onRevealFragment: model.revealFragment,
                        onConsumeFocus: model.consumeCreated,
                        onDuplicate: { model.duplicate(mode) },
                        onDelete: { modePendingDelete = mode })
                        .id(mode.id)
                } else if let starter = model.selectedStarter {
                    ModeStarterPreview(template: starter) { model.materializeTemplate(starter.id) }
                        .id(starter.id)
                } else {
                    ContentUnavailableView(
                        "Choose a mode", systemImage: "square.stack.3d.up",
                        description: Text("Select one of your modes to edit it, or a template to add it."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .confirmationDialog(
            "Delete this mode?", isPresented: Binding(
                get: { modePendingDelete != nil },
                set: { if !$0 { modePendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let mode = modePendingDelete { model.delete(mode) }
                modePendingDelete = nil
            }
            .accessibilityIdentifier(AccessibilityID.Mode.List.deleteConfirmConfirm)
            Button("Cancel", role: .cancel) { modePendingDelete = nil }
                .accessibilityIdentifier(AccessibilityID.Mode.List.deleteConfirmCancel)
        } message: {
            Text("\(modePendingDelete?.name ?? "This mode") and its configuration will be removed. This cannot be undone.")
        }
    }

    private func issue(for mode: Mode) -> ModeSummaryIssue? {
        guard mode.enabled, let rewrite = mode.aiRewrite else { return nil }
        if rewrite.connection.isEmpty {
            return .needsService
        }
        if !model.connections.contains(where: { $0.id == rewrite.connection }) {
            return .missingService
        }
        if brokenConnectionIds.contains(rewrite.connection) {
            return .failedService
        }
        return nil
    }
}

// A Catalog row in the Start-from-a-Template section: the template name + its one-line capability. No
// per-row action — selecting it opens the read-only preview on the right (option-1-rollout.md).
private struct ModeStarterRow: View {
    let template: Mode

    var body: some View {
        PaneListRow(title: template.name, subtitle: ModeStore.templateSummary(for: template.id))
    }
}

// The Catalog detail for a starter Mode: a reduced, read-only capability preview with one CTA, `Add Mode`.
// It never edits configuration — pressing Add Mode materializes an editable (Disabled) mode and the pane
// swaps this preview for the live editor (installed-catalog-behavior.md). No edit fields, no destructive or
// Advanced controls live here.
private struct ModeStarterPreview: View {
    let template: Mode
    let onAdd: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("STARTER MODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                PaneDetailHeader(
                    systemImage: "square.stack.3d.up",
                    title: template.name,
                    subtitle: ModeStore.templateSummary(for: template.id))

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("How to use").foregroundStyle(.secondary)
                        Text(ModeSummary.whenRuns(template))
                    }
                    GridRow {
                        Text("Runs").foregroundStyle(.secondary)
                        Text(template.aiRewrite == nil ? "On this Mac" : "Needs an AI service")
                    }
                }
                .font(.callout)

                if let example = ModeStore.templateExample(for: template.id) {
                    exampleCard(example)
                }

                Divider()

                Button("Add Mode", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Mode.Preview.add(template.id))
                Text("Added modes start Disabled — review the settings, then turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func exampleCard(_ example: (heard: String, result: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(label: "You say", text: example.heard, style: AnyShapeStyle(.secondary))
            exampleRow(label: "You get", text: example.result, style: AnyShapeStyle(.primary))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func exampleRow(label: String, text: String, style: AnyShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(style)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Surfaces a malformed mode file instead of letting it vanish (a silent routing change). A mode with a prior
// good copy keeps running on it; one that never loaded is skipped.
private struct ModeLoadFailureBanner: View {
    let failures: [ModeStore.LoadFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(failures, id: \.id) { failure in
                IssueText(failure.usedLastKnownGood
                    ? "“\(failure.id)” has an error in its file — still running its last working version. Fix the file to apply changes."
                    : "“\(failure.id)” couldn’t be loaded and was skipped. Check its file under Application Support.",
                    severity: .advisory, font: .callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

private struct ModeSummaryRow: View {
    let mode: Mode
    var issue: ModeSummaryIssue?

    var body: some View {
        PaneListRow(title: mode.name, subtitle: summary, badges: {
            if mode.isSystem { PaneBadge("Built in") }
            if !mode.enabled { PaneBadge("Disabled") }
            if let issue {
                Circle().fill(.red).frame(width: 7, height: 7)
                    .help(issue.help)
                    .accessibilityLabel("Needs attention")
            }
        })
    }

    private var summary: String {
        var values = [ModeSummary.whenRuns(mode)]
        values.append(issue?.summary ?? (mode.aiRewrite == nil ? "On this Mac" : "Cloud rewrite"))
        if mode.excludeFromHistory { values.append("No history") }
        return values.joined(separator: " · ")
    }
}

private enum ModeSummaryIssue {
    case needsService
    case missingService
    case failedService

    var summary: String {
        switch self {
        case .needsService: "Needs AI service"
        case .missingService: "AI service missing"
        case .failedService: "AI service failed"
        }
    }

    var help: String {
        switch self {
        case .needsService: "Choose an AI service for this enabled mode."
        case .missingService: "The selected AI service no longer exists."
        case .failedService: "This mode's AI service failed its last connection test."
        }
    }
}

// Shared user-facing summary phrasing (ui_components.md "Mode summary"): when a mode runs and where its text
// goes, in plain words — never bundle IDs or raw regex.
enum ModeSummary {
    // The one place the spoken-phrase format lives, so menu, mode list, and template gallery can never phrase
    // it differently. Sentence-leading form is capitalized ("Say …"), the inline/annotation form is not.
    static func spokenPhrase(_ phrase: String, capitalized: Bool) -> String {
        "\(capitalized ? "Say" : "say") \"\(phrase)\""
    }

    static func whenRuns(_ mode: Mode) -> String {
        let constrained = !mode.constraints.isEmpty
        // The Direct floor: shortcut first (it owns Fn), plus its fallback role.
        if mode.isSystem {
            if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
                return "Triggered by \(descriptor.displayString) · fallback"
            }
            return "Fallback when no mode matches"
        }
        // A shortcut is what makes a mode run automatically. A constrained mode with NO shortcut/phrase never
        // auto-runs (Fn goes to Plain Dictation) — it's menu-reachable, so don't imply it's automatic.
        if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
            return constrained ? "Triggered by \(descriptor.displayString) in matching apps"
                               : "Triggered by \(descriptor.displayString)"
        }
        if let phrase = mode.triggerPhrases.first {
            let said = spokenPhrase(phrase, capitalized: true)
            return constrained ? "\(said) in matching apps" : said
        }
        if constrained { return "App rule — add a shortcut to use it" }
        return "Pick from the menu"
    }
}
