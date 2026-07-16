import AppKit
import SwiftUI
import KeyScribeKit

struct ModeEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    let connections: [Connection]
    let fragmentIds: [String]
    let fragmentNames: [String: String]
    var autofocusName = false
    let onUpdate: (Mode) -> Void
    let onAddFragmentFile: (String) -> String?
    let onLoadFragmentBody: (String) -> String
    let onSaveFragmentBody: (String, String) -> Void
    let onCloseFragment: (String, String) -> Void
    let onRevealFragment: (String) -> Void
    var onConsumeFocus: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onEditVocabulary: () -> Void = {}
    let onDelete: () -> Void

    private var bind: ModeBinding { ModeBinding(mode: mode, onUpdate: onUpdate) }
    private var trigger: ModeTrigger {
        ModeTrigger(mode: mode, allModes: allModes, actionShortcuts: actionShortcuts, onUpdate: onUpdate)
    }

    var body: some View {
        if mode.isSystem { systemBody } else { normalBody }
    }

    private var systemBody: some View {
        Form {
            Section("Ways to use this mode") {
                ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                TriggerConflictLabel(conflict: trigger.conflict)
                TriggerOverlapLabel(overlap: trigger.overlap)
                if usesMouseShortcut {
                    Text("While this shortcut is assigned, the mouse button won’t also go Back or Forward in other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Plain Dictation is also used whenever no other mode matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spoken editing") {
                SettingRow(
                    title: "Turn spoken editing phrases into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D}, \u{201C}scratch that\u{201D}, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: bind.commandsBinding(\.liveEdits)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.liveEdits)
                }
            }
            Section("Result handling") {
                nonPasteInsertionNotice
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, Direct's dictations are never written to local history. Otherwise it records per your global History setting.")
                {
                    Toggle("", isOn: bind.binding(\.excludeFromHistory)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.excludeFromHistory)
                }
                finishingControls
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    private var normalBody: some View {
        Form {
            Section { summaryCard }

            Section("Basics") {
                CommittedTextField("Name", text: mode.name, autofocus: autofocusName, validation: UserInputValidation.nameIssue) { value in
                    var updated = mode; updated.name = value.trimmingCharacters(in: .whitespacesAndNewlines); onUpdate(updated)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.name)
                Toggle("Enabled", isOn: bind.binding(\.enabled))
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.enabled)
            }

            ModeRoutingSection(mode: mode, allModes: allModes, actionShortcuts: actionShortcuts, onUpdate: onUpdate)
            Section("What it does") {
                SettingRow(
                    title: "Rewrite selected text",
                    result: mode.source == .selection ? "Rewrites the highlighted text" : "Dictates at the cursor",
                    help: "When on, this mode edits the currently selected text using your spoken instruction instead of inserting new text at the cursor — for \u{201C}make this more formal\u{201D} style edits. The selection is captured with ⌘C, so there must be something selected for it to act on.")
                {
                    Toggle("", isOn: selectionMode).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.rewriteSelection)
                }
                SettingRow(
                    title: "Turn spoken commands into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D}, \u{201C}scratch that\u{201D}, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: bind.commandsBinding(\.liveEdits)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.liveEdits)
                }
                modeVocabularyRow
                if mode.source != .selection {
                    SettingRow(
                        title: "Write numbers as digits",
                        help: "Numbers are tidied on this Mac, before any AI rewrite.")
                    {
                        Toggle("", isOn: bind.commandsBinding(\.numbers)).labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.numbersAsDigits)
                    }
                }
            }
            ModeAISection(
                mode: mode, connections: connections,
                fragmentIds: fragmentIds, fragmentNames: fragmentNames,
                onUpdate: onUpdate,
                onAddFragmentFile: onAddFragmentFile,
                onLoadFragmentBody: onLoadFragmentBody,
                onSaveFragmentBody: onSaveFragmentBody,
                onCloseFragment: onCloseFragment,
                onRevealFragment: onRevealFragment)
            dataSentWithAISection

            Section("Result handling") {
                nonPasteInsertionNotice
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, this mode's dictations are never written to local history — useful for sensitive work. Other modes still record per your History setting.")
                {
                    Toggle("", isOn: bind.binding(\.excludeFromHistory)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.excludeFromHistory)
                }
                finishingControls
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        onDuplicate()
                    } label: {
                        Label("Duplicate Mode", systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.duplicate)
                    Spacer()
                    PaneDeleteButton(title: "Delete Mode") { onDelete() }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.delete)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            if autofocusName { onConsumeFocus() }
        }
    }

    private var usesMouseShortcut: Bool {
        guard let key = mode.triggerKeys.first?.key,
              let descriptor = try? KeyDescriptor(parsing: key)
        else { return false }
        if case .mouseButton = descriptor { return true }
        return false
    }

    @ViewBuilder private var nonPasteInsertionNotice: some View {
        if mode.insertion != .paste {
            Label("This mode uses a custom insertion method from its TOML file.", systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneDetailHeader(
                systemImage: "square.stack.3d.up",
                title: mode.name,
                subtitle: ModeSummary.whenRuns(mode),
                badges: {
                    if mode.isSystem { PaneBadge("Built in") }
                    if !mode.enabled { PaneBadge("Disabled") }
                })
            VStack(alignment: .leading, spacing: 6) {
                summaryLine("Status", mode.enabled ? "Enabled" : "Disabled")
                summaryLine("Trigger", ModeSummary.whenRuns(mode))
                summaryLine("Does", mode.source == .selection
                    ? "Replaces the selected text using your spoken instruction"
                    : (mode.commands.liveEdits ? "Dictation with spoken edits" : "Plain dictation"))
                summaryLine("Text goes", boundarySummary)
            }
        }
        .padding(.vertical, 2)
    }

    private func summaryLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(.callout)
        }
    }

    private var boundarySummary: String {
        guard let rewrite = mode.aiRewrite else { return "Stays on this Mac" }
        guard !rewrite.connection.isEmpty else { return "Needs AI service" }
        guard let name = connections.first(where: { $0.id == rewrite.connection })?.name else {
            return "AI service missing"
        }
        let redaction = mode.commands.privacy ? ", best-effort redaction on" : ""
        return "Cloud rewrite via \(name)\(redaction)"
    }

    private var modeVocabularyRow: some View {
        SettingRow(
            title: "Recognition and replacements",
            result: VocabularyScopePicker.summary(for: mode),
            help: modeVocabularyHelp,
            combinesAccessibilityChildren: false)
        {
            Button("Edit Vocabulary…", action: onEditVocabulary)
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.Recognition.editVocabulary)
        }
    }

    private var modeVocabularyHelp: String {
        guard mode.dictionary.includeGlobal || mode.replacements.includeGlobal else {
            return "This mode uses only the words and replacements you add for it."
        }
        return "Mode-only words and replacements apply only here. Global vocabulary is also included where this mode allows it."
    }

    @ViewBuilder private var finishingControls: some View {
        SettingRow(
            title: "Trim trailing punctuation",
            help: "Removes a final . ! or ? (and any trailing spaces) from the result before it is inserted. Useful for command, identifier, or subject-line modes that should not end in sentence punctuation. Runs before \u{201C}End with\u{201D} adds its space or line break.")
        {
            Toggle("", isOn: bind.binding(\.trimTrailingPunctuation)).labelsHidden()
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.trimTrailingPunctuation)
        }
        SettingRow(
            title: "End with",
            help: "Appends a space or line break to the end of every dictation. It is part of the inserted text, so one ⌘Z still undoes the whole thing.")
        {
            Picker("", selection: bind.binding(\.trailing)) {
                Text("Nothing").tag(Mode.Trailing.none)
                Text("Space").tag(Mode.Trailing.space)
                Text("Line break").tag(Mode.Trailing.newline)
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier(AccessibilityID.Mode.Editor.trailing)
        }
        nonDefaultSubmitNotice
    }

    @ViewBuilder private var nonDefaultSubmitNotice: some View {
        if mode.submit != .none {
            Label("This mode sends \(submitLabel) after inserting, configured in its TOML file.",
                  systemImage: "return")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var submitLabel: String {
        switch mode.submit {
        case .none: "nothing"
        case .return: "Return"
        case .shiftReturn: "Shift-Return"
        case .cmdReturn: "Command-Return"
        }
    }

    // Privacy and context are mutually exclusive; the controls stay visible with the reason rather than
    // disappearing, so the user always sees exactly what leaves the Mac.
    @ViewBuilder private var dataSentWithAISection: some View {
        if mode.aiRewrite != nil {
            Section("Data sent with AI") {
                if mode.source == .selection {
                    Label(
                        "Selected text shared — the highlighted text is the content sent to the AI service to be rewritten.",
                        systemImage: "doc.on.doc")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingRow(
                    title: "Send app details",
                    help: "Shares the frontmost app's name as untrusted reference, never as commands. The browser URL is never sent — it is only a local routing key.",
                    dependencyReason: mode.commands.privacy ? "Off while best-effort redaction sends only the redacted dictation." : nil)
                {
                    Toggle("", isOn: bind.contextBinding(\.app)).labelsHidden().disabled(mode.commands.privacy)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Context.app)
                }
                SettingRow(
                    title: "Send text before the cursor",
                    help: "Shares a short, bounded excerpt of the text just before the insertion point as untrusted reference, so a rewrite can match the surrounding voice and tense. Native text fields only — best-effort (browsers expose nothing).",
                    dependencyReason: mode.commands.privacy ? "Off while best-effort redaction sends only the redacted dictation." : nil)
                {
                    Toggle("", isOn: bind.contextBinding(\.precedingText)).labelsHidden().disabled(mode.commands.privacy)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Context.precedingText)
                }
                SettingRow(
                    title: "Hide recognizable sensitive text",
                    help: "Best-effort redaction replaces recognizable sensitive spans with tokens before the request, then restores them on this Mac. It is pattern matching: it can miss content, it turns all context off, and it does not make cloud use appropriate for every secret.",
                    dependencyReason: mode.commands.privacy ? "All context is off while this is on." : nil)
                {
                    Toggle("", isOn: privacyMode).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.privacy)
                }
            }
        }
    }

    private var selectionMode: Binding<Bool> {
        Binding(
            get: { mode.source == .selection },
            set: { enabled in
                var updated = mode
                updated.source = enabled ? .selection : .dictation
                updated.output = enabled ? .replaceSelection : .cursor
                onUpdate(updated)
            })
    }

    private var privacyMode: Binding<Bool> {
        Binding(get: { mode.commands.privacy }, set: { value in
            var updated = mode
            updated.commands.privacy = value
            onUpdate(updated)
        })
    }
}
