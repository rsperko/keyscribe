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
    let onDelete: () -> Void
    @State private var recognitionExpanded = false

    private var bind: ModeBinding { ModeBinding(mode: mode, onUpdate: onUpdate) }
    private var trigger: ModeTrigger {
        ModeTrigger(mode: mode, allModes: allModes, actionShortcuts: actionShortcuts, onUpdate: onUpdate)
    }

    var body: some View {
        if mode.isSystem { systemBody } else { normalBody }
    }

    // The Direct floor (`_direct`, shown as "Plain Dictation"): a reduced, mostly-locked editor. Only its
    // shortcut and result handling are editable; the guarantees (no AI, no edit-in-place, global vocabulary
    // only) are fixed.
    private var systemBody: some View {
        Form {
            Section {
                Label("Plain Dictation is the built-in fallback — it dictates on-device with no AI and always types plainly, and runs whenever no other mode applies. You can change its shortcut and result handling (including whether it saves to history); everything else is fixed.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                ModeTriggerRow(mode: mode, onUpdate: onUpdate)
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                TriggerConflictLabel(conflict: trigger.conflict)
                TriggerOverlapLabel(overlap: trigger.overlap)
                Text("Plain Dictation owns Fn by default. Change or clear its shortcut here — even with no shortcut it still runs automatically whenever no other mode applies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What it does") {
                SettingRow(
                    title: "Turn spoken commands into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D}, \u{201C}scratch that\u{201D}, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: bind.commandsBinding(\.liveEdits)).labelsHidden()
                }
            }
            Section("Result handling") {
                nonPasteInsertionNotice
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, Direct's dictations are never written to local history. Otherwise it records per your global History setting.")
                {
                    Toggle("", isOn: bind.binding(\.excludeFromHistory)).labelsHidden()
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
                CommittedTextField("Name", text: mode.name, autofocus: autofocusName) { value in
                    var updated = mode; updated.name = value; onUpdate(updated)
                }
                Toggle("Enabled", isOn: bind.binding(\.enabled))
            }

            ModeRoutingSection(mode: mode, allModes: allModes, actionShortcuts: actionShortcuts, onUpdate: onUpdate)
            Section("What it does") {
                SettingRow(
                    title: "Rewrite selected text",
                    result: mode.source == .selection ? "Rewrites the highlighted text" : "Dictates at the cursor",
                    help: "When on, this mode edits the currently selected text using your spoken instruction instead of inserting new text at the cursor — for \u{201C}make this more formal\u{201D} style edits. The selection is captured with ⌘C, so there must be something selected for it to act on.")
                {
                    Toggle("", isOn: selectionMode).labelsHidden()
                }
                SettingRow(
                    title: "Turn spoken commands into edits",
                    help: "Turns phrases you say into edits: \u{201C}insert new line\u{201D}, \u{201C}insert new paragraph\u{201D}, \u{201C}insert tab character\u{201D}, \u{201C}insert clipboard contents\u{201D}, \u{201C}scratch that\u{201D}, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: bind.commandsBinding(\.liveEdits)).labelsHidden()
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
                }
                finishingControls
            }

            Section {
                Button("Duplicate Mode", systemImage: "plus.square.on.square", action: onDuplicate)
                Button("Delete Mode", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear { if autofocusName { onConsumeFocus() } }
    }

    @ViewBuilder private var nonPasteInsertionNotice: some View {
        if mode.insertion != .paste {
            Label("This mode uses a custom insertion method from its TOML file.", systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryLine("When", ModeSummary.whenRuns(mode))
            summaryLine("Does", mode.source == .selection
                ? "Replaces the selected text using your spoken instruction"
                : (mode.commands.liveEdits ? "Dictation with spoken edits" : "Plain dictation"))
            summaryLine("Text goes", boundarySummary)
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

    @ViewBuilder private var recognitionDisclosure: some View {
        DisclosureSection(isExpanded: $recognitionExpanded) {
            DisclosureSummaryLabel(title: "Recognition and replacements", summary: recognitionSummary)
        } content: {
            Text("Add to this mode")
                .font(.subheadline.weight(.semibold))
            VocabularyComposer(
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
                onRemove: removeWord)
            if mode.dictionary.words.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            }

            Text("Automatic replacements")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                .font(.caption).foregroundStyle(.secondary)
            ReplacementRows(
                rules: mode.replacements.rules,
                onRemove: removeReplacement(at:))
            if mode.replacements.rules.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            }

            if mode.source != .selection {
                Divider().padding(.vertical, 4)
                Toggle("Write numbers as digits", isOn: bind.commandsBinding(\.numbers))
                Text("Numbers are tidied on this Mac, before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

    // When a mode rewrites, the user must see exactly what leaves the Mac. Privacy and context are mutually
    // exclusive; the controls stay visible with the reason rather than disappearing.
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
                }
                SettingRow(
                    title: "Send text before the cursor",
                    help: "Shares a short, bounded excerpt of the text just before the insertion point as untrusted reference, so a rewrite can match the surrounding voice and tense. Native text fields only — best-effort (browsers expose nothing).",
                    dependencyReason: mode.commands.privacy ? "Off while best-effort redaction sends only the redacted dictation." : nil)
                {
                    Toggle("", isOn: bind.contextBinding(\.precedingText)).labelsHidden().disabled(mode.commands.privacy)
                }
                SettingRow(
                    title: "Hide recognizable sensitive text",
                    help: "Best-effort redaction replaces recognizable sensitive spans with tokens before the request, then restores them on this Mac. It is pattern matching: it can miss content, it turns all context off, and it does not make cloud use appropriate for every secret.",
                    dependencyReason: mode.commands.privacy ? "All context is off while this is on." : nil)
                {
                    Toggle("", isOn: privacyMode).labelsHidden()
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
