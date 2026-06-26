import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class ModesSettingsModel: ObservableObject {
    @Published private(set) var modes: [Mode] = []
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var fragmentIds: [String] = []
    @Published var selectedID: String?
    @Published var lastCreatedId: String?
    @Published private(set) var error: String?
    @Published private(set) var loadFailures: [ModeStore.LoadFailure] = []

    private let modesDir: URL
    private let supportDir: URL
    private let defaultModeId: () -> String
    private let onSetDefault: (String) -> Void

    init(
        modesDir: URL, supportDir: URL,
        defaultModeId: @escaping () -> String = { "" },
        onSetDefault: @escaping (String) -> Void = { _ in }
    ) {
        self.modesDir = modesDir
        self.supportDir = supportDir
        self.defaultModeId = defaultModeId
        self.onSetDefault = onSetDefault
        reload()
    }

    func isDefault(_ mode: Mode) -> Bool { mode.id == defaultModeId() }

    func makeDefault(_ mode: Mode) {
        onSetDefault(mode.id)
        objectWillChange.send()
    }

    func reload() {
        let result = ModeStore.load(in: modesDir, previous: modes)
        modes = result.modes
        loadFailures = result.failures
        connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        fragmentIds = loadFragmentIds()
        if selectedID == nil || !modes.contains(where: { $0.id == selectedID }) {
            selectedID = modes.first?.id
        }
        error = nil
    }

    func create() {
        let name = "New Mode"
        var mode = Mode(id: ModeStore.newID(for: name, existing: modes.map(\.id)), name: name)
        mode.trailing = .space
        mode.commands.liveEdits = true
        save(mode)
        selectedID = mode.id
        lastCreatedId = mode.id
    }

    func consumeCreated() { lastCreatedId = nil }

    func update(_ mode: Mode) {
        save(mode)
    }

    func delete(_ mode: Mode) {
        do {
            try ModeStore.delete(mode, from: modesDir)
            let wasDefault = mode.id == defaultModeId()
            modes.removeAll { $0.id == mode.id }
            selectedID = modes.first?.id
            // Default-mode delete guard (session-status follow-up): hand the default to a remaining
            // mode so settings.default_mode_id never dangles after the default is removed.
            if wasDefault, let next = modes.first { onSetDefault(next.id) }
            error = nil
        } catch {
            self.error = "Could not delete \(mode.name): \(error.localizedDescription)"
        }
    }

    var selected: Mode? {
        modes.first { $0.id == selectedID }
    }

    private var fragmentsDir: URL { supportDir.appendingPathComponent("fragments", isDirectory: true) }

    private func loadFragmentIds() -> [String] {
        FragmentStore.ids(in: fragmentsDir)
    }

    // Create (or resolve) a fragment file by name, refresh the list, and reveal it so the user can
    // fill in the instruction text. Returns the fragment id to add to the mode.
    func addFragmentFile(named name: String) -> String? {
        do {
            let id = try FragmentStore.createIfNeeded(name: name, in: fragmentsDir)
            fragmentIds = loadFragmentIds()
            error = nil
            NSWorkspace.shared.activateFileViewerSelecting(
                [fragmentsDir.appendingPathComponent("\(id).md")])
            return id
        } catch {
            self.error = "Could not create the instruction file: \(error.localizedDescription)"
            return nil
        }
    }

    func revealFragment(_ id: String) {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save(_ mode: Mode) {
        do {
            try ModeStore.write(mode, to: modesDir)
            if let index = modes.firstIndex(where: { $0.id == mode.id }) {
                modes[index] = mode
            } else {
                modes.append(mode)
            }
            error = nil
        } catch {
            self.error = "Could not save \(mode.name): \(error.localizedDescription)"
        }
    }
}

struct ModesSettingsView: View {
    @ObservedObject var model: ModesSettingsModel
    var brokenConnectionIds: Set<String> = []
    @EnvironmentObject private var recordingState: HotkeyRecordingState
    @State private var modePendingDelete: Mode?

    var body: some View {
        VStack(spacing: 0) {
            if !model.loadFailures.isEmpty {
                ModeLoadFailureBanner(failures: model.loadFailures)
                Divider()
            }
            paneBody
        }
    }

    private var paneBody: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.modes) { mode in
                    ModeSummaryRow(
                        mode: mode, isDefault: model.isDefault(mode),
                        connectionBroken: usesBrokenConnection(mode))
                        .tag(mode.id)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add Mode", systemImage: "plus", action: model.create)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .disabled(recordingState.isRecording)
            .frame(width: 240)

            Divider()

            Group {
                if let mode = model.selected {
                    ModeEditorView(
                        mode: mode, allModes: model.modes,
                        connections: model.connections, fragmentIds: model.fragmentIds,
                        isDefault: model.isDefault(mode),
                        autofocusName: model.lastCreatedId == mode.id,
                        onUpdate: model.update,
                        onMakeDefault: { model.makeDefault(mode) },
                        onAddFragmentFile: model.addFragmentFile(named:),
                        onRevealFragment: model.revealFragment,
                        onConsumeFocus: model.consumeCreated,
                        onDelete: { modePendingDelete = mode })
                        .id(mode.id)
                } else {
                    ContentUnavailableView(
                        "No modes", systemImage: "square.stack.3d.up",
                        description: Text("Create a mode to choose how KeyScribe handles a dictation."))
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
            let isDefault = modePendingDelete.map(model.isDefault) ?? false
            Text("\(modePendingDelete?.name ?? "This mode") and its configuration will be removed. This cannot be undone."
                + (isDefault ? " It is the default mode — another mode will become the default." : ""))
        }
    }

    private func usesBrokenConnection(_ mode: Mode) -> Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return brokenConnectionIds.contains(rewrite.connection)
    }
}

// Surfaces a malformed mode file instead of letting it vanish (it would silently change routing).
// A mode that still has a prior good copy keeps running on it; one that never loaded is skipped.
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
    let isDefault: Bool
    var connectionBroken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(mode.name)
                if isDefault {
                    Text("Default").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule()).foregroundStyle(.tint)
                }
                if !mode.enabled {
                    Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                }
                if connectionBroken {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .help("This mode's AI service failed its last connection test")
                }
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var values = [ModeSummary.whenRuns(mode, isDefault: isDefault)]
        values.append(mode.aiRewrite == nil ? "On this Mac" : "Cloud rewrite")
        if mode.excludeFromHistory { values.append("No history") }
        return values.joined(separator: " · ")
    }
}

// Shared user-facing summary phrasing (ui_components.md "Mode summary"): when a mode runs and
// where its text goes, in plain words — never bundle IDs or raw regex.
enum ModeSummary {
    static func whenRuns(_ mode: Mode, isDefault: Bool) -> String {
        if let key = mode.triggerKeys.first?.key,
           let descriptor = try? KeyDescriptor(parsing: key) {
            return "Triggered by \(triggerLabel(descriptor))"
        }
        if !mode.constraints.isEmpty {
            return "Routing rule"
        }
        if !mode.triggerPhrases.isEmpty { return "Spoken phrase" }
        if isDefault { return "Automatic default" }
        return "Pick from the menu"
    }

    static func triggerLabel(_ descriptor: KeyDescriptor) -> String {
        switch descriptor.canonical {
        case "fn": "Fn (Globe)"
        case "right_option": "Right Option"
        case "right_command": "Right Command"
        case "hyper": "Hyper"
        default: descriptor.canonical
        }
    }
}

private let customTriggerTag = "__custom__"

private struct ModeEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    let connections: [Connection]
    let fragmentIds: [String]
    let isDefault: Bool
    var autofocusName = false
    let onUpdate: (Mode) -> Void
    let onMakeDefault: () -> Void
    let onAddFragmentFile: (String) -> String?
    let onRevealFragment: (String) -> Void
    var onConsumeFocus: () -> Void = {}
    let onDelete: () -> Void
    @State private var routingExpanded = false
    @State private var advancedExpanded = false
    @State private var newPhrase = ""
    @State private var newURLPattern = ""
    @State private var newWindowTitlePattern = ""
    @State private var newFragmentName = ""
    @State private var capturingCustom = false
    @State private var manualBundleId = ""
    @State private var enteringBundleId = false
    @State private var runningApps: [InstalledApps.Info] = []

    var body: some View {
        Form {
            Section { summaryCard }

            Section("Basics") {
                CommittedTextField("Name", text: mode.name, autofocus: autofocusName) { value in
                    var updated = mode; updated.name = value; onUpdate(updated)
                }
                Toggle("Enabled", isOn: binding(\.enabled))
                if isDefault {
                    Label("Used automatically when no routing rule or spoken phrase applies",
                          systemImage: "star.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode.source != .selection {
                    Button("Use as default mode", action: onMakeDefault)
                    Text("The default mode runs whenever no routing rule, shortcut, or spoken phrase selects another mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            whenUsedSection
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
                    help: "Interprets spoken commands like \u{201C}delete that\u{201D} or \u{201C}new line\u{201D} as edits to the text instead of typing them literally. Turn it off if you dictate prose that uses those words verbatim.")
                {
                    Toggle("", isOn: commandsBinding(\.liveEdits)).labelsHidden()
                }
                if mode.source != .selection {
                    Toggle("Write numbers as digits", isOn: commandsBinding(\.numbers))
                    Toggle("Prefer dictionary words", isOn: commandsBinding(\.fuzzyCorrection))
                    Text("These tidy the transcript on this Mac, before any AI rewrite.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            dictionarySection
            improveWithAISection
            dataSentWithAISection

            Section("Result handling") {
                SettingRow(
                    title: "How text is inserted",
                    result: insertionLabel,
                    help: "Paste is recommended: it inserts the finished dictation atomically (one ⌘Z undoes it) and works in the widest range of apps. Insert and Type place text key-by-key and need Accessibility permission; some apps reject them.",
                    dependencyReason: accessibilityMissingForInsertion
                        ? "\(insertionLabel) needs Accessibility permission, which isn't granted. Without it this method can silently fail — grant access or use Paste."
                        : nil)
                {
                    Picker("", selection: binding(\.insertion)) {
                        Text("Paste").tag(Mode.Insertion.paste)
                        Text("Insert").tag(Mode.Insertion.insert)
                        Text("Type").tag(Mode.Insertion.type)
                    }
                    .labelsHidden().fixedSize()
                }
                if accessibilityMissingForInsertion {
                    Button("Open Accessibility Settings") { Permissions.openSettings(.accessibility) }
                        .controlSize(.small)
                }
                SettingRow(
                    title: "End with",
                    help: "Appends a space or line break to the end of every dictation. It is part of the inserted text, so one ⌘Z still undoes the whole thing.")
                {
                    Picker("", selection: binding(\.trailing)) {
                        Text("Nothing").tag(Mode.Trailing.none)
                        Text("Space").tag(Mode.Trailing.space)
                        Text("Line break").tag(Mode.Trailing.newline)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow(
                    title: "Send after inserting",
                    help: "After inserting, sends a keystroke to submit — Return sends in most chat and prompt boxes, ⇧Return adds a soft line break, ⌘Return sends in Slack and similar. Only fires when the text actually reached the target (never on a clipboard fallback). Leave on \u{201C}Nothing\u{201D} to avoid sending half-finished messages.",
                    dependencyReason: mode.submit != .none && mode.source == .selection
                        ? "This mode replaces a selection, so a send keystroke usually isn't what you want here."
                        : nil)
                {
                    Picker("", selection: binding(\.submit)) {
                        Text("Nothing").tag(Mode.Submit.none)
                        Text("Return").tag(Mode.Submit.return)
                        Text("⇧Return").tag(Mode.Submit.shiftReturn)
                        Text("⌘Return").tag(Mode.Submit.cmdReturn)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, this mode's dictations are never written to local history — useful for sensitive work. Other modes still record per your History setting.")
                {
                    Toggle("", isOn: binding(\.excludeFromHistory)).labelsHidden()
                }
            }

            advancedSection

            Section {
                Button("Delete Mode", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear { if autofocusName { onConsumeFocus() } }
    }

    private var accessibilityMissingForInsertion: Bool {
        (mode.insertion == .insert || mode.insertion == .type)
            && Permissions.accessibilityStatus() != .granted
    }

    private var insertionLabel: String {
        switch mode.insertion {
        case .paste: "Paste"
        case .insert: "Insert"
        case .type: "Type"
        }
    }

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryLine("When", ModeSummary.whenRuns(mode, isDefault: isDefault))
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
        let name = connections.first { $0.id == rewrite.connection }?.name ?? "an AI service"
        let redaction = mode.commands.privacy ? ", best-effort redaction on" : ""
        return "Cloud rewrite via \(name)\(redaction)"
    }

    @ViewBuilder private var whenUsedSection: some View {
        Section("When this mode is used") {
            // The Mode shortcut row holds either the menu or, for a custom chord, the recorder itself —
            // no separate "Shortcut" row. Choosing "Custom shortcut…" arms it in place immediately;
            // Esc or clearing reverts to the menu. (autostart only when freshly entering custom.)
            if isCustom {
                LabeledContent("Start this mode with") {
                    HotkeyRecorder(
                        key: triggerKey, autostart: capturingCustom,
                        onCancel: { capturingCustom = false })
                }
            } else {
                Picker("Start this mode with", selection: triggerSelection) {
                    Text("No mode shortcut").tag("")
                    Text("Fn (Globe)").tag("fn")
                    Text("Right Option").tag("right_option")
                    Text("Right Command").tag("right_command")
                    Text("Custom shortcut…").tag(customTriggerTag)
                }
            }
            Picker("How the shortcut works", selection: pressStyle) {
                Text("Hold or tap").tag("hold-or-tap")
                Text("Hold only").tag("hold-only")
                Text("Tap to toggle").tag("tap-to-toggle")
            }
            .disabled(mode.triggerKeys.isEmpty)
            if let conflict = triggerConflict {
                Label("Also used by \(conflict.modeName) in an overlapping context. When both could apply, the more specific mode wins, then the one listed first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Use Fn, a keyboard shortcut, or an extra mouse button to start this mode directly. Bound mouse buttons are used by KeyScribe while it runs, so they won’t also go Back or Forward in other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureSection("Advanced routing", isExpanded: $routingExpanded) {
                Text("Limit by app, URL, or window title")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(mode.constraints.indices, id: \.self) { index in
                    HStack {
                        constraintLabel(mode.constraints[index])
                        Spacer()
                        Button("Remove", role: .destructive) { removeConstraint(at: index) }
                    }
                }
                HStack {
                    Menu("Add app rule") {
                        ForEach(runningApps) { app in
                            Button(app.name) { addAppConstraint(app.bundleId) }
                        }
                        Divider()
                        Button("Choose from Applications…") {
                            if let app = InstalledApps.chooseFromApplications() { addAppConstraint(app.bundleId) }
                        }
                        Button("Enter Bundle ID…") { enteringBundleId = true }
                    }
                    .fixedSize()
                    .onAppear { if runningApps.isEmpty { runningApps = InstalledApps.running() } }
                    Spacer()
                }
                if enteringBundleId {
                    HStack {
                        TextField("Bundle ID, e.g. com.apple.Safari", text: $manualBundleId)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitManualBundleId)
                        Button("Add", action: commitManualBundleId)
                            .disabled(manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    TextField("URL regex, e.g. github\\.com", text: $newURLPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitURLConstraint)
                    Button("Add", action: commitURLConstraint)
                        .disabled(newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    TextField("Window title regex, e.g. (?i)pull request", text: $newWindowTitlePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitWindowTitleConstraint)
                    Button("Add", action: commitWindowTitleConstraint)
                        .disabled(newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Choose by spoken phrase")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(mode.triggerPhrases, id: \.self) { phrase in
                    HStack {
                        Text(phrase).font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) { removePhrase(phrase) }
                    }
                }
                HStack {
                    TextField("Trailing phrase, e.g. as a note", text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitPhrase)
                    Button("Add", action: commitPhrase)
                        .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Routing rules choose a mode before recording. App rules match bundle IDs, URL and window title rules are regular expressions, and each is checked only when a mode uses it. URLs are local routing keys and are never sent to a rewrite provider. A spoken phrase said at the end can reroute the result after transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var dictionarySection: some View {
        Section("Add to Vocabulary") {
            VocabularyComposer(
                onAddWord: addWord,
                onAddReplacement: addReplacementRule)
            Text("Mode-only words and replacements apply on top of the global lists for this mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Words to Recognize") {
            SettingRow(
                title: "Use global dictionary",
                help: "Adds your global dictionary terms to this mode as recognition hints, on top of the mode-only words below. A dictionary term tells the model a word is valid — it does not force the word to appear, and an AI rewrite may still change it.")
            {
                Toggle("", isOn: dictionaryBinding(\.includeGlobal)).labelsHidden()
            }
            Text("Mode-only names, product terms, and jargon KeyScribe should recognize as written in this mode.")
                .font(.caption).foregroundStyle(.secondary)
            DictionaryRows(
                words: mode.dictionary.words,
                onRemove: removeWord)
        }
        Section("Automatic Replacements") {
            SettingRow(
                title: "Use global replacements",
                help: "Applies your global replacement rules in this mode, on top of the mode-only rules below. Replacements run on this Mac before any AI rewrite, so a rewrite can still change the replaced text.")
            {
                Toggle("", isOn: replacementsBinding(\.includeGlobal)).labelsHidden()
            }
            Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                .font(.caption).foregroundStyle(.secondary)
            ReplacementRows(
                rules: mode.replacements.rules,
                onRemove: removeReplacement(at:))
        }
    }

    @ViewBuilder private var improveWithAISection: some View {
        Section("Improve with AI") {
            if connections.isEmpty {
                Text("Add an AI service in Settings before a mode can rewrite the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SettingRow(
                    title: "AI service",
                    result: aiServiceLabel,
                    help: "When set, the transcript is sent to this AI service to be rewritten before it is inserted. Only an explicit AI service can run a rewrite; if it fails, the transcript is inserted without rewriting — your words are never lost.")
                {
                    Picker("", selection: rewriteSelection) {
                        Text("No cloud rewrite").tag("")
                        ForEach(connections) { connection in
                            Text(connection.name).tag(connection.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                if mode.aiRewrite != nil {
                    PromptEditor(title: "Writing instruction", text: mode.aiRewrite?.prompt ?? "") { value in
                        updateRewrite { $0.prompt = value }
                    }
                }
            }
        }
    }

    private var aiServiceLabel: String {
        guard let id = mode.aiRewrite?.connection,
              let name = connections.first(where: { $0.id == id })?.name else {
            return "No cloud rewrite"
        }
        return name
    }

    // ui_design.md §4.4 / review #7: when a mode rewrites, the user must be able to see exactly what
    // leaves the Mac. Privacy and context are mutually exclusive; the controls stay visible with the
    // reason rather than disappearing.
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
                    Toggle("", isOn: contextBinding(\.app)).labelsHidden().disabled(mode.commands.privacy)
                }
                SettingRow(
                    title: "Send visible window text",
                    help: "Shares a capped excerpt of the focused window's visible text as untrusted reference. It can include anything on screen, so leave it off for sensitive windows.",
                    dependencyReason: mode.commands.privacy ? "Off while best-effort redaction sends only the redacted dictation." : nil)
                {
                    Toggle("", isOn: contextBinding(\.visibleText)).labelsHidden().disabled(mode.commands.privacy)
                }
                SettingRow(
                    title: "Send text before the cursor",
                    help: "Shares a short, bounded excerpt of the text just before the insertion point as untrusted reference, so a rewrite can match the surrounding voice and tense. Native text fields only — best-effort (browsers expose nothing).",
                    dependencyReason: mode.commands.privacy ? "Off while best-effort redaction sends only the redacted dictation." : nil)
                {
                    Toggle("", isOn: contextBinding(\.precedingText)).labelsHidden().disabled(mode.commands.privacy)
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

    @ViewBuilder private var advancedSection: some View {
        Section {
            DisclosureSection("Advanced", isExpanded: $advancedExpanded) {
                if mode.aiRewrite != nil {
                    Text("Reusable writing instructions")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(mode.aiRewrite?.fragments ?? [], id: \.self) { fragment in
                        HStack {
                            Text(fragment).font(.callout)
                            Spacer()
                            Button { onRevealFragment(fragment) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless)
                                .help("Reveal this instruction's file in Finder to edit it.")
                            Button("Remove", role: .destructive) { removeFragment(fragment) }
                        }
                    }
                    HStack {
                        TextField("New instruction name, e.g. email-style", text: $newFragmentName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitNewFragment)
                        if !unusedFragmentIds.isEmpty {
                            Menu("Add existing") {
                                ForEach(unusedFragmentIds, id: \.self) { id in
                                    Button(id) { addFragment(id) }
                                }
                            }
                            .fixedSize()
                        }
                        Button("Create", action: commitNewFragment)
                            .disabled(newFragmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Each instruction is a prompt file appended after the writing instruction, in order. Creating one opens its file so you can write the instruction.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Reusable writing instructions become available once this mode uses an AI service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commitNewFragment() {
        let name = newFragmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let id = onAddFragmentFile(name) else { return }
        addFragment(id)
        newFragmentName = ""
    }

    private var unusedFragmentIds: [String] {
        let used = Set(mode.aiRewrite?.fragments ?? [])
        return fragmentIds.filter { !used.contains($0) }
    }

    @ViewBuilder private func constraintLabel(_ constraint: Mode.Constraint) -> some View {
        let parts = constraintParts(constraint)
        if let bundle = constraint.bundleId, parts.count == 1 {
            HStack(spacing: 6) {
                if let icon = InstalledApps.icon(forBundleId: bundle) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(InstalledApps.name(forBundleId: bundle) ?? bundle).font(.callout)
                Text(bundle).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(parts.joined(separator: " + ")).font(.callout)
        }
    }

    private func constraintParts(_ constraint: Mode.Constraint) -> [String] {
        var parts: [String] = []
        if let bundle = constraint.bundleId {
            let name = InstalledApps.name(forBundleId: bundle) ?? bundle
            parts.append("App: \(name)")
        }
        if let prefix = constraint.bundlePrefix { parts.append("App prefix: \(prefix)") }
        if let url = constraint.urlPattern { parts.append("URL regex: \(url)") }
        if let title = constraint.windowTitle { parts.append("Window title regex: \(title)") }
        return parts.isEmpty ? ["Empty routing rule"] : parts
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

    private func commitPhrase() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        if !mode.triggerPhrases.contains(phrase) {
            var updated = mode
            updated.triggerPhrases.append(phrase)
            onUpdate(updated)
        }
        newPhrase = ""
    }

    private func removePhrase(_ phrase: String) {
        var updated = mode
        updated.triggerPhrases.removeAll { $0 == phrase }
        onUpdate(updated)
    }

    private func addAppConstraint(_ bundleId: String) {
        guard !mode.constraints.contains(where: { $0.bundleId == bundleId }) else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: bundleId))
        onUpdate(updated)
    }

    private func commitManualBundleId() {
        let value = manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        addAppConstraint(value)
        manualBundleId = ""
        enteringBundleId = false
    }

    private func commitURLConstraint() {
        let value = newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: nil, urlPattern: value))
        onUpdate(updated)
        newURLPattern = ""
    }

    private func commitWindowTitleConstraint() {
        let value = newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = mode
        updated.constraints.append(.init(windowTitle: value))
        onUpdate(updated)
        newWindowTitlePattern = ""
    }

    private func removeConstraint(at index: Int) {
        guard mode.constraints.indices.contains(index) else { return }
        var updated = mode
        updated.constraints.remove(at: index)
        onUpdate(updated)
    }

    private func addFragment(_ id: String) {
        guard var rewrite = mode.aiRewrite, !rewrite.fragments.contains(id) else { return }
        rewrite.fragments.append(id)
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private func removeFragment(_ fragment: String) {
        guard var rewrite = mode.aiRewrite else { return }
        rewrite.fragments.removeAll { $0 == fragment }
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private func addReplacementRule(_ heard: String, _ replace: String, _ regex: Bool) {
        var set = ReplacementsSet(rules: mode.replacements.rules)
        if regex {
            set.rules.append(.init(heard: heard, replace: replace, regex: true))
        } else {
            set = set.addingLiteral(heard: heard, replace: replace)
        }
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

    private var triggerSelection: Binding<String> {
        Binding(
            get: {
                if capturingCustom { return customTriggerTag }
                let key = mode.triggerKeys.first?.key ?? ""
                guard !key.isEmpty else { return "" }
                if let descriptor = try? KeyDescriptor(parsing: key), case .named = descriptor {
                    return descriptor.canonical
                }
                return customTriggerTag
            },
            set: { selection in
                if selection == customTriggerTag {
                    capturingCustom = true
                } else {
                    capturingCustom = false
                    triggerKey.wrappedValue = selection
                }
            })
    }

    private var isCustom: Bool {
        if capturingCustom { return true }
        guard let descriptor = try? KeyDescriptor(parsing: mode.triggerKeys.first?.key ?? "") else { return false }
        if case .chord = descriptor { return true }
        if case .mouseButton = descriptor { return true }
        return false
    }

    private var triggerConflict: TriggerKeyConflict? {
        TriggerKeyConflicts.conflict(for: mode, in: allModes)
    }

    private var triggerKey: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.key ?? "" },
            set: { key in
                capturingCustom = false
                var updated = mode
                if key.isEmpty {
                    updated.triggerKeys = []
                } else {
                    let existing = mode.triggerKeys.first
                    updated.triggerKeys = [.init(
                        key: key,
                        pressStyle: existing?.pressStyle ?? "hold-or-tap",
                        tapThresholdMs: existing?.tapThresholdMs ?? 250)]
                }
                onUpdate(updated)
            })
    }

    private var pressStyle: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.pressStyle ?? "hold-or-tap" },
            set: { style in
                guard let existing = mode.triggerKeys.first else { return }
                var updated = mode
                updated.triggerKeys = [.init(
                    key: existing.key, pressStyle: style, tapThresholdMs: existing.tapThresholdMs)]
                onUpdate(updated)
            })
    }

    private func contextBinding(_ keyPath: WritableKeyPath<Mode.ContextOptIn, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.commands.privacy ? false : (mode.aiRewrite?.context[keyPath: keyPath] ?? false) },
            set: { value in
                guard var rewrite = mode.aiRewrite else { return }
                rewrite.context[keyPath: keyPath] = value
                var updated = mode
                updated.aiRewrite = rewrite
                onUpdate(updated)
            })
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

    private var rewriteSelection: Binding<String> {
        Binding(
            get: { mode.aiRewrite?.connection ?? "" },
            set: { id in
                if id.isEmpty {
                    disableRewrite()
                } else if mode.aiRewrite == nil {
                    var updated = mode
                    updated.aiRewrite = .init(
                        connection: id,
                        prompt: "Clean up grammar and punctuation. Keep my meaning and wording.")
                    onUpdate(updated)
                } else {
                    updateRewrite { $0.connection = id }
                }
            })
    }

    private var privacyMode: Binding<Bool> {
        Binding(get: { mode.commands.privacy }, set: { value in
            var updated = mode
            updated.commands.privacy = value
            onUpdate(updated)
        })
    }

    private func disableRewrite() {
        var updated = mode
        updated.aiRewrite = nil
        onUpdate(updated)
    }

    private func updateRewrite(_ update: (inout Mode.AIRewrite) -> Void) {
        guard var rewrite = mode.aiRewrite else { return }
        update(&rewrite)
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Mode, T>) -> Binding<T> {
        Binding(
            get: { mode[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

    private func commandsBinding(_ keyPath: WritableKeyPath<Mode.Commands, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.commands[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated.commands[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

    private func dictionaryBinding(_ keyPath: WritableKeyPath<Mode.ModeDictionary, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.dictionary[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated.dictionary[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

    private func replacementsBinding(_ keyPath: WritableKeyPath<Mode.ModeReplacements, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.replacements[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated.replacements[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

}
