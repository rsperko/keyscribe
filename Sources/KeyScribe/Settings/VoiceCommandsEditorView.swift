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

            Section("How to start Voice Commands") {
                ModeTriggerRow(mode: mode, onUpdate: updateShortcut, label: "Shortcut")
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
                Text("Speech on this shortcut is never typed. If it isn’t a command \(Branding.appName) understands, nothing happens. Commands are recognized on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What it does") {
                ForEach(VoiceCommandPhrase.allCases, id: \.self) { phrase in
                    phraseRow(Self.label(for: phrase), Self.explanation(for: phrase))
                }
                SettingRow(
                    title: "Recognition and replacements",
                    result: VocabularyScopePicker.summary(for: mode),
                    help: ModeEditorView.vocabularyHelp(for: mode) + " They apply before \(Branding.appName) reads a command, so they can fix a name that keeps coming out wrong, or a misheard \u{201C}switch to\u{201D}.",
                    combinesAccessibilityChildren: false)
                {
                    Button("Edit Vocabulary…", action: onEditVocabulary)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.editVocabulary)
                }
            }

            trySection

            placesSection

            actionsSection

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

    private static func label(for phrase: VoiceCommandPhrase) -> String {
        phrase.words.map { phrase == .goBack ? "\u{201C}\($0)\u{201D}" : "\u{201C}\($0) …\u{201D}" }.joined(separator: "  ")
    }

    private static func explanation(for phrase: VoiceCommandPhrase) -> String {
        switch phrase {
        case .focus:
            "Brings an app or saved place to the front, opening it if needed. App names work without setup. Say \u{2018}switch to Budget\u{2019} to bring an open window named Budget forward."
        case .run:
            "Runs a script or shortcut below. Say its name after \u{201C}run\u{201D}, followed by any words it accepts."
        case .goBack:
            "Returns to the window or app you were using before your last switch by voice. Say it again to switch back."
        }
    }

    private func phraseRow(_ phrase: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase)
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var placesSection: some View {
        Section("Places") {
            addMenu
            if model.places.isEmpty {
                Text("No places yet. App names already work on their own — add a place to give an app a nickname, or to jump to a web page, using an open tab when there is one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.places, id: \.name) { place in
                placeRow(place)
            }
            VoiceCommandNoticeRow(kind: .apps, needsAcknowledgment: false)
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.appNotice)
        }
    }

    private func placeRow(_ place: VoiceCommandPlace) -> some View {
        HStack(alignment: .firstTextBaseline) {
            PlaceKindIcon(place: place)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                Text("Say: " + place.spokenExamples.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(destination(place)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            PaneBadge(place.isWebPage ? "Web page" : "App")
            Button("Edit…") { edit(place: PlaceDraft(place)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeEdit(VoiceCommandText.key(place.name).replacingOccurrences(of: " ", with: "-")))
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Menu("Add Action\u{2026}") {
                Button("Script\u{2026}") { edit(script: ScriptDraft()) }
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addScript)
                Button("Shortcut\u{2026}") { edit(shortcut: ShortcutDraft()) }
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addShortcut)
            }
            .fixedSize()
            .disabled(model.hasUnreadableFile)
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addAction)
            if model.scripts.isEmpty {
                Text("No actions yet. Add a script or macOS shortcut, then say \u{201C}run\u{201D} and its name. You can also pass it words you say after the name.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.scripts, id: \.name) { script in
                actionRow(script)
            }
        }
        .task(id: model.scripts.contains(where: \.isShortcut)) {
            if model.scripts.contains(where: \.isShortcut) { await model.loadShortcutChoices() }
        }
    }

    private func actionRow(_ script: VoiceCommandScript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ActionKindIcon(isShortcut: script.isShortcut)
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                Text("Say: " + script.spokenForms.map { form in
                    "\u{201C}run \(form)\(script.takesText ? " \u{2026}" : "")\u{201D}"
                }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                if let shortcut = script.shortcut {
                    Text(ShortcutDraft.description(shortcut)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if model.shortcutIsMissing(shortcut) {
                        IssueText("This shortcut is no longer in Shortcuts.", severity: .advisory)
                    }
                } else {
                    Text(script.run.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let issue = VoiceCommandsSettingsModel.programIssue(script.program) {
                        IssueText(issue, severity: .advisory)
                    }
                }
            }
            Spacer()
            PaneBadge(script.isShortcut ? "Shortcut" : "Script")
            Button("Edit\u{2026}") {
                if script.isShortcut { edit(shortcut: ShortcutDraft(script)) } else { edit(script: ScriptDraft(script)) }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptEdit(VoiceCommandText.key(script.name).replacingOccurrences(of: " ", with: "-")))
        }
    }

    private func destination(_ place: VoiceCommandPlace) -> String {
        switch place.target {
        case .app(let bundleId): return model.appName(bundleId)
        case .url(let url):
            return place.browser.map { "\(url) in \(model.appName($0))" } ?? url
        }
    }

    private var addMenu: some View {
        Menu("Add Place…") {
            if let app = model.currentApp {
                Button("Current App (\(app.name))") {
                    edit(place: PlaceDraft(name: app.name, kind: .app, bundleId: app.bundleId))
                }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentApp)
                if model.isCheckingBrowsers {
                    Button("Checking browsers\u{2026}") {}
                        .disabled(true)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentTab)
                } else if model.canCaptureTab(of: app.bundleId) {
                    Button("Current Browser Tab") { captureTab(of: app) }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentTab)
                }
                Divider()
            }
            Button("App…") { edit(place: PlaceDraft(name: "", kind: .app)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addApp)
            Button("Web Page…") { edit(place: PlaceDraft(name: "", kind: .webPage)) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addWebPage)
        }
        .fixedSize()
        .disabled(model.hasUnreadableFile)
        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addPlace)
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
        Section("Try it") {
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
            Text("Previews a command without opening anything or running an action. Checking open tabs reads their addresses and titles, and may ask to control your browser. A phrase no app or place matches reads the titles of open windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension VoiceCommandPlace {
    var isWebPage: Bool {
        if case .url = target { return true }
        return false
    }

    var spokenExamples: [String] {
        spokenForms.map { "\(isWebPage ? "open" : "switch to") \($0)" }
    }
}

struct PlaceDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case app, webPage }

    let id = UUID()
    let originalName: String?
    var name: String
    var say: String
    var kind: Kind
    var bundleId: String
    var url: String
    var browser: String
    var notice: String?
    private var suggestion: String?

    init(name: String, kind: Kind, bundleId: String = "", url: String = "", browser: String? = nil) {
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
        originalName = place.name
        name = place.name
        say = place.say.joined(separator: ", ")
        switch place.target {
        case .app(let bundleId):
            kind = .app; self.bundleId = bundleId; url = ""
        case .url(let url):
            kind = .webPage; bundleId = ""; self.url = url
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

    func example(destination: String) -> String? {
        let place = place
        guard !place.name.isEmpty, !destination.isEmpty else { return nil }
        let form = place.say.first ?? place.name
        return kind == .app
            ? "Say \u{201C}switch to \(form)\u{201D} to bring \(destination) to the front."
            : "Say \u{201C}open \(form)\u{201D} to go to \(destination)."
    }

    var place: VoiceCommandPlace {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forms = say.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let target: VoiceCommandPlace.Target = kind == .app
            ? .app(bundleId: bundleId)
            : .url(url.trimmingCharacters(in: .whitespacesAndNewlines))
        let browserValue = kind == .webPage && !browser.isEmpty ? browser : nil
        return VoiceCommandPlace(name: trimmedName, say: forms, target: target, browser: browserValue)
    }
}

private struct PlaceEditorSheet: View {
    @State var draft: PlaceDraft
    @ObservedObject var model: VoiceCommandsSettingsModel
    let onDone: () -> Void
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var enteringBundleID = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == nil ? "Add Place" : "Edit Place").font(.title2.bold())
            Form {
                VoiceCommandNoticeRow(kind: .places, needsAcknowledgment: draft.originalName == nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeNotice)
                Picker("Goes to", selection: $draft.kind) {
                    Text("An app").tag(PlaceDraft.Kind.app)
                    Text("A web page").tag(PlaceDraft.Kind.webPage)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeKind)
                if draft.kind == .app {
                    appRow
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Web page", text: $draft.url, prompt: Text("https://mail.google.com/"))
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeURL)
                            .formFieldLabel("Web page")
                        if let urlIssue { IssueText(urlIssue) }
                        if let notice = draft.notice { IssueText(notice, severity: .advisory) }
                        Text("An open tab whose address starts with this is brought to the front. With no such tab, the page opens.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    Text("Any browser looks through every running browser that can list its tabs, in all its windows, which can include private ones. Finding an open tab asks macOS for permission to control the browser the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $draft.name, prompt: Text("What would you like to call it?"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeName)
                        .formFieldLabel("Name")
                    if let nameIssue { IssueText(nameIssue) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Also say", text: $draft.say, prompt: Text("Optional, such as inbox, email"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSay)
                        .formFieldLabel("Also say")
                    if let sayIssue { IssueText(sayIssue) }
                    if let shared = model.sharedNameAdvisory(for: draft.place, replacing: draft.originalName) {
                        IssueText(shared, severity: .advisory)
                    }
                    Text("Other names for this place, separated by commas. Say any of them after \u{201C}switch to\u{201D} or \u{201C}open\u{201D}.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let example = draft.example(destination: destinationName) {
                Label(example, systemImage: "arrow.right.circle").font(.callout)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeExample)
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
                    PaneDeleteButton(title: "Delete Place") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeCancel)
                    Button("Add Place") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSave)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
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
                if let name = draft.originalName {
                    issue = model.delete(named: name)
                    if issue == nil { onDone() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saying its name will no longer go there. Apps themselves are not affected.")
        }
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
                }
            }
        }
    }

    private var destinationName: String {
        switch draft.kind {
        case .app: draft.bundleId.isEmpty ? "" : model.appName(draft.bundleId)
        case .webPage: Self.host(draft.url) ?? ""
        }
    }

    private static func host(_ url: String) -> String? {
        guard UserInputValidation.endpointIssue(url) == nil,
              let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var nameIssue: String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let issue = UserInputValidation.nameIssue(name) { return issue.message }
        return model.nameTaken(name, except: draft.originalName.map(VoiceCommandText.key))
            ? "Another place or action already uses this name." : nil
    }

    private var sayIssue: String? {
        draft.place.say.lazy.compactMap { UserInputValidation.phraseIssue($0)?.message }.first
    }

    private var urlIssue: String? {
        draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : UserInputValidation.endpointIssue(draft.url)?.message
    }

    private var canSave: Bool { draft.place.issue == nil && nameIssue == nil }

    private func save() {
        issue = model.save(draft.place, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}

struct ScriptDraft: Identifiable, Equatable {
    let id = UUID()
    let originalName: String?
    var name: String
    var say: String
    var program: String
    var arguments: String

    init() {
        originalName = nil
        name = ""
        say = ""
        program = ""
        arguments = ""
        fixedArguments = nil
    }

    let fixedArguments: [String]?

    init(_ script: VoiceCommandScript) {
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
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), say: forms,
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
            Text(draft.originalName == nil ? "Add Script" : "Edit Script").font(.title2.bold())
            Form {
                VoiceCommandNoticeRow(kind: .scripts, needsAcknowledgment: draft.originalName == nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptNotice)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $draft.name, prompt: Text("deploy"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptName)
                        .formFieldLabel("Name")
                    Text("Say \u{201C}run\u{201D} followed by this name. To pass words after its name, put \(VoiceCommandScript.textPlaceholder) in an argument below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Also say", text: $draft.say, prompt: Text("ship, release"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptSay)
                        .formFieldLabel("Also say")
                    if let shared = model.sharedNameAdvisory(for: draft.script, replacing: draft.originalName) {
                        IssueText(shared, severity: .advisory)
                    }
                    Text("Other names for this script, separated by commas. Say any of them after \u{201C}run\u{201D}.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    Text("The full path to an executable file. It runs directly, not through a shell, with a minimal PATH, so a script that calls other tools should use their full paths or set PATH itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
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
                            DisclosureSummaryLabel(title: "How arguments are passed", summary: "Blank lines, and when words are needed")
                        } content: {
                            Text("Each line is passed exactly as written, including blank lines between them, and the words you say stay within each argument that contains \(VoiceCommandScript.textPlaceholder). With \(VoiceCommandScript.textPlaceholder), the script needs words after its name; without it, say \u{201C}run\u{201D} and the name with no words after it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptArgumentDetails)
                    }
                }
            }
            .formStyle(.grouped)
            if let validationIssue, !draft.name.isEmpty || !draft.program.isEmpty {
                IssueText(validationIssue)
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
                    PaneDeleteButton(title: "Delete Script") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptCancel)
                    Button("Add Script") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptSave)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog("Delete \u{201C}\(draft.originalName ?? draft.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let name = draft.originalName {
                    issue = model.deleteScript(named: name)
                    if issue == nil { onDone() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \u{201C}run\u{201D} commands will no longer work. The program itself is not deleted.")
        }
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
        model.scriptIssue(draft.script, replacing: draft.originalName)
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
        case .url: place.browser
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
    let originalName: String?
    var name: String
    var say: String
    var shortcut: VoiceCommandShortcut?
    var input: String
    private var suggestion: String?

    init() {
        originalName = nil
        name = ""
        say = ""
        shortcut = nil
        input = ""
    }

    init(_ script: VoiceCommandScript) {
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
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), say: forms,
            shortcut: VoiceCommandShortcut(
                name: shortcut?.name ?? "", identifier: shortcut?.identifier,
                input: trimmedInput.isEmpty ? nil : trimmedInput))
    }

    static func description(_ shortcut: VoiceCommandShortcut) -> String {
        let input = shortcut.input.map { ", given \u{201C}\($0)\u{201D}" } ?? ""
        return "Shortcut \u{201C}\(shortcut.name)\u{201D}\(input)"
    }

    var example: String? {
        let action = script
        guard action.issue == nil, let shortcut = action.shortcut else { return nil }
        let phrase = "run \(action.name)" + (action.takesText ? " buy milk" : "")
        let result = action.arguments(text: "buy milk").first.map {
            "pass \u{201C}\($0)\u{201D} to \u{201C}\(shortcut.name)\u{201D}"
        } ?? "run \u{201C}\(shortcut.name)\u{201D} with no input"
        return "Say \u{201C}\(phrase)\u{201D} to \(result)."
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
            Text(draft.originalName == nil ? "Add Shortcut" : "Edit Shortcut").font(.title2.bold())
            Form {
                VoiceCommandNoticeRow(kind: .shortcuts, needsAcknowledgment: draft.originalName == nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutNotice)
                shortcutRow
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $draft.name, prompt: Text("What would you like to call it?"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutName)
                        .formFieldLabel("Name")
                    Text("Say \u{201C}run\u{201D} followed by this name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Also say", text: $draft.say, prompt: Text("Optional, such as log, note"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutSay)
                        .formFieldLabel("Also say")
                    if let shared = model.sharedNameAdvisory(for: draft.script, replacing: draft.originalName) {
                        IssueText(shared, severity: .advisory)
                    }
                    Text("Other names for this shortcut, separated by commas. Say any of them after \u{201C}run\u{201D}.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Input", text: $draft.input, prompt: Text("Optional, such as \(VoiceCommandScript.textPlaceholder)"))
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutInput)
                        .formFieldLabel("Input")
                    Text("Leave empty for no input, or enter \(VoiceCommandScript.textPlaceholder) to pass the words you say after the name. You can also enter fixed text.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let example = draft.example {
                        Text(example).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutExample)
                    }
                }
                Text("The shortcut may open an app or ask you a question. While it waits, it is shown as started. Its final result is saved when History is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if let validationIssue, !draft.name.isEmpty || draft.shortcut != nil {
                IssueText(validationIssue)
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
                    PaneDeleteButton(title: "Delete Shortcut") { confirmingDelete = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutDelete)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutCancel)
                    Button("Add Shortcut") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutSave)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await model.loadShortcutChoices() }
        .confirmationDialog("Delete \u{201C}\(draft.originalName ?? draft.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let name = draft.originalName {
                    issue = model.deleteScript(named: name)
                    if issue == nil { onDone() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.shortcutDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \u{201C}run\u{201D} commands will no longer work. The shortcut itself stays in Shortcuts.")
        }
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
        model.scriptIssue(draft.script, replacing: draft.originalName)
    }

    private func save() {
        issue = model.saveScript(draft.script, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}
