import AppKit
import SwiftUI
import KeyScribeKit

struct ModeEditorView: View {
    let mode: Mode
    let allModes: [Mode]
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
    var codingAgents: CodingAgentsSettingsModel?
    var sharedVocabularyNames: [String] = []

    private var bind: ModeBinding { ModeBinding(mode: mode, onUpdate: onUpdate) }
    private var trigger: ModeTrigger {
        ModeTrigger(mode: mode, allModes: allModes, onUpdate: onUpdate)
    }

    var body: some View {
        if mode.id == Mode.codingAgentId { codingAgentBody } else if mode.isSystem { systemBody } else { normalBody }
    }

    private var codingAgentBody: some View {
        ScrollViewReader { scroll in codingAgentForm(scroll) }
    }

    private func codingAgentForm(_ scroll: ScrollViewProxy) -> some View {
        Form {
            Section {
                PaneDetailHeader(
                    systemImage: "terminal",
                    title: mode.name,
                    subtitle: ModeSummary.whenRuns(mode),
                    badges: { PaneBadge("Built in") })
            }

            Section("How to start \(mode.name)") {
                ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
                PressStyleRow(trigger: trigger)
                TriggerConflictLabel(conflict: trigger.conflict, mode: mode)
                ExtraTriggersNote(mode: mode)
            }
            if let codingAgents {
                CodingAgentPhrasesSection(model: codingAgents)
                CodingAgentRecipientSection(
                    model: codingAgents, shortcut: ModeSummary.triggerDescriptors(mode).first?.displayString, scroll: scroll)
                SpokenResultSection(model: codingAgents, connections: connections)
                ConnectorSetupsProblemSection(model: codingAgents)
                ForEach(codingAgents.connectors) { connector in
                    AgentConnectorSection(model: connector, onInstall: { codingAgents.requestInstall($0, of: connector) })
                }
            }
            Section("Words") {
                modeVocabularyRow
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
            if mode.aiRewrite != nil {
                Section("Data sent with AI") {
                    SettingRow(
                        title: "Hide recognizable sensitive text",
                        help: "Best-effort redaction replaces recognizable sensitive spans with tokens before the AI rewrite, then restores them on this Mac. It protects only the rewrite request: the coding agent still receives your words in full.")
                    {
                        Toggle("", isOn: privacyMode).labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.privacy)
                    }
                }
            }
            Section("Where it goes") {
                Label(
                    "The coding agent receives what you say and sends it to its own AI provider under its own settings. Best-effort redaction does not apply to it.",
                    systemImage: "arrow.up.forward.app")
                    .font(.caption).foregroundStyle(.secondary)
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, what you send to coding agents is never written to local history. Other modes still record per your History setting.")
                {
                    Toggle("", isOn: bind.binding(\.excludeFromHistory)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.excludeFromHistory)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    private var systemBody: some View {
        Form {
            Section {
                PaneDetailHeader(
                    systemImage: "square.stack.3d.up",
                    title: mode.name,
                    subtitle: ModeSummary.whenRuns(mode),
                    badges: { PaneBadge("Built in") })
            }

            Section("How to start Plain Dictation") {
                ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
                PressStyleRow(trigger: trigger)
                TriggerConflictLabel(conflict: trigger.conflict, mode: mode)
                ExtraTriggersNote(mode: mode)
                if trigger.usesMouseShortcut {
                    Text("While this shortcut is assigned, the mouse button won’t also go Back or Forward in other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Plain Dictation also runs whenever no other mode matches on a shortcut it owns. A shortcut it does not own stays with the modes you gave it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What it does") {
                SettingRow(
                    title: "Turn spoken editing phrases into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D} (or \u{201C}insert clipboard as code\u{201D} for a code block), \u{201C}scratch that\u{201D}, \u{201C}never mind\u{201D} at the end to throw the dictation away, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: bind.commandsBinding(\.liveEdits)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.liveEdits)
                }
                SettingRow(
                    title: "Recognition and replacements",
                    result: "Uses your global vocabulary",
                    help: "Plain Dictation always uses the words and replacements in Global vocabulary. To give dictation its own words, add a mode.",
                    combinesAccessibilityChildren: false)
                {
                    Button("Edit Vocabulary…", action: onEditVocabulary)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Recognition.editVocabulary)
                }
            }
            Section("Result handling") {
                nonPasteInsertionNotice
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, Plain Dictation's dictations are never written to local history. Other modes still record per your History setting.")
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

            Section {
                CommittedTextField("Name", text: mode.name, autofocus: autofocusName, validation: UserInputValidation.nameIssue) { value in
                    var updated = mode; updated.name = value.trimmingCharacters(in: .whitespacesAndNewlines); onUpdate(updated)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.name)
                Toggle("Enabled", isOn: bind.binding(\.enabled))
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.enabled)
            }

            ModeRoutingSection(mode: mode, allModes: allModes, onUpdate: onUpdate)
            Section("What it does") {
                SettingRow(
                    title: "Turn spoken editing phrases into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D} (or \u{201C}insert clipboard as code\u{201D} for a code block), \u{201C}scratch that\u{201D}, \u{201C}never mind\u{201D} at the end to throw the dictation away, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
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
            if mode.answersAloud, let codingAgents, let voice = codingAgents.voice {
                Section("Answer") {
                    SpokenVoiceRows(
                        voice: voice,
                        selection: Binding(get: { codingAgents.voiceChoice }, set: { codingAgents.voiceChoice = $0 }),
                        spokenVoice: codingAgents.chosenVoice,
                        sharedNote: "This choice also applies to coding agent reply updates, so changing it here changes it there.")
                }
            }

            Section("Result handling") {
                if !mode.answersAloud { nonPasteInsertionNotice }
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, this mode's dictations are never written to local history — useful for sensitive work. Other modes still record per your History setting.")
                {
                    Toggle("", isOn: bind.binding(\.excludeFromHistory)).labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.excludeFromHistory)
                }
                if !mode.answersAloud { finishingControls }
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
                summaryLine("Does", mode.answersAloud
                    ? "Answers your spoken question about the selected text"
                    : mode.source == .selection
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
        return "\(mode.answersAloud ? "Cloud answer" : "Cloud rewrite") via \(name)\(redaction)"
    }

    private var modeVocabularyRow: some View {
        SettingRow(
            title: "Recognition and replacements",
            result: VocabularyScopePicker.summary(for: mode),
            help: Self.vocabularyHelp(for: mode, shared: sharedVocabularyNames),
            combinesAccessibilityChildren: false)
        {
            Button("Edit Vocabulary…", action: onEditVocabulary)
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.Recognition.editVocabulary)
        }
    }

    static func vocabularyHelp(for mode: Mode, shared: [String] = []) -> String {
        let base = mode.dictionary.includeGlobal || mode.replacements.includeGlobal
            ? "Mode-only words and replacements apply only here. Global vocabulary is also included where this mode allows it."
            : shared.isEmpty ? "This mode uses only the words and replacements you add for it."
            : "Mode-only words and replacements apply only here."
        guard !shared.isEmpty else { return base }
        return "\(base) It also uses \(ListFormatter.localizedString(byJoining: shared)), shared with other modes."
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
                if mode.answersAloud {
                    Label(
                        "Selected text shared — the highlighted text and your spoken request are sent to the AI service to be answered. Nothing else from your screen is sent.",
                        systemImage: "doc.on.doc")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode.source == .selection {
                    Label(
                        "Selected text shared — the highlighted text is the content sent to the AI service to be rewritten.",
                        systemImage: "doc.on.doc")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !mode.answersAloud { contextRows }
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

    @ViewBuilder private var contextRows: some View {
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
    }

    private var privacyMode: Binding<Bool> {
        Binding(get: { mode.commands.privacy }, set: { value in
            var updated = mode
            updated.commands.privacy = value
            onUpdate(updated)
        })
    }
}
