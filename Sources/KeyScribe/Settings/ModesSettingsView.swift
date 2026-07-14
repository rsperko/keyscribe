import AppKit
import SwiftUI
import KeyScribeKit

struct ModesSettingsView: View {
    @ObservedObject var model: ModesSettingsModel
    var brokenConnectionIds: Set<String> = []
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    @EnvironmentObject private var recordingState: HotkeyRecordingState
    @State private var modePendingDelete: Mode?
    @State private var showingAddMode = false
    // The List selection is mirrored through local @State so SwiftUI's selection write never mutates the
    // ObservableObject during a view update (which logs "Publishing changes from within view updates" and
    // re-enters the backing NSTableView). model.selectedID is synced in `.onChange`, which runs outside the
    // update pass.
    @State private var selection: String?

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
            List(selection: $selection) {
                Section {
                    ForEach(model.modes) { mode in
                        ModeSummaryRow(mode: mode, issue: issue(for: mode))
                            .tag(mode.id)
                            .accessibilityIdentifier(AccessibilityID.Mode.List.row(mode.id))
                    }
                } header: {
                    PaneListSectionHeader("Your Modes")
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.List.list)
            .paneListActionBar {
                Button("Add Mode…", systemImage: "plus") { showingAddMode = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.Mode.List.add)
            }
            .disabled(recordingState.isRecording)
            .frame(width: PaneMetrics.listWidth)

            Divider()

            Group {
                if let mode = model.selected {
                    ModeEditorView(
                        mode: mode, allModes: model.modes, actionShortcuts: actionShortcuts,
                        globalWords: model.globalWords, globalRules: model.globalRules,
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
                } else {
                    ContentUnavailableView(
                        "Choose a mode", systemImage: "square.stack.3d.up",
                        description: Text("Select one of your modes to edit it, or add a new one."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload(); selection = model.selectedID }
        .onChange(of: selection) { _, id in if model.selectedID != id { model.selectedID = id } }
        .onChange(of: model.selectedID) { _, id in if selection != id { selection = id } }
        .sheet(isPresented: $showingAddMode) {
            AddModeChooser(
                templates: model.allTemplates,
                onAddBlank: {
                    model.create()
                    showingAddMode = false
                },
                onAddTemplate: { template in
                    model.materializeTemplate(template.id)
                    showingAddMode = false
                },
                onCancel: { showingAddMode = false })
        }
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

private struct AddModeChooser: View {
    let templates: [Mode]
    let onAddBlank: () -> Void
    let onAddTemplate: (Mode) -> Void
    let onCancel: () -> Void
    @State private var selectedTemplateID: String?

    private var selectedTemplate: Mode? {
        templates.first { $0.id == selectedTemplateID } ?? templates.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Mode").font(.title2.bold())
            Text("Start with a template or make a blank mode.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                List(selection: $selectedTemplateID) {
                    Section("Start from a template") {
                        ForEach(templates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                }
                .frame(width: 220)

                if let template = selectedTemplate {
                    ModeStarterPreview(template: template) { onAddTemplate(template) }
                } else {
                    ContentUnavailableView("No templates available", systemImage: "square.stack.3d.up")
                }
            }
            Divider()
            HStack {
                Text("Or start with an empty mode.").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier(AccessibilityID.Mode.List.chooserCancel)
                Button("New Blank Mode", action: onAddBlank)
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .onAppear { selectedTemplateID = templates.first?.id }
    }
}

private struct ModeStarterPreview: View {
    let template: Mode
    let onAdd: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
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
                    severity: failure.usedLastKnownGood ? .advisory : .failure, font: .callout)
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
        guard mode.enabled else { return "Disabled" }
        return [ModeSummary.whenRuns(mode), issue?.summary ?? (mode.aiRewrite == nil ? "On this Mac" : "Cloud rewrite")]
            .joined(separator: " · ")
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

// Shared user-facing summary phrasing (ui_components.md "Mode summary") — plain words, never bundle IDs
// or raw regex.
enum ModeSummary {
    // The one place the spoken-phrase format lives, so menu, list, and gallery never phrase it differently.
    // Sentence-leading form is capitalized ("Say …"); inline/annotation form is not.
    static func spokenPhrase(_ phrase: String, capitalized: Bool) -> String {
        "\(capitalized ? "Say" : "say") \"\(phrase)\""
    }

    static func whenRuns(_ mode: Mode) -> String {
        let constrained = !mode.constraints.isEmpty
        // The Direct floor: shortcut first (it owns Fn), plus its fallback role.
        if mode.isSystem {
            if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
                return descriptor.displayString
            }
            return "Fallback"
        }
        // A constrained mode with no shortcut/phrase never auto-runs (Fn goes to Plain Dictation) — it's
        // menu-reachable, so don't imply it's automatic.
        if let key = mode.triggerKeys.first?.key, let descriptor = try? KeyDescriptor(parsing: key) {
            return constrained ? "\(descriptor.displayString) in matching apps"
                               : descriptor.displayString
        }
        if let phrase = mode.triggerPhrases.first {
            let said = spokenPhrase(phrase, capitalized: true)
            return constrained ? "\(said) in matching apps" : said
        }
        if constrained { return "App rule — add a shortcut to use it" }
        return "Pick from the menu"
    }

    static func availabilityDescription(_ mode: Mode) -> String {
        mode.constraints.isEmpty
            ? "Available in every app and website. Add a place to limit this mode to it."
            : "Available only in these places."
    }
}
