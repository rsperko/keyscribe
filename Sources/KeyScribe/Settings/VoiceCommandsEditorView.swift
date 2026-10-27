import AppKit
import SwiftUI
import KeyScribeKit

struct VoiceCommandsEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    let onUpdate: (Mode) -> Void
    let onMoveShortcut: (Mode) -> Void
    @ObservedObject var model: VoiceCommandsSettingsModel
    var onEditVocabulary: () -> Void = {}
    @State private var editing: PlaceDraft?
    @State private var editingScript: ScriptDraft?
    @State private var editingShortcut: ShortcutDraft?
    @State private var tryText = ""
    @State private var pendingShortcut: Mode?
    @State private var actionPermissionsExpanded = false
    @State private var previewDetailsExpanded = false
    @State private var moreExamplesExpanded = false
    @State private var capturingTab: Task<Void, Never>?

    private var trigger: ModeTrigger { ModeTrigger(mode: mode, allModes: allModes, onUpdate: onUpdate) }

    var body: some View {
        Form {
            Section {
                PaneDetailHeader(
                    systemImage: "arrow.right.circle",
                    title: mode.name,
                    subtitle: ModeSummary.whenRuns(mode),
                    badges: {
                        PaneBadge("Built in")
                        PaneBadge("Experimental")
                    })
            }

            Section("Start with a shortcut") {
                ModeTriggerRow(mode: mode, onUpdate: updateShortcut, label: "Start shortcut")
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                if let clash = VoiceCommandTriggers.clash(for: mode, in: trigger.allModes) {
                    IssueText("\(clash.name) also uses this shortcut, so it does not start \(mode.name). Choose one no other mode uses, or move it here.")
                    Button("Move Shortcut to \(mode.name)\u{2026}") { onMoveShortcut(mode) }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.moveShortcut)
                } else {
                    TriggerConflictLabel(conflict: trigger.conflict, mode: mode)
                }
                ExtraTriggersNote(mode: mode)
                if trigger.usesMouseShortcut {
                    Text("While this shortcut is assigned, the mouse button won’t also go Back or Forward in other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("What you can say") {
                ForEach(Self.examples(findsInApps: model.findsInApps), id: \.phrase) { example in
                    phraseRow(example.phrase, example.meaning)
                }
                DisclosureSection(isExpanded: $moreExamplesExpanded) {
                    DisclosureSummaryLabel(title: "More examples", summary: "Saved commands, scripts and shortcuts, and choosing from a list")
                } content: {
                    phraseRow("Your commands", "Say the name of a command you saved below, such as \u{201C}web hooks\u{201D}. If it takes words, say them after the name: \u{201C}note buy milk\u{201D}.")
                    ForEach(VoiceCommandPhrase.allCases, id: \.self) { phrase in
                        phraseRow(Self.label(for: phrase), Self.explanation(for: phrase, findsInApps: model.findsInApps))
                    }
                    Text("If more than one thing matches, choose from the list that appears. Click a choice, press its number, or use any shortcut and say its number. Press Esc or say \u{201C}cancel\u{201D} to dismiss it. If nothing matches, \(Branding.appName) tells you instead of typing your words.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.moreExamples)
            }

            trySection

            commandsSection

            Section("Recognition and replacements") {
                SettingRow(
                    title: "Vocabulary",
                    result: VocabularyScopePicker.summary(for: mode),
                    help: ModeEditorView.vocabularyHelp(for: mode) + " Replacements apply before a command is read. Use them to correct a name or phrase that is often misheard.",
                    combinesAccessibilityChildren: false)
                {
                    Button("Edit Vocabulary…", action: onEditVocabulary)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.editVocabulary)
                }
            }

            Section("Result handling") {
                SettingRow(
                    title: "Do not save this mode in history",
                    help: "Keeps voice commands out of History. Otherwise, when History is on, it saves what you said, what ran (including any input), and any error message. Errors may include text from the script or shortcut.")
                {
                    Toggle("", isOn: Binding(
                        get: { mode.excludeFromHistory },
                        set: { var updated = mode; updated.excludeFromHistory = $0; onUpdate(updated) }))
                        .labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.excludeFromHistory)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .task { await model.loadBrowserChoices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.loadBrowserChoices() }
        }
        .onDisappear { capturingTab?.cancel() }
        .sheet(item: $editing) { draft in
            PlaceEditorSheet(draft: draft, model: model) { editing = nil }
        }
        .sheet(item: $editingScript) { draft in
            ScriptEditorSheet(draft: draft, model: model) { editingScript = nil }
        }
        .sheet(item: $editingShortcut) { draft in
            ShortcutEditorSheet(draft: draft, model: model) { editingShortcut = nil }
        }
        .alert(VoiceCommandNotices.Kind.apps.title, isPresented: Binding(
            get: { pendingShortcut != nil },
            set: { if !$0 { pendingShortcut = nil } }))
        {
            Button("Set Shortcut") {
                if let updated = pendingShortcut {
                    model.notices.acknowledge(.apps)
                    onUpdate(updated)
                }
                pendingShortcut = nil
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.appNoticeConfirm)
            Button("Cancel", role: .cancel) { pendingShortcut = nil }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.appNoticeCancel)
        } message: {
            Text(VoiceCommandNotices.Kind.apps.message)
        }
    }

    private func updateShortcut(_ updated: Mode) {
        if !updated.triggerKeys.isEmpty, model.notices.needsAcknowledgment(.apps),
           VoiceCommandTriggers.clash(for: updated, in: allModes) == nil {
            pendingShortcut = updated
        } else {
            onUpdate(updated)
        }
    }

    static func examples(findsInApps: Bool) -> [(phrase: String, meaning: String)] {
        let open = ("\u{201C}open Mail\u{201D}", "Switches to an app, window, or tab. Nothing to set up.")
        let inside = ("\u{201C}open Slack general\u{201D}", "Opens something inside an app, such as a channel, mailbox, or tab.")
        let back = ("\u{201C}go back\u{201D}", "Returns to where you were.")
        return findsInApps ? [open, inside, back] : [open, back]
    }

    private static func label(for phrase: VoiceCommandPhrase) -> String {
        phrase.words.map { phrase == .goBack ? "\u{201C}\($0)\u{201D}" : "\u{201C}\($0) …\u{201D}" }.joined(separator: "  ")
    }

    static func explanation(for phrase: VoiceCommandPhrase, findsInApps: Bool) -> String {
        switch phrase {
        case .focus where findsInApps:
            "Switch to an app, a saved app or link, or an open window or browser tab by name. App names work without setup. Add what you want in the app after its name to find it: \u{201C}open Slack general\u{201D} opens a channel, \u{201C}open Chrome github\u{201D} a tab."
        case .focus:
            "Switch to an app, a saved app or link, or an open window or browser tab by name. App names work without setup."
        case .run:
            "Run a saved script or shortcut. Saying its name alone works too."
        case .goBack:
            "Return to the app or window you left. Say it again to switch back."
        }
    }

    private func phraseRow(_ phrase: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase)
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var commandsSection: some View {
        Section("Commands") {
            Text("Save a name of your own for an app or a link, or a script or shortcut to run, then say that name.")
                .font(.callout).foregroundStyle(.secondary)
            addMenu
            if model.commands.isEmpty {
                Text("No saved commands yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.commands, id: \.id) { command in
                switch command {
                case .place(let place): placeRow(place)
                case .script(let script): actionRow(script)
                }
            }
            VoiceCommandNoticeRow(kind: .apps, needsAcknowledgment: false)
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.appNotice)
            DisclosureSection(isExpanded: $actionPermissionsExpanded) {
                DisclosureSummaryLabel(
                    title: "Permissions and confirmations",
                    summary: "Some prompts appear on the first run; others can appear every time.")
            } content: {
                Text(VoiceCommandNotices.actionPermissions)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.actionPermissions)
        }
        .task(id: model.scripts.contains(where: \.isShortcut)) {
            if model.scripts.contains(where: \.isShortcut) { await model.loadShortcutChoices() }
        }
    }

    private func placeRow(_ place: VoiceCommandPlace) -> some View {
        HStack(alignment: .firstTextBaseline) {
            PlaceKindIcon(place: place)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                Text("Say: " + VoiceCommandExample.phrases(for: .place(place)).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(destination(place)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let unreachable = model.namesLostToReplacements(for: .place(place)).first {
                    IssueText(unreachable, severity: .advisory)
                }
            }
            Spacer()
            PaneBadge(place.isTabSearch ? "Tab search" : place.isAppLink ? "App link" : place.isWebPage ? "Web page" : "App")
            Button("Edit…") { edit(place: PlaceDraft(place)) }
                .accessibilityLabel("Edit place \(place.name)")
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeEdit(VoiceCommandText.key(place.name).replacingOccurrences(of: " ", with: "-")))
        }
    }

    private func actionRow(_ script: VoiceCommandScript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ActionKindIcon(isShortcut: script.isShortcut)
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                Text("Say: " + VoiceCommandExample.phrases(for: .script(script)).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                if let shortcut = script.shortcut {
                    Text(ShortcutDraft.description(shortcut)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if model.shortcutIsMissing(shortcut) {
                        IssueText("This shortcut is no longer in Shortcuts.", severity: .advisory)
                    }
                } else {
                    Text(script.commandLine(arguments: Array(script.run.dropFirst()))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let issue = VoiceCommandsSettingsModel.programIssue(script.program) {
                        IssueText(issue, severity: .advisory)
                    }
                }
                if let unreachable = model.namesLostToReplacements(for: .script(script)).first {
                    IssueText(unreachable, severity: .advisory)
                }
            }
            Spacer()
            PaneBadge(script.isShortcut ? "Shortcut" : "Script")
            Button("Edit\u{2026}") {
                if script.isShortcut { edit(shortcut: ShortcutDraft(script)) } else { edit(script: ScriptDraft(script)) }
            }
            .accessibilityLabel("Edit action \(script.name)")
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptEdit(VoiceCommandText.key(script.name).replacingOccurrences(of: " ", with: "-")))
        }
    }

    private func destination(_ place: VoiceCommandPlace) -> String {
        switch place.target {
        case .app(let bundleId): return model.appName(bundleId)
        case .url(let url):
            return place.browser.map { "\(url) in \(model.appName($0))" } ?? url
        case .tabSearch:
            return "Finds an open tab in " + (place.browser.map(model.appName) ?? "any browser")
        }
    }

    private var addMenu: some View {
        Menu("Add Command\u{2026}") {
            if let app = model.currentApp {
                Button("Open Current App (\(app.name))") {
                    edit(place: PlaceDraft(name: app.name, kind: .app, bundleId: app.bundleId))
                }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentApp)
                if model.isCheckingBrowsers {
                    Button("Checking browsers\u{2026}") {}
                        .disabled(true)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentTab)
                } else if model.canCaptureTab(of: app.bundleId) {
                    Button("Open Current Browser Tab") { captureTab(of: app) }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentTab)
                }
                Divider()
            }
            Button("Open an App\u{2026}") { edit(place: PlaceDraft(name: "", kind: .app)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addApp)
            Button("Open a Link\u{2026}") { edit(place: PlaceDraft(name: "", kind: .webPage)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addLink)
            Button("Run a Shortcut\u{2026}") { edit(shortcut: ShortcutDraft()) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addShortcut)
            Button("Run a Script\u{2026}") { edit(script: ScriptDraft()) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addScript)
            Divider()
            Button("Find a Browser Tab\u{2026}") { edit(place: PlaceDraft(name: "", kind: .tabSearch)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addTabSearch)
        }
        .fixedSize()
        .disabled(model.hasUnreadableFile)
        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCommand)
    }

    private func edit(place draft: PlaceDraft) {
        capturingTab?.cancel()
        editing = draft
    }

    private func edit(script draft: ScriptDraft) {
        capturingTab?.cancel()
        editingScript = draft
    }

    private func edit(shortcut draft: ShortcutDraft) {
        capturingTab?.cancel()
        editingShortcut = draft
    }

    private func captureTab(of app: VoiceCommandCatalog.App) {
        capturingTab?.cancel()
        capturingTab = Task {
            let tab = await model.currentTab(of: app)
            guard !Task.isCancelled, editing == nil, editingScript == nil, editingShortcut == nil else { return }
            if let tab {
                editing = PlaceDraft(
                    name: Self.suggestedName(title: tab.title, url: tab.url), kind: .webPage,
                    url: tab.url, browser: tab.browserBundleId)
            } else {
                var draft = PlaceDraft(name: "", kind: .webPage, browser: app.bundleId)
                draft.notice = "Could not read the current tab. Enter the web page address."
                editing = draft
            }
        }
    }

    static func suggestedName(title: String, url: String) -> String {
        let fromTitle = title.split(whereSeparator: { "-–—|·".contains($0) }).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !fromTitle.isEmpty, fromTitle.count <= 40 { return fromTitle }
        return URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
    }

    private var trySection: some View {
        Section("Preview a command") {
            Text("Type a command to see what would happen. Nothing opens or runs.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Type what you would say", text: $tryText, prompt: Text("switch to mail"))
                .onSubmit { model.tryIt(tryText) }
                .onChange(of: tryText) { _, value in model.tryIt(value) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.tryIt)
                .formFieldLabel("Type what you would say")
            if let result = model.tryResult, result.heard == tryText.trimmingCharacters(in: .whitespacesAndNewlines) {
                VStack(alignment: .leading, spacing: 2) {
                    if let readAs = result.readAs {
                        Text("Read as \u{201C}\(readAs)\u{201D}").font(.caption).foregroundStyle(.secondary)
                    }
                    if result.resolved {
                        Label(result.summary, systemImage: "arrow.right.circle").font(.callout)
                    } else if result.asksChoice {
                        Label(result.summary, systemImage: "list.number").font(.callout)
                    } else {
                        IssueText(result.summary, severity: .advisory, font: .callout)
                    }
                    if !result.detail.isEmpty {
                        Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureSection(isExpanded: $previewDetailsExpanded) {
                DisclosureSummaryLabel(title: "What the preview checks", summary: "May ask for browser access")
            } content: {
                Text("The preview checks your apps, places, and actions. Looking for an open window or browser tab reads its title; checking tabs also reads their addresses and may ask for permission to control your browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.previewDetails)
        }
    }
}

extension VoiceCommandPlace {
    var isWebPage: Bool {
        if case .url = target { return true }
        return false
    }

}

struct PlaceDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case app, webPage, tabSearch }

    let id = UUID()
    let commandId: String
    let originalName: String?
    var name: String
    var say: String
    let kind: Kind
    var bundleId: String
    var url: String
    var browser: String
    var notice: String?
    private var suggestion: String?

    init(name: String, kind: Kind, bundleId: String = "", url: String = "", browser: String? = nil) {
        commandId = VoiceCommandNaming.newId()
        originalName = nil
        self.name = name
        suggestion = name.isEmpty ? nil : name
        say = ""
        self.kind = kind
        self.bundleId = bundleId
        self.url = url
        self.browser = browser ?? ""
    }

    init(_ place: VoiceCommandPlace) {
        commandId = place.id
        originalName = place.name
        name = place.name
        say = place.say.joined(separator: ", ")
        switch place.target {
        case .app(let bundleId):
            kind = .app; self.bundleId = bundleId; url = ""
        case .url(let url):
            kind = .webPage; bundleId = ""; self.url = url
        case .tabSearch:
            kind = .tabSearch; bundleId = ""; url = ""
        }
        browser = place.browser ?? ""
    }

    mutating func suggest(_ suggested: String) {
        let current = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == suggestion else { return }
        name = suggested
        suggestion = suggested
    }

    mutating func choose(_ app: VoiceCommandCatalog.App) {
        bundleId = app.bundleId
        suggest(app.name)
    }


    var place: VoiceCommandPlace {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forms = say.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let target: VoiceCommandPlace.Target
        switch kind {
        case .app: target = .app(bundleId: bundleId)
        case .webPage: target = .url(url.trimmingCharacters(in: .whitespacesAndNewlines))
        case .tabSearch: target = .tabSearch
        }
        let takesBrowser = kind == .tabSearch || (kind == .webPage && !VoiceCommandPlace.isAppLink(url))
        let browserValue = takesBrowser && !browser.isEmpty ? browser : nil
        return VoiceCommandPlace(
            id: commandId, name: trimmedName, say: forms, target: target, browser: browserValue)
    }
}

private struct PlaceEditorSheet: View {
    @State var draft: PlaceDraft
    @ObservedObject var model: VoiceCommandsSettingsModel
    let onDone: () -> Void
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var enteringBundleID = false
    @State private var browserDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Form {
                whatShouldHappen
                Section("What will you say?") {
                    CommandPhraseFields(
                        name: $draft.name, say: $draft.say,
                        caption: draft.kind == .tabSearch ? "Say this name, then words from the tab\u{2019}s title."
                            : draft.kind == .app && model.findsInApps
                                ? "Say this name to open the app. Add more words to find a tab, channel, mailbox, or other item in it."
                            : "Say this name to open it.",
                        namePrompt: draft.kind == .tabSearch ? "tabs" : "What would you like to call it?",
                        sayPrompt: "Optional, such as inbox, email",
                        nameIssue: nameIssue,
                        advisories: model.conflicts(for: .place(draft.place)),
                        ids: .init(
                            name: AccessibilityID.Mode.VoiceCommands.placeName,
                            say: AccessibilityID.Mode.VoiceCommands.placeSay,
                            otherNames: AccessibilityID.Mode.VoiceCommands.placeOtherNames))
                }
                CommandPreviewSection(
                    example: canSave ? model.example(for: .place(draft.place)) : nil,
                    id: AccessibilityID.Mode.VoiceCommands.placeExample)
                Section { notice }
            }
            .formStyle(.grouped)
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (draft.kind == .app && draft.bundleId.isEmpty)
                || (draft.kind == .webPage && draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Text("Choose what should happen and enter a spoken name to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { IssueText(issue) }
            HStack {
                if draft.originalName != nil {
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeCancel)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSave)
                    Spacer()
                    PaneDeleteButton(title: "Delete Command") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeCancel)
                    Button("Add Command") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSave)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
        .task { await model.loadBrowserChoices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.loadBrowserChoices() }
        }
        .onChange(of: draft.url) { _, url in
            if let host = Self.host(url) {
                draft.suggest(host)
                draft.notice = nil
            }
        }
        .confirmationDialog("Delete \u{201C}\(draft.originalName ?? draft.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                issue = model.delete(id: draft.commandId)
                if issue == nil { onDone() }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this command and its other names. The app or web page stays where it is.")
        }
    }

    @ViewBuilder private var whatShouldHappen: some View {
        Section("What should happen?") {
            switch draft.kind {
            case .app:
                appRow
            case .webPage:
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Link", text: $draft.url, prompt: Text("https://example.com/inbox"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeURL)
                        .formFieldLabel("Link")
                    if let urlIssue { IssueText(urlIssue) }
                    if let notice = draft.notice { IssueText(notice, severity: .advisory) }
                    if isAppLink {
                        if let app = model.linkAppName(draft.url) {
                            Text("Opens this link in \(app). Open tabs are not checked.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            IssueText("No app on this Mac opens this link yet.", severity: .advisory)
                        }
                    } else {
                        Text("A web address switches to an open tab whose address starts with it, or opens the page. A link that opens an app, such as a chat channel link, opens in that app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isAppLink { browserChoice }
            case .tabSearch:
                Text("Say the name, then words from the tab\u{2019}s title or site, such as github. It switches to the open tab that best matches them; when several match equally, the frontmost one.")
                    .font(.caption).foregroundStyle(.secondary)
                browserChoice
            }
        }
    }

    private var title: String {
        guard draft.originalName == nil else { return "Edit Command" }
        switch draft.kind {
        case .app: return "Open an App"
        case .webPage: return "Open a Link"
        case .tabSearch: return "Find a Browser Tab"
        }
    }

    @ViewBuilder private var browserChoice: some View {
        Picker("Browser", selection: $draft.browser) {
            Text("Any browser").tag("")
            if !draft.browser.isEmpty, !model.browsers.contains(where: { $0.bundleId == draft.browser }) {
                Text(model.appName(draft.browser)).tag(draft.browser)
            }
            ForEach(model.browsers, id: \.bundleId) { app in
                Text(app.name).tag(app.bundleId)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeBrowser)
        if model.isCheckingBrowsers {
            Text("Checking browsers\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
        DisclosureSection(isExpanded: $browserDetailsExpanded) {
            DisclosureSummaryLabel(title: "Finding open tabs", summary: "May ask for permission to control your browser")
        } content: {
            Text("Reads the titles and addresses of open tabs in the selected browser. Any browser checks all running browsers that can list their tabs. This can include private windows. macOS may ask for permission the first time a browser is checked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeBrowserDetails)
    }

    private var notice: some View {
        VoiceCommandNoticeRow(kind: .places, needsAcknowledgment: false)
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeNotice)
    }

    private var appRow: some View {
        LabeledContent("App") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if draft.bundleId.isEmpty {
                        Text("None chosen").foregroundStyle(.secondary)
                    } else {
                        if let icon = InstalledApps.menuIcon(forBundleId: draft.bundleId) { Image(nsImage: icon) }
                        Text(model.appName(draft.bundleId))
                    }
                    AppChooserMenu(
                        title: draft.bundleId.isEmpty ? "Choose App" : "Change",
                        ids: .init(
                            menu: AccessibilityID.Mode.VoiceCommands.placeApp,
                            app: AccessibilityID.Mode.VoiceCommands.placeAppChoice,
                            chooseFromApplications: AccessibilityID.Mode.VoiceCommands.placeChooseFromApplications,
                            enterBundleID: AccessibilityID.Mode.VoiceCommands.placeEnterBundleID),
                        onChoose: { draft.choose(VoiceCommandCatalog.App(name: $0.name, bundleId: $0.bundleId)) },
                        onEnterBundleID: { enteringBundleID = true })
                }
                if enteringBundleID {
                    TextField("Bundle ID", text: $draft.bundleId, prompt: Text("com.apple.mail"))
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeBundleID)
                    if !draft.bundleId.isEmpty, let invalid = UserInputValidation.identifierIssue(draft.bundleId, required: true) {
                        IssueText(invalid.message)
                    }
                }
            }
        }
    }


    private var isAppLink: Bool { VoiceCommandPlace.isAppLink(draft.url) }

    private static func host(_ url: String) -> String? {
        guard UserInputValidation.endpointIssue(url) == nil,
              let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var nameIssue: String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let issue = UserInputValidation.nameIssue(name) { return issue.message }
        return model.nameTaken(name, except: draft.commandId) ? VoiceCommandsSettingsModel.nameTakenMessage : nil
    }

    private var urlIssue: String? {
        draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : VoiceCommandPlace.linkIssue(draft.url)
    }

    private var canSave: Bool { draft.place.issue == nil && nameIssue == nil }

    private func save() {
        issue = model.save(draft.place, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}

struct ScriptDraft: Identifiable, Equatable {
    let id = UUID()
    let commandId: String
    let originalName: String?
    var name: String
    var say: String
    var program: String
    var arguments: String

    init() {
        commandId = VoiceCommandNaming.newId()
        originalName = nil
        name = ""
        say = ""
        program = ""
        arguments = ""
        fixedArguments = nil
    }

    let fixedArguments: [String]?

    init(_ script: VoiceCommandScript) {
        commandId = script.id
        originalName = script.name
        name = script.name
        say = script.say.joined(separator: ", ")
        program = script.program
        let given = Array(script.run.dropFirst())
        arguments = given.joined(separator: "\n")
        fixedArguments = Self.lines(arguments) == given ? nil : given
    }

    var script: VoiceCommandScript {
        let forms = say.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return VoiceCommandScript(
            id: commandId, name: name.trimmingCharacters(in: .whitespacesAndNewlines), say: forms,
            run: [program.trimmingCharacters(in: .whitespacesAndNewlines)] + (fixedArguments ?? Self.lines(arguments)))
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

}

private struct ScriptEditorSheet: View {
    @State var draft: ScriptDraft
    @ObservedObject var model: VoiceCommandsSettingsModel
    let onDone: () -> Void
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var argumentDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == nil ? "Run a Script" : "Edit Command").font(.title2.bold())
            Form {
                if draft.originalName == nil {
                    Section { notice }
                }
                Section("What should happen?") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Program", text: $draft.program, prompt: Text("~/bin/deploy"))
                                .font(.body.monospaced())
                                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptProgram)
                            Button("Choose\u{2026}") { chooseProgram() }
                                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptChooseProgram)
                        }
                        .formFieldLabel("Program")
                        if let programIssue = VoiceCommandsSettingsModel.programIssue(draft.program) {
                            IssueText(programIssue, severity: .advisory)
                        }
                        Text("Choose an executable file or enter its full path. Shell commands such as pipes and redirects do not work here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("What will you say?") {
                    CommandPhraseFields(
                        name: $draft.name, say: $draft.say, caption: "Say this name to run the script.",
                        namePrompt: "deploy", sayPrompt: "ship, release", nameIssue: nil,
                        advisories: model.conflicts(for: .script(draft.script)),
                        ids: .init(
                            name: AccessibilityID.Mode.VoiceCommands.scriptName,
                            say: AccessibilityID.Mode.VoiceCommands.scriptSay,
                            otherNames: AccessibilityID.Mode.VoiceCommands.scriptOtherNames))
                }
                Section("Arguments (optional)") {
                    VStack(alignment: .leading, spacing: 4) {
                        if draft.fixedArguments != nil {
                            Text(draft.arguments).font(.body.monospaced()).textSelection(.enabled)
                            Text("These arguments end with an empty one, which this editor cannot show, so they are kept as they are. Change them in \(VoiceCommandStore.fileName).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextEditor(text: $draft.arguments)
                                .font(.body.monospaced())
                                .multilineTextAlignment(.leading)
                                .ghostText("--env\n\(VoiceCommandScript.textPlaceholder)", visible: draft.arguments.isEmpty)
                                .frame(minHeight: 72)
                                .padding(4)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                                .accessibilityLabel("Arguments")
                                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptArguments)
                            Text("One per line. \(VoiceCommandScript.textPlaceholder) is replaced by what you say after the name. Your script should treat those words as input, not as code to run.")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureSection(isExpanded: $argumentDetailsExpanded) {
                                DisclosureSummaryLabel(title: "How scripts run", summary: "Arguments, spoken input, and the script’s environment")
                            } content: {
                                Text("Each line is one argument, including blank lines between arguments. Spaces stay within that argument. \(VoiceCommandScript.textPlaceholder) requires words after the spoken name; without it, say only the name.\n\nThe file runs directly, without a shell or Terminal window. It uses \(Branding.appName)’s environment, so tools used by the script may need full paths or a PATH set inside the script.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptArgumentDetails)
                        }
                    }
                }
                CommandPreviewSection(
                    example: draft.script.issue == nil ? model.example(for: .script(draft.script)) : nil,
                    id: AccessibilityID.Mode.VoiceCommands.scriptExample)
                if draft.originalName != nil {
                    Section { notice }
                }
            }
            .formStyle(.grouped)
            if let validationIssue, !draft.name.isEmpty || !draft.program.isEmpty {
                IssueText(validationIssue)
            }
            if draft.name.isEmpty && draft.program.isEmpty {
                Text("Choose a file and enter a spoken name to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { IssueText(issue) }
            HStack {
                if draft.originalName != nil {
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptCancel)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptSave)
                    Spacer()
                    PaneDeleteButton(title: "Delete Command") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptCancel)
                    Button("Add Command") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptSave)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 620)
        .confirmationDialog("Delete \u{201C}\(draft.originalName ?? draft.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                issue = model.delete(id: draft.commandId)
                if issue == nil { onDone() }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saying its name will no longer run it. The program itself is not deleted.")
        }
    }

    private var notice: some View {
        VoiceCommandNoticeRow(kind: .scripts, needsAcknowledgment: draft.originalName == nil)
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptNotice)
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        draft.program = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private var validationIssue: String? {
        model.scriptIssue(draft.script)
    }

    private func save() {
        issue = model.saveScript(draft.script, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}

struct ActionKindIcon: View {
    static let shortcutsBundleId = "com.apple.shortcuts"
    let isShortcut: Bool

    var body: some View {
        Group {
            if isShortcut, let icon = InstalledApps.menuIcon(forBundleId: Self.shortcutsBundleId) {
                Image(nsImage: icon)
            } else {
                Image(systemName: isShortcut ? "square.stack.3d.up" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityLabel(isShortcut ? "Shortcut" : "Script")
    }
}

struct PlaceKindIcon: View {
    let place: VoiceCommandPlace

    private var appBundleId: String? {
        switch place.target {
        case .app(let bundleId): bundleId
        case .url, .tabSearch: place.browser
        }
    }

    var body: some View {
        Group {
            if let appBundleId, let icon = InstalledApps.menuIcon(forBundleId: appBundleId) {
                Image(nsImage: icon)
            } else {
                Image(systemName: place.isWebPage ? "globe" : "app.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ShortcutDraft: Identifiable, Equatable {
    let id = UUID()
    let commandId: String
    let originalName: String?
    var name: String
    var say: String
    var shortcut: VoiceCommandShortcut?
    var input: String
    private var suggestion: String?

    init() {
        commandId = VoiceCommandNaming.newId()
        originalName = nil
        name = ""
        say = ""
        shortcut = nil
        input = ""
    }

    init(_ script: VoiceCommandScript) {
        commandId = script.id
        originalName = script.name
        name = script.name
        say = script.say.joined(separator: ", ")
        shortcut = script.shortcut.map { VoiceCommandShortcut(name: $0.name, identifier: $0.identifier) }
        input = script.shortcut?.input ?? ""
    }

    mutating func choose(_ chosen: VoiceCommandShortcut) {
        shortcut = VoiceCommandShortcut(name: chosen.name, identifier: chosen.identifier)
        let current = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == suggestion else { return }
        name = chosen.name
        suggestion = chosen.name
    }

    var script: VoiceCommandScript {
        let forms = say.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceCommandScript(
            id: commandId, name: name.trimmingCharacters(in: .whitespacesAndNewlines), say: forms,
            shortcut: VoiceCommandShortcut(
                name: shortcut?.name ?? "", identifier: shortcut?.identifier,
                input: trimmedInput.isEmpty ? nil : trimmedInput))
    }

    static func description(_ shortcut: VoiceCommandShortcut) -> String {
        let input = shortcut.input.map { ", given \u{201C}\($0)\u{201D}" } ?? ""
        return "Shortcut \u{201C}\(shortcut.name)\u{201D}\(input)"
    }

}

private struct ShortcutEditorSheet: View {
    @State var draft: ShortcutDraft
    @ObservedObject var model: VoiceCommandsSettingsModel
    let onDone: () -> Void
    @State private var issue: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == nil ? "Run a Shortcut" : "Edit Command").font(.title2.bold())
            Form {
                if draft.originalName == nil {
                    Section { notice }
                }
                Section("What should happen?") {
                    shortcutRow
                }
                Section("What will you say?") {
                    CommandPhraseFields(
                        name: $draft.name, say: $draft.say, caption: "Say this name to run the shortcut.",
                        namePrompt: "What would you like to call it?", sayPrompt: "Optional, such as log, note",
                        nameIssue: nil,
                        advisories: model.conflicts(for: .script(draft.script)),
                        ids: .init(
                            name: AccessibilityID.Mode.VoiceCommands.shortcutName,
                            say: AccessibilityID.Mode.VoiceCommands.shortcutSay,
                            otherNames: AccessibilityID.Mode.VoiceCommands.shortcutOtherNames))
                }
                Section("Input (optional)") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Input", text: $draft.input, prompt: Text("Optional, such as \(VoiceCommandScript.textPlaceholder)"))
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutInput)
                            .formFieldLabel("Input")
                        Text("Leave empty for no input. Enter fixed text, or use \(VoiceCommandScript.textPlaceholder) for the words you say after the name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                CommandPreviewSection(
                    example: draft.script.issue == nil ? model.example(for: .script(draft.script)) : nil,
                    id: AccessibilityID.Mode.VoiceCommands.shortcutExample)
                Section {
                    Text("The shortcut may open an app or ask a question. If it is waiting, check for a dialog. Its final result appears in History when saving is enabled for this mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.originalName != nil {
                    Section { notice }
                }
            }
            .formStyle(.grouped)
            if let validationIssue, !draft.name.isEmpty || draft.shortcut != nil {
                IssueText(validationIssue)
            }
            if draft.name.isEmpty && draft.shortcut == nil {
                Text("Choose a shortcut and enter a spoken name to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { IssueText(issue) }
            HStack {
                if draft.originalName != nil {
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutCancel)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutSave)
                    Spacer()
                    PaneDeleteButton(title: "Delete Command") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutCancel)
                    Button("Add Command") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutSave)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
        .task { await model.loadShortcutChoices() }
        .confirmationDialog("Delete \u{201C}\(draft.originalName ?? draft.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                issue = model.delete(id: draft.commandId)
                if issue == nil { onDone() }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saying its name will no longer run it. The shortcut itself stays in Shortcuts.")
        }
    }

    private var notice: some View {
        VoiceCommandNoticeRow(kind: .shortcuts, needsAcknowledgment: draft.originalName == nil)
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutNotice)
    }

    private var shortcutRow: some View {
        LabeledContent("Shortcut") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if let shortcut = draft.shortcut {
                        ActionKindIcon(isShortcut: true)
                        Text(shortcut.name)
                    } else {
                        Text("None chosen").foregroundStyle(.secondary)
                    }
                    Menu(draft.shortcut == nil ? "Choose Shortcut" : "Change") {
                        switch model.shortcutChoices {
                        case .loading:
                            Text("Loading\u{2026}")
                        case .unavailable:
                            Text("Your shortcuts could not be listed")
                        case .loaded(let choices) where choices.isEmpty:
                            Text("No shortcuts yet")
                        case .loaded(let choices):
                            ForEach(choices, id: \.target) { choice in
                                Button(choice.name) { draft.choose(choice) }
                                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutOption(choice.target))
                            }
                        }
                        Divider()
                        Button("Refresh List") { Task { await model.loadShortcutChoices() } }
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutRefresh)
                        Button("Open Shortcuts\u{2026}") {
                            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ActionKindIcon.shortcutsBundleId) else { return }
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutOpenApp)
                    }
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutChoice)
                }
                switch model.shortcutChoices {
                case .unavailable:
                    IssueText("Could not load your shortcuts. Open Shortcuts, then choose Refresh List.", severity: .advisory)
                case .loaded(let choices) where choices.isEmpty:
                    Text("Create a shortcut in Shortcuts, then choose Refresh List.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if let shortcut = draft.shortcut, model.shortcutIsMissing(shortcut) {
                    IssueText("This shortcut is no longer in Shortcuts. Choose another.", severity: .advisory)
                }
            }
        }
    }

    private var validationIssue: String? {
        model.scriptIssue(draft.script)
    }

    private func save() {
        issue = model.saveScript(draft.script, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}

struct CommandPhraseFields: View {
    struct IDs {
        let name: String
        let say: String
        let otherNames: String
    }

    @Binding var name: String
    @Binding var say: String
    let caption: String
    let namePrompt: String
    let sayPrompt: String
    let nameIssue: String?
    let advisories: [String]
    let ids: IDs
    @State private var otherNamesExpanded = false

    private var sayIssue: String? {
        say.split(separator: ",").lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .compactMap { UserInputValidation.phraseIssue($0)?.message }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Spoken name", text: $name, prompt: Text(namePrompt))
                .accessibilityIdentifier(ids.name)
                .formFieldLabel("Spoken name")
            if let nameIssue { IssueText(nameIssue) }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        DisclosureSection(isExpanded: $otherNamesExpanded, hasError: sayIssue != nil, headerID: ids.otherNames) {
            DisclosureSummaryLabel(title: "Other names (optional)", summary: say.isEmpty ? "None" : say)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Other names", text: $say, prompt: Text(sayPrompt))
                    .accessibilityIdentifier(ids.say)
                    .formFieldLabel("Other names")
                if let sayIssue { IssueText(sayIssue) }
                Text("Separate names with commas. Each works the same way as the spoken name. Add one for a word that is often misheard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(advisories, id: \.self) { advisory in
            IssueText(advisory, severity: .advisory)
        }
    }
}

struct CommandPreviewSection: View {
    let example: VoiceCommandExample?
    let id: String

    var body: some View {
        if let example {
            if let conflict = example.conflict {
                Section("Preview") {
                    IssueText(conflict, severity: .advisory)
                        .accessibilityIdentifier(id)
                }
            } else if !example.result.isEmpty {
                Section("Preview") {
                    ExampleCard(heard: example.heard, result: example.result, resultLabel: "What happens")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(id)
                }
            }
        }
    }
}
