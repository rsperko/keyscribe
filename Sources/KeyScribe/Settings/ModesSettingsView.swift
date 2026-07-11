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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
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
                ForEach(model.modes) { mode in
                    ModeSummaryRow(mode: mode, issue: issue(for: mode))
                        .tag(mode.id)
                        .accessibilityIdentifier(AccessibilityID.Mode.List.row(mode.id))
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.List.list)
            .safeAreaInset(edge: .bottom) {
                Menu("Add Mode", systemImage: "plus") {
                    Button("Blank Mode", action: model.create)
                        .accessibilityIdentifier(AccessibilityID.Mode.List.addBlank)
                    Divider()
                    ForEach(ModeStore.templates()) { template in
                        Button(template.name) { model.materializeTemplate(template.id) }
                            .accessibilityIdentifier(AccessibilityID.Mode.List.addTemplate(template.id))
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .accessibilityIdentifier(AccessibilityID.Mode.List.add)
            }
            .disabled(recordingState.isRecording)
            .frame(width: 240)

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
                } else {
                    TemplateGallery(model: model)
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
            Button("Cancel", role: .cancel) { modePendingDelete = nil }
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

// The empty-detail discovery surface: a fresh install lists only Plain Dictation, and this shows the full
// menu of starter templates (name + one-liner + Add) so what can be added is visible without clicking.
private struct TemplateGallery: View {
    @ObservedObject var model: ModesSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a mode")
                    .font(.title3.bold())
                Text("Start from a template, or use Add Mode ▸ Blank Mode for an empty one.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(ModeStore.templates()) { template in
                        row(for: template)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func row(for template: Mode) -> some View {
        let added = model.isTemplateMaterialized(template.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.headline)
                Text(ModeStore.templateSummary(for: template.id))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if added {
                Label("Added", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Add") { model.materializeTemplate(template.id) }
                    .accessibilityIdentifier(AccessibilityID.Mode.Gallery.add(template.id))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// Surfaces a malformed mode file instead of letting it vanish (a silent routing change). A mode with a prior
// good copy keeps running on it; one that never loaded is skipped.
private struct ModeLoadFailureBanner: View {
    let failures: [ModeStore.LoadFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(failures, id: \.id) { failure in
                Label {
                    Text(failure.usedLastKnownGood
                        ? "“\(failure.id)” has an error in its file — still running its last working version. Fix the file to apply changes."
                        : "“\(failure.id)” couldn’t be loaded and was skipped. Check its file under Application Support.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(mode.name)
                if mode.isSystem {
                    Text("Built in").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.18), in: Capsule()).foregroundStyle(.secondary)
                }
                if !mode.enabled {
                    Text("Disabled")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let issue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .help(issue.help)
                }
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
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
