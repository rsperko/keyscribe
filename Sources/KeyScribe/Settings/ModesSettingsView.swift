import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class ModesSettingsModel: ObservableObject {
    @Published private(set) var modes: [Mode] = []
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var fragmentIds: [String] = []
    @Published private(set) var fragmentNames: [String: String] = [:]
    @Published var selectedID: String?
    @Published var lastCreatedId: String?
    private var awaitingInitialName: String?
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
        awaitingInitialName = mode.id
    }

    func consumeCreated() { lastCreatedId = nil }

    // A freshly created mode's id is the slug of the placeholder "New Mode". The first time the user
    // gives it a real name, re-slug the id so the TOML filename matches the name instead of staying
    // "new-mode" (the id is the filename stem). Only the initial naming re-slugs; later renames keep
    // the file so external references stay stable.
    func update(_ mode: Mode) {
        if mode.id == awaitingInitialName {
            let newId = ModeStore.newID(for: mode.name, existing: modes.filter { $0.id != mode.id }.map(\.id))
            if newId != mode.id {
                awaitingInitialName = nil
                rename(mode, to: newId)
                return
            }
        }
        save(mode)
    }

    private func rename(_ mode: Mode, to newId: String) {
        let oldId = mode.id
        var renamed = mode
        renamed.id = newId
        do {
            try ModeStore.write(renamed, to: modesDir)
            try? ModeStore.delete(mode, from: modesDir)
            if let index = modes.firstIndex(where: { $0.id == oldId }) {
                modes[index] = renamed
            } else {
                modes.append(renamed)
            }
            if defaultModeId() == oldId { onSetDefault(newId) }
            if selectedID == oldId { selectedID = newId }
            if lastCreatedId == oldId { lastCreatedId = newId }
            error = nil
        } catch {
            self.error = "Could not save \(mode.name): \(error.localizedDescription)"
        }
    }

    func delete(_ mode: Mode) {
        do {
            try ModeStore.delete(mode, from: modesDir)
            if awaitingInitialName == mode.id { awaitingInitialName = nil }
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
        let ids = FragmentStore.ids(in: fragmentsDir)
        fragmentNames = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, FragmentStore.name(id: $0, in: fragmentsDir) ?? $0)
        })
        return ids
    }

    // Create (or resolve) a fragment file by name and refresh the list. Returns the fragment id to
    // add to the mode; the caller opens it in the in-app editor to fill in the instruction text.
    func addFragmentFile(named name: String) -> String? {
        do {
            let id = try FragmentStore.createIfNeeded(name: name, in: fragmentsDir)
            fragmentIds = loadFragmentIds()
            error = nil
            return id
        } catch {
            self.error = "Could not create the instruction file: \(error.localizedDescription)"
            return nil
        }
    }

    func fragmentBody(_ id: String) -> String {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return FragmentStore.body(ofFile: content)
    }

    func saveFragmentBody(_ id: String, _ body: String) {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        do {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try FragmentStore.replacingBody(inFile: content, with: body)
                .write(to: url, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "Could not save the instruction: \(error.localizedDescription)"
        }
    }

    func revealFragment(_ id: String) {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Closing the editor on an empty instruction discards it: detach from the editing mode and, when
    // no other mode still references it, delete the file. So an instruction created but never written
    // never persists — an empty one is not a saveable instruction.
    func closeFragment(_ id: String, fromMode modeId: String) {
        guard fragmentBody(id).isEmpty else { return }
        if var mode = modes.first(where: { $0.id == modeId }),
           var rewrite = mode.aiRewrite, rewrite.fragments.contains(id) {
            rewrite.fragments.removeAll { $0 == id }
            mode.aiRewrite = rewrite
            save(mode)
        }
        let stillUsed = modes.contains { $0.aiRewrite?.fragments.contains(id) == true }
        if !stillUsed {
            try? FileManager.default.removeItem(at: fragmentsDir.appendingPathComponent("\(id).md"))
            fragmentIds = loadFragmentIds()
        }
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
                        issue: issue(for: mode))
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
                        fragmentNames: model.fragmentNames,
                        isDefault: model.isDefault(mode),
                        autofocusName: model.lastCreatedId == mode.id,
                        onUpdate: model.update,
                        onMakeDefault: { model.makeDefault(mode) },
                        onAddFragmentFile: model.addFragmentFile(named:),
                        onLoadFragmentBody: model.fragmentBody,
                        onSaveFragmentBody: model.saveFragmentBody,
                        onCloseFragment: model.closeFragment(_:fromMode:),
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
    var issue: ModeSummaryIssue?

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
                    Text(mode.seedId == nil ? "Disabled" : "Disabled starter")
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
        var values = [ModeSummary.whenRuns(mode, isDefault: isDefault)]
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
        case "hyper": "⌃⌥⇧⌘"
        default: descriptor.displayString
        }
    }
}

private let customTriggerTag = "__custom__"

private struct ModeEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    let connections: [Connection]
    let fragmentIds: [String]
    let fragmentNames: [String: String]
    let isDefault: Bool
    var autofocusName = false
    let onUpdate: (Mode) -> Void
    let onMakeDefault: () -> Void
    let onAddFragmentFile: (String) -> String?
    let onLoadFragmentBody: (String) -> String
    let onSaveFragmentBody: (String, String) -> Void
    let onCloseFragment: (String, String) -> Void
    let onRevealFragment: (String) -> Void
    var onConsumeFocus: () -> Void = {}
    let onDelete: () -> Void
    @State private var routingExpanded = false
    @State private var recognitionExpanded = false
    @State private var newPhrase = ""
    @State private var newURLPattern = ""
    @State private var newWindowTitlePattern = ""
    @State private var newFragmentName = ""
    @State private var editingFragment: String?
    @State private var creatingFragment = false
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
                    help: "Turns phrases you say into edits: \u{201C}new line\u{201D}, \u{201C}line break\u{201D}, \u{201C}new paragraph\u{201D}, \u{201C}scratch that\u{201D}, \u{201C}strike that\u{201D}, \u{201C}tab key\u{201D}, \u{201C}insert tab\u{201D}, and \u{201C}begin verbatim\u{201D}/\u{201C}end verbatim\u{201D}.")
                {
                    Toggle("", isOn: commandsBinding(\.liveEdits)).labelsHidden()
                }
                recognitionDisclosure
            }
            improveWithAISection
            dataSentWithAISection

            Section("Result handling") {
                nonPasteInsertionNotice
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "When on, this mode's dictations are never written to local history — useful for sensitive work. Other modes still record per your History setting.")
                {
                    Toggle("", isOn: binding(\.excludeFromHistory)).labelsHidden()
                }
                finishingControls
            }

            Section {
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
        guard !rewrite.connection.isEmpty else { return "Needs AI service" }
        guard let name = connections.first(where: { $0.id == rewrite.connection })?.name else {
            return "AI service missing"
        }
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
            DisclosureSection(isExpanded: $routingExpanded) {
                disclosureLabel("Advanced routing", routingSummary)
            } content: {
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

    private var routingSummary: String {
        if triggerConflict != nil { return "Shortcut conflict" }
        let ruleCount = mode.constraints.count
        let phraseCount = mode.triggerPhrases.count
        if ruleCount == 0 && phraseCount == 0 { return "No app rules or spoken phrases" }
        var parts: [String] = []
        if ruleCount > 0 { parts.append("\(ruleCount) rule\(ruleCount == 1 ? "" : "s")") }
        if phraseCount > 0 { parts.append("\(phraseCount) spoken phrase\(phraseCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var recognitionDisclosure: some View {
        DisclosureSection(isExpanded: $recognitionExpanded) {
            disclosureLabel("Recognition and replacements", recognitionSummary)
        } content: {
            VocabularyComposer(
                onAddWord: addWord,
                onAddReplacement: addReplacementRule)
            Text("Mode-only words and replacements apply on top of the global lists for this mode.")
                .font(.caption).foregroundStyle(.secondary)

            if mode.source != .selection {
                Toggle("Write numbers as digits", isOn: commandsBinding(\.numbers))
                Text("Numbers are tidied on this Mac, before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
                fuzzyCorrectionNotice
            }

            Text("Mode-only names, product terms, and jargon KeyScribe should recognize as written in this mode.")
                .font(.caption).foregroundStyle(.secondary)
            DictionaryRows(
                words: mode.dictionary.words,
                onRemove: removeWord)

            Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                .font(.caption).foregroundStyle(.secondary)
            ReplacementRows(
                rules: mode.replacements.rules,
                onRemove: removeReplacement(at:))
        }
    }

    @ViewBuilder private var fuzzyCorrectionNotice: some View {
        if mode.commands.fuzzyCorrection {
            Label("This mode corrects close matches to vocabulary from its TOML file.",
                  systemImage: "text.magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recognitionSummary: String {
        var parts: [String] = []
        if mode.source != .selection, mode.commands.numbers { parts.append("Numbers as digits") }
        if mode.source != .selection, mode.commands.fuzzyCorrection { parts.append("TOML vocabulary correction") }
        let wordCount = mode.dictionary.words.count
        let replacementCount = mode.replacements.rules.count
        if wordCount > 0 { parts.append("\(wordCount) word\(wordCount == 1 ? "" : "s")") }
        if replacementCount > 0 { parts.append("\(replacementCount) replacement\(replacementCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "No mode-only words or replacements" : parts.joined(separator: ", ")
    }

    @ViewBuilder private var improveWithAISection: some View {
        Section("Improve with AI") {
            if connections.isEmpty {
                if let aiServiceIssueText {
                    Label(aiServiceIssueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Add an AI service in Settings before a mode can rewrite the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let aiServiceIssueText {
                    Label(aiServiceIssueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
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
                    PromptEditor(
                        title: "Writing instruction",
                        placeholder: "Describe how the AI should rewrite your dictation\u{2026}",
                        text: mode.aiRewrite?.prompt ?? ""
                    ) { value in
                        updateRewrite { $0.prompt = value }
                    }
                    reusableInstructions
                }
            }
        }
    }

    @ViewBuilder private var reusableInstructions: some View {
        let attached = mode.aiRewrite?.fragments ?? []
        if attached.isEmpty {
            addInstructionMenu
            Text("Reusable writing instructions are saved snippets appended to this mode's prompt and shared across modes \u{2014} a \u{201C}my voice\u{201D} style guide, a standard sign-off, a glossary of names to spell right, or tone rules like \u{201C}keep it terse.\u{201D} Add one to reuse it across modes.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Reusable writing instructions")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(attached, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Text(fragmentName(id)).font(.callout)
                    Spacer()
                    Button("Edit") { editingFragment = id }
                        .buttonStyle(.borderless)
                        .popover(isPresented: Binding(
                            get: { editingFragment == id },
                            set: { if !$0 { closeFragmentEditor(id) } })) {
                            fragmentEditor(id)
                        }
                    Button("Remove", role: .destructive) { removeFragment(id) }
                        .buttonStyle(.borderless)
                }
            }
            .onMove(perform: moveFragment)
            addInstructionMenu
            Text("Each is appended after the writing instruction, in order. Instructions are shared, so editing one changes it for every mode that uses it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var finishingControls: some View {
        SettingRow(
            title: "Trim trailing punctuation",
            help: "Removes a final . ! or ? (and any trailing spaces) from the result before it is inserted. Useful for command, identifier, or subject-line modes that should not end in sentence punctuation. Runs before \u{201C}End with\u{201D} adds its space or line break.")
        {
            Toggle("", isOn: binding(\.trimTrailingPunctuation)).labelsHidden()
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
        nonDefaultSubmitNotice
    }

    @ViewBuilder private var nonDefaultSubmitNotice: some View {
        if mode.submit != .none {
            Label("This mode sends \(submitLabel) after inserting, configured in its TOML file.",
                  systemImage: "return")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func disclosureLabel(_ title: String, _ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary).font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder private var addInstructionMenu: some View {
        Menu {
            if !unusedFragmentIds.isEmpty {
                ForEach(unusedFragmentIds, id: \.self) { id in
                    Button(fragmentName(id)) { addFragment(id) }
                }
                Divider()
            }
            Button { creatingFragment = true } label: {
                Label("New instruction…", systemImage: "plus")
            }
        } label: {
            Label("Add instruction", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("New reusable instruction", isPresented: $creatingFragment) {
            TextField("Name, e.g. Email style", text: $newFragmentName)
            Button("Create", action: commitNewFragment)
            Button("Cancel", role: .cancel) { newFragmentName = "" }
        } message: {
            Text("Creates a reusable instruction you can edit here and attach to any mode.")
        }
    }

    @ViewBuilder private func fragmentEditor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fragmentName(id)).font(.headline)
            Label("Shared — editing this changes it for every mode that uses it.",
                  systemImage: "person.2")
                .font(.caption).foregroundStyle(.secondary)
            PromptEditor(
                title: fragmentName(id),
                placeholder: "Describe the reusable instruction\u{2026}",
                text: onLoadFragmentBody(id),
                commitsOnChange: true
            ) { body in
                onSaveFragmentBody(id, body)
            }
            HStack {
                Button { onRevealFragment(id) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.link).font(.caption)
                Spacer()
                Button("Done") { closeFragmentEditor(id) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func fragmentName(_ id: String) -> String {
        let name = fragmentNames[id]
        return (name?.isEmpty == false) ? name! : id
    }

    private var aiServiceLabel: String {
        guard let id = mode.aiRewrite?.connection,
              !id.isEmpty else {
            if mode.aiRewrite != nil { return "Choose an AI service" }
            return "No cloud rewrite"
        }
        guard let name = connections.first(where: { $0.id == id })?.name else { return "Missing AI service" }
        return name
    }

    private var aiServiceIssueText: String? {
        guard mode.enabled, let rewrite = mode.aiRewrite else { return nil }
        if rewrite.connection.isEmpty { return "Choose an AI service for this enabled mode." }
        if !connections.contains(where: { $0.id == rewrite.connection }) {
            return "The selected AI service no longer exists."
        }
        return nil
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

    private func commitNewFragment() {
        let name = newFragmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFragmentName = ""
        guard !name.isEmpty, let id = onAddFragmentFile(name) else { return }
        addFragment(id)
        editingFragment = id
    }

    private func closeFragmentEditor(_ id: String) {
        guard editingFragment == id else { return }
        let modeId = mode.id
        editingFragment = nil
        // Tearing the popover down flushes the editor's pending edit via its onDisappear commit; let
        // that land before deciding whether the instruction is empty and should be discarded.
        Task { @MainActor in onCloseFragment(id, modeId) }
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

    private func moveFragment(from source: IndexSet, to destination: Int) {
        guard var rewrite = mode.aiRewrite else { return }
        rewrite.fragments.move(fromOffsets: source, toOffset: destination)
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

}
