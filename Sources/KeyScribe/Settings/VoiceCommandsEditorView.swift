import AppKit
import SwiftUI
import KeyScribeKit

struct VoiceCommandsEditorView: View {
    let mode: Mode
    let allModes: [Mode]
    let onUpdate: (Mode) -> Void
    @ObservedObject var model: VoiceCommandsSettingsModel
    var onEditVocabulary: () -> Void = {}
    @State private var editing: PlaceDraft?
    @State private var tryText = ""

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
                ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                if let clash = VoiceCommandTriggers.clash(for: mode, in: trigger.allModes) {
                    IssueText("\(clash.name) also uses this shortcut, so it does not start \(mode.name). Choose one no other mode uses.")
                } else {
                    TriggerConflictLabel(conflict: trigger.conflict, mode: mode)
                }
                ExtraTriggersNote(mode: mode)
                if trigger.usesMouseShortcut {
                    Text("While this shortcut is assigned, the mouse button won’t also go Back or Forward in other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Speech on this shortcut is never typed. If it isn’t a command \(Branding.appName) understands, nothing happens. Commands are recognized on this Mac and are not saved to History.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What you can say") {
                phraseRow("\u{201C}switch to …\u{201D}  \u{201C}go to …\u{201D}  \u{201C}open …\u{201D}  \u{201C}focus …\u{201D}",
                          "Any running app, or one in your Applications folders, by name, or a place below. Brings it to the front, opening it if needed.")
                phraseRow("\u{201C}go back\u{201D}", "Returns to the app you were in before your last command.")
            }

            placesSection

            Section("When a command is misheard") {
                SettingRow(
                    title: "Recognition and replacements",
                    result: VocabularyScopePicker.summary(for: mode),
                    help: "Words and replacements here apply only to commands, before \(Branding.appName) reads what you said. Add a name as it is really spelled, or replace a phrase that keeps coming out wrong, such as a misheard \u{201C}switch to\u{201D}.",
                    combinesAccessibilityChildren: false)
                {
                    Button("Edit Vocabulary…", action: onEditVocabulary)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.editVocabulary)
                }
            }

            trySection
        }
        .formStyle(.grouped)
        .padding(16)
        .sheet(item: $editing) { draft in
            PlaceEditorSheet(draft: draft, model: model) { editing = nil }
        }
    }

    private func phraseRow(_ phrase: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase)
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var placesSection: some View {
        Section {
            if let loadError = model.loadError {
                IssueText(loadError)
            }
            if model.places.isEmpty {
                Text("No places yet. App names already work on their own — add a place to give an app a nickname, or to jump to a web page, using an open tab when there is one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.places, id: \.name) { place in
                placeRow(place)
            }
        } header: {
            HStack {
                Text("Places")
                Spacer()
                addMenu
            }
        }
    }

    private func placeRow(_ place: VoiceCommandPlace) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                Text("Say: " + place.spokenForms.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(destination(place)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            PaneBadge(place.isWebPage ? "Web page" : "App")
            Button("Edit…") { editing = PlaceDraft(place) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeEdit(VoiceCommandText.key(place.name).replacingOccurrences(of: " ", with: "-")))
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
        Menu("Add Place") {
            if let app = model.currentApp {
                Button("Current App (\(app.name))") {
                    editing = PlaceDraft(name: app.name, kind: .app, bundleId: app.bundleId)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentApp)
                if LiveVoiceCommandSystem.shared.isBrowser(app.bundleId) {
                    Button("Current Browser Tab") {
                        Task {
                            if let tab = await model.currentTab() {
                                editing = PlaceDraft(
                                    name: Self.suggestedName(title: tab.title, url: tab.url), kind: .webPage,
                                    url: tab.url, browser: tab.browserBundleId)
                            } else {
                                editing = PlaceDraft(name: "", kind: .webPage, browser: app.bundleId)
                            }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addCurrentTab)
                }
                Divider()
            }
            Button("App…") { editing = PlaceDraft(name: "", kind: .app) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addApp)
            Button("Web Page…") { editing = PlaceDraft(name: "", kind: .webPage) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addWebPage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.loadError != nil)
        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.addPlace)
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
                .multilineTextAlignment(.leading)
                .onSubmit { model.tryIt(tryText) }
                .onChange(of: tryText) { _, value in model.tryIt(value) }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.tryIt)
            if let result = model.tryResult, result.heard == tryText.trimmingCharacters(in: .whitespacesAndNewlines) {
                VStack(alignment: .leading, spacing: 2) {
                    if let readAs = result.readAs {
                        Text("Read as \u{201C}\(readAs)\u{201D}").font(.caption).foregroundStyle(.secondary)
                    }
                    if result.resolved {
                        Label(result.summary, systemImage: "arrow.right.circle").font(.callout)
                    } else {
                        IssueText(result.summary, severity: .advisory, font: .callout)
                    }
                    if !result.detail.isEmpty {
                        Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Shows what a command would do without doing it. Checking open tabs reads their addresses and titles, and may ask to control your browser.")
                .font(.caption).foregroundStyle(.secondary)
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
    enum Kind: String, CaseIterable { case app, webPage }

    let id = UUID()
    let originalName: String?
    var name: String
    var say: String
    var kind: Kind
    var bundleId: String
    var url: String
    var browser: String

    init(name: String, kind: Kind, bundleId: String = "", url: String = "", browser: String? = nil) {
        originalName = nil
        self.name = name
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == nil ? "Add Place" : "Edit Place").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeName)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Also say", text: $draft.say, prompt: Text("mail, inbox"))
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSay)
                    Text("Other names you might say for this place, separated by commas. The name always works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Goes to", selection: $draft.kind) {
                    Text("An app").tag(PlaceDraft.Kind.app)
                    Text("A web page").tag(PlaceDraft.Kind.webPage)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeKind)
                if draft.kind == .app {
                    Picker("App", selection: $draft.bundleId) {
                        if draft.bundleId.isEmpty { Text("Choose an app").tag("") }
                        if !draft.bundleId.isEmpty, !model.appChoices.contains(where: { $0.bundleId == draft.bundleId }) {
                            Text(model.appName(draft.bundleId)).tag(draft.bundleId)
                        }
                        ForEach(model.appChoices, id: \.bundleId) { app in
                            Text(app.name).tag(app.bundleId)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeApp)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Web page", text: $draft.url, prompt: Text("https://mail.google.com/"))
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeURL)
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
                    Text("Any browser looks through every running browser that can list its tabs, in all its windows, which can include private ones. Finding an open tab asks macOS for permission to control the browser the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let issue { IssueText(issue) }
            HStack {
                if draft.originalName != nil {
                    Button("Cancel", role: .cancel, action: onDone)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeCancel)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
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
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.placeSave)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await model.loadAppChoices() }
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

    private func save() {
        issue = model.save(draft.place, replacing: draft.originalName)
        if issue == nil { onDone() }
    }
}
