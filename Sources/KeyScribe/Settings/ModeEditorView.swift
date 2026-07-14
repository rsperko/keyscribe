import AppKit
import SwiftUI
import KeyScribeKit

struct ModeEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    var globalWords: [String] = []
    var globalRules: [ReplacementsSet.Rule] = []
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
    let onDelete: () -> Void
    @State private var recognitionExpanded = false
    @State private var replacementAdvisories: [[VocabularyAnalysis.Advisory]] = []

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
                recognitionDisclosure
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
            refreshReplacementAdvisories(vocabularyScope)
        }
        .onChange(of: vocabularyScope) { _, scope in refreshReplacementAdvisories(scope) }
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

    private var vocabularyScope: VocabularyScope {
        VocabularyScope(
            globalWords: globalWords, globalRules: globalRules,
            local: VocabularyScope.Local(
                words: mode.dictionary.words, rules: mode.replacements.rules,
                includeGlobalWords: mode.dictionary.includeGlobal,
                includeGlobalRules: mode.replacements.includeGlobal))
    }

    @ViewBuilder private var recognitionDisclosure: some View {
        DisclosureSection(isExpanded: $recognitionExpanded) {
            DisclosureSummaryLabel(title: "Recognition and replacements", summary: recognitionSummary)
        } content: {
            Text("Add to this mode")
                .font(.subheadline.weight(.semibold))
            VocabularyComposer(
                analyze: { [vocabularyScope] in VocabularyAdvisor.analyze($0, in: vocabularyScope) },
                onAddWord: addWord,
                onAddReplacement: addReplacementRule)
            Text("Mode-only words and replacements apply on top of the global lists for this mode.")
                .font(.caption).foregroundStyle(.secondary)

            Text("Words to recognize")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Text("Mode-only names, product terms, and jargon \(Branding.appName) should recognize as written in this mode.")
                .font(.caption).foregroundStyle(.secondary)
            DictionaryRows(
                words: mode.dictionary.words,
                removeID: AccessibilityID.Mode.Editor.Recognition.dictionaryRemove,
                deletionScope: .mode,
                deleteConfirmConfirmID: AccessibilityID.Mode.Editor.Recognition.dictionaryDeleteConfirmConfirm,
                deleteConfirmCancelID: AccessibilityID.Mode.Editor.Recognition.dictionaryDeleteConfirmCancel,
                onRemove: removeWord)
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.Recognition.dictionaryList)
            if mode.dictionary.words.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            }

            Text("Automatic replacements")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                .font(.caption).foregroundStyle(.secondary)
            if mode.replacements.rules.count > 1 {
                Text("Applied from top to bottom. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReplacementRows(
                rules: mode.replacements.rules,
                advisories: replacementAdvisories,
                ids: ReplacementRowAccessibilityIDs(
                    list: AccessibilityID.Mode.Editor.Recognition.replacementsList,
                    edit: AccessibilityID.Mode.Editor.Recognition.replacementEdit,
                    remove: AccessibilityID.Mode.Editor.Recognition.replacementRemove,
                    advisory: AccessibilityID.Mode.Editor.Recognition.replacementAdvisory,
                    deleteConfirmConfirm: AccessibilityID.Mode.Editor.Recognition.replacementDeleteConfirmConfirm,
                    deleteConfirmCancel: AccessibilityID.Mode.Editor.Recognition.replacementDeleteConfirmCancel,
                    editor: ReplacementEditorAccessibilityIDs(
                        heard: AccessibilityID.Mode.Editor.Recognition.replacementEditorHeard,
                        useInstead: AccessibilityID.Mode.Editor.Recognition.replacementEditorUseInstead,
                        regex: AccessibilityID.Mode.Editor.Recognition.replacementEditorRegex,
                        advanced: AccessibilityID.Mode.Editor.Recognition.replacementEditorAdvanced,
                        status: AccessibilityID.Mode.Editor.Recognition.replacementEditorStatus,
                        update: AccessibilityID.Mode.Editor.Recognition.replacementEditorUpdate)),
                deletionScope: .mode,
                analyzeEdit: analyzeReplacementEdit,
                onUpdate: updateReplacement,
                onMove: moveReplacement,
                onRemove: removeReplacement(at:))
            if mode.replacements.rules.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            }

            if mode.source != .selection {
                Divider().padding(.vertical, 4)
                Toggle("Write numbers as digits", isOn: bind.commandsBinding(\.numbers))
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.numbersAsDigits)
                Text("Numbers are tidied on this Mac, before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Recognition.disclosure)
    }

    private var recognitionSummary: String {
        var parts: [String] = []
        if mode.source != .selection, mode.commands.numbers { parts.append("Numbers as digits") }
        let wordCount = mode.dictionary.words.count
        let replacementCount = mode.replacements.rules.count
        if wordCount > 0 { parts.append("\(wordCount) word\(wordCount == 1 ? "" : "s")") }
        if replacementCount > 0 { parts.append("\(replacementCount) replacement\(replacementCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "No mode-only words or replacements" : parts.joined(separator: ", ")
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

    private func addWord(_ word: String) {
        var updated = mode
        updated.dictionary.words = DictionarySet(words: mode.dictionary.words).adding(word: word).words
        onUpdate(updated)
    }

    private func removeWord(_ word: String) {
        var updated = mode
        updated.dictionary.words.removeAll { $0 == word }
        onUpdate(updated)
    }

    private func addReplacementRule(_ heard: String, _ replace: String, _ regex: Bool) {
        let set = ReplacementsSet(rules: mode.replacements.rules)
            .adding(heard: heard, replace: replace, regex: regex)
        var updated = mode
        updated.replacements.rules = set.rules
        onUpdate(updated)
    }

    private func removeReplacement(at index: Int) {
        guard mode.replacements.rules.indices.contains(index) else { return }
        var updated = mode
        updated.replacements.rules.remove(at: index)
        onUpdate(updated)
    }

    private func updateReplacement(
        _ original: ReplacementsSet.Rule, _ replacement: ReplacementsSet.Rule
    ) -> Bool {
        let replacementSet = ReplacementsSet(rules: mode.replacements.rules)
            .replacing(original, with: replacement)
        guard replacementSet.rules != mode.replacements.rules else { return false }
        var updated = mode
        updated.replacements.rules = replacementSet.rules
        onUpdate(updated)
        return true
    }

    private func moveReplacement(from source: IndexSet, to destination: Int) {
        var rules = mode.replacements.rules
        guard ReplacementMoveValidation.isValid(source: source, destination: destination, count: rules.count)
        else { return }
        rules.move(fromOffsets: source, toOffset: destination)
        var updated = mode
        updated.replacements.rules = rules
        onUpdate(updated)
    }

    private func analyzeReplacementEdit(
        _ original: ReplacementsSet.Rule, _ proposal: VocabularyProposal
    ) -> VocabularyAnalysis {
        var editingScope = vocabularyScope
        if let index = editingScope.local?.rules.firstIndex(of: original) {
            editingScope.local?.rules.remove(at: index)
        }
        return VocabularyAdvisor.analyze(proposal, in: editingScope)
    }

    private func refreshReplacementAdvisories(_ scope: VocabularyScope) {
        replacementAdvisories = VocabularyAdvisor.ruleAdvisories(in: scope)
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
