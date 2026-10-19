import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandsSettingsModelTests {
    private func make() -> (VoiceCommandsSettingsModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        return (VoiceCommandsSettingsModel(repository: repository), dir)
    }

    private let mail = VoiceCommandPlace(name: "Mail", say: ["inbox"], target: .url("https://mail.google.com/"))

    @Test func addingAPlaceWritesTheFile() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.save(mail, replacing: nil) == nil)
        #expect(model.places == [mail])
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).places == [mail])
    }

    @Test func editingReplacesInPlaceAndCanRename() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let code = VoiceCommandPlace(name: "Code", target: .app(bundleId: "com.microsoft.VSCode"))
        _ = model.save(mail, replacing: nil)
        _ = model.save(code, replacing: nil)
        var renamed = mail
        renamed.name = "Gmail"
        #expect(model.save(renamed, replacing: "Mail") == nil)
        #expect(model.places.map(\.name) == ["Gmail", "Code"])
    }

    @Test func aDuplicateNameIsRefused() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        let other = VoiceCommandPlace(name: "mail", target: .app(bundleId: "com.apple.mail"))
        #expect(model.save(other, replacing: nil) == "Another place or action already uses this name.")
        #expect(model.places == [mail])
    }

    @Test func anInvalidPlaceIsRefusedWithItsIssue() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = VoiceCommandPlace(name: "Web", target: .url("mail.google.com"))
        #expect(model.save(bad, replacing: nil) != nil)
        #expect(model.places.isEmpty)
    }

    @Test func deleteRemovesThePlace() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        #expect(model.delete(named: "MAIL") == nil)
        #expect(model.places.isEmpty)
    }

    @Test func aMalformedFileBlocksEditingAndExplainsWhy() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "schema_version = 1\n[[place]]\nname = \"Nowhere\"\n"
            .write(to: dir.appendingPathComponent(VoiceCommandStore.fileName), atomically: true, encoding: .utf8)
        model.reload()
        #expect(model.loadError != nil)
        #expect(model.save(mail, replacing: nil) != nil)
    }

    @Test func tryItDescribesWithoutRunning() {
        let summary = VoiceCommandsSettingsModel.describe(.noMatch("banana"), heard: "go to banana", appName: { _ in nil })
        #expect(!summary.resolved)
        #expect(summary.summary == "No match")
        let action = VoiceCommandsSettingsModel.describe(
            .action(.app(.init(name: "Ghostty", bundleId: "com.mitchellh.ghostty"))), heard: "switch to ghostty", appName: { _ in nil })
        #expect(action.resolved)
        #expect(action.summary == "Ghostty")
    }

    @Test func tryItShowsTheChoiceItWouldOfferWithoutOfferingIt() {
        let personal = VoiceCommandPlace(name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"))
        let work = VoiceCommandPlace(name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"))
        let choice = VoiceCommandChoice(family: .navigation, target: "mail", matches: [.place(personal), .place(work)])
        let asked = VoiceCommandsSettingsModel.describe(.ambiguous(choice), heard: "switch to mail", appName: { _ in nil })
        #expect(!asked.resolved)
        #expect(asked.summary == "Would ask \u{201C}Which one?\u{201D}")
        #expect(asked.asksChoice)
        #expect(asked.detail.hasPrefix("When spoken, this command would ask you to choose: "))
        #expect(asked.detail.contains("1. Personal Mail (Default browser \u{00B7} mail.example.net)"))
        #expect(asked.detail.contains("2. Work Mail (Default browser \u{00B7} inbox.example.org)"))
        let many = VoiceCommandChoice(
            family: .navigation, target: "note",
            matches: (1...6).map { .app(.init(name: "Note \($0)", bundleId: "com.example.\($0)")) })
        #expect(VoiceCommandsSettingsModel.describe(.ambiguous(many), heard: "open note", appName: { _ in nil }).detail
                == "6 matches for \u{201C}note\u{201D}. Say more of the name.")
    }

    @Test func aSharedSpokenNameIsAnAdvisoryAndStillSaves() {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personal = VoiceCommandPlace(name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"))
        let work = VoiceCommandPlace(name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"))
        #expect(model.save(personal, replacing: nil) == nil)
        #expect(model.sharedNameAdvisory(for: work, replacing: nil)
                == "Saying \u{201C}mail\u{201D} will ask you to choose between Work Mail and Personal Mail.")
        #expect(model.save(work, replacing: nil) == nil)
        model.reload()
        #expect(model.places.map(\.name) == ["Personal Mail", "Work Mail"])
    }

    @Test func tryItReadsWithTheVocabularyLiveCommandsUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var commands = Mode.voiceCommands
        commands.dictionary.words = ["herdr"]
        try ModeStore.write(commands, to: modesDir)
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let model = VoiceCommandsSettingsModel(repository: ConfigRepository(supportDir: dir, config: config))
        _ = config.resolved

        try "not toml".write(to: modesDir.appendingPathComponent("\(Mode.voiceCommandsId).toml"), atomically: true, encoding: .utf8)

        #expect(model.readAs("switch to herder") == "switch to herdr")
    }

    @Test func tryItShowsWhatTheVocabularyChanged() {
        let cleaned = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "bitch to herder", readAs: "switch to herdr", appName: { _ in nil })
        #expect(cleaned.readAs == "switch to herdr")
        let unchanged = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "go to herdr", readAs: "go to herdr", appName: { _ in nil })
        #expect(unchanged.readAs == nil)
    }

    @Test func tryItRefreshesWhenAPlaceIsSaved() async throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.tryIt("switch to zzqvplace")
        try await waitFor { model.tryResult?.summary == "No match" }
        let place = VoiceCommandPlace(name: "Zzqvplace", target: .app(bundleId: "com.apple.finder"))
        #expect(model.save(place, replacing: nil) == nil)
        try await waitFor { model.tryResult?.resolved == true }
        #expect(model.tryResult?.summary == "Zzqvplace")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    @Test func aPlaceRowShowsPhrasesThatActuallyWork() {
        #expect(mail.spokenExamples == ["open Mail", "open inbox"])
        let code = VoiceCommandPlace(name: "Code", say: ["editor"], target: .app(bundleId: "com.microsoft.VSCode"))
        #expect(code.spokenExamples == ["switch to Code", "switch to editor"])
    }

    @Test func choosingAnAppSuggestsItsNameUntilTheUserTypesOne() {
        var draft = PlaceDraft(name: "", kind: .app)
        draft.choose(VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail"))
        #expect(draft.name == "Mail")
        draft.choose(VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty"))
        #expect(draft.name == "Ghostty")
        #expect(draft.bundleId == "com.mitchellh.ghostty")
        draft.name = "terminal"
        draft.choose(VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail"))
        #expect(draft.name == "terminal")
    }

    @Test func aPlaceStartedFromTheCurrentAppStillFollowsALaterChoice() {
        var draft = PlaceDraft(name: "Safari", kind: .app, bundleId: "com.apple.Safari")
        draft.choose(VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail"))
        #expect(draft.name == "Mail")
        var existing = PlaceDraft(VoiceCommandPlace(name: "Work", target: .app(bundleId: "com.apple.Safari")))
        existing.choose(VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail"))
        #expect(existing.name == "Work")
    }

    @Test func thePlaceSheetShowsALiveExample() {
        var draft = PlaceDraft(name: "", kind: .app, bundleId: "com.apple.mail")
        #expect(draft.example(destination: "Mail") == nil)
        draft.name = "Mail"
        draft.say = "inbox, letters"
        #expect(draft.example(destination: "Mail") == "Say \u{201C}switch to inbox\u{201D} to bring Mail to the front.")
        var page = PlaceDraft(name: "Gmail", kind: .webPage, url: "https://mail.google.com/")
        #expect(page.example(destination: "mail.google.com") == "Say \u{201C}open Gmail\u{201D} to go to mail.google.com.")
        page.say = "inbox"
        #expect(page.example(destination: "mail.google.com") == "Say \u{201C}open inbox\u{201D} to go to mail.google.com.")
    }

    @Test func suggestedPlaceNameComesFromTheTabTitle() {
        #expect(VoiceCommandsEditorView.suggestedName(title: "Inbox - me@example.com - Gmail", url: "https://mail.google.com/") == "Inbox")
        #expect(VoiceCommandsEditorView.suggestedName(title: "", url: "https://www.github.com/x") == "github.com")
    }

    private let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["/usr/bin/true", "{text}"])

    @Test func addingEditingAndDeletingAScriptWritesTheFile() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.saveScript(deploy, replacing: nil) == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).scripts == [deploy])
        var renamed = deploy
        renamed.name = "Release"
        #expect(model.saveScript(renamed, replacing: "Deploy") == nil)
        #expect(model.scripts == [renamed])
        #expect(model.deleteScript(named: "release") == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).scripts.isEmpty)
    }

    @Test func aScriptCannotTakeAPlacesName() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        let clash = VoiceCommandScript(name: "Mail", run: ["/usr/bin/true"])
        #expect(model.saveScript(clash, replacing: nil) == "Another place or action already uses this name.")
        #expect(model.save(VoiceCommandPlace(name: "deploy", target: .app(bundleId: "com.example")), replacing: nil) == nil)
        #expect(model.saveScript(deploy, replacing: nil) == "Another place or action already uses this name.")
    }

    @Test func anInvalidScriptIsRefusedWithItsIssue() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.saveScript(VoiceCommandScript(name: "X", run: ["deploy"]), replacing: nil)
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
        #expect(model.scripts.isEmpty)
    }

    @Test func anInterpreterGivenSpokenTextIsRefusedWithoutTouchingTheFile() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.saveScript(deploy, replacing: nil) == nil)
        let file = dir.appendingPathComponent(VoiceCommandStore.fileName)
        let before = try String(contentsOf: file, encoding: .utf8)
        #expect(model.saveScript(VoiceCommandScript(name: "Shell", run: ["/bin/sh", "-c", "{text}"]), replacing: nil)
            == "Program: With {text}, “sh” could run spoken words as code. Put the logic in an executable script file and choose that file instead.")
        #expect(model.saveScript(VoiceCommandScript(name: deploy.name, run: ["/usr/bin/env", "{text}"]), replacing: deploy.name) != nil)
        #expect(model.scripts == [deploy])
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
    }

    @Test func scriptValidationExplainsWhatPreventsSavingWithoutWriting() {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.scriptIssue(deploy, replacing: nil) == nil)
        #expect(model.scriptIssue(VoiceCommandScript(name: "", run: ["/bin/tool"]), replacing: nil) != nil)
        #expect(model.scriptIssue(VoiceCommandScript(name: "Tool", run: ["tool"]), replacing: nil)
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(VoiceCommandStore.fileName).path))

        _ = model.saveScript(deploy, replacing: nil)
        #expect(model.scriptIssue(deploy, replacing: nil) == "Another place or action already uses this name.")
        #expect(model.scriptIssue(deploy, replacing: deploy.name) == nil)
    }

    @Test func theProgramCheckNamesWhatIsWrong() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-prog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tool")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(VoiceCommandsSettingsModel.programIssue(file.path)
            == "This file is not executable. Make it executable (chmod +x) so it can run.")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(VoiceCommandsSettingsModel.programIssue(file.path) == nil)
        #expect(VoiceCommandsSettingsModel.programIssue(dir.appendingPathComponent("absent").path) == "No file is at this path yet.")
        #expect(VoiceCommandsSettingsModel.programIssue("relative") == nil)
    }

    @Test func tryItDescribesAScriptWithoutRunningIt() {
        let action = VoiceCommandAction.script(deploy, arguments: ["staging"])
        let result = VoiceCommandsSettingsModel.describe(.action(action), heard: "deploy staging", appName: { _ in nil })
        #expect(result.summary == "Deploy")
        #expect(result.detail == "Runs /usr/bin/true staging in the background.")
        let wanting = VoiceCommandsSettingsModel.describe(.scriptNeedsText("Deploy"), heard: "deploy", appName: { _ in nil })
        #expect(!wanting.resolved)
        #expect(wanting.detail == "Say what to pass to Deploy after its name.")
    }

    @Test func aDraftKeepsEveryArgumentLineExactly() {
        var draft = ScriptDraft()
        draft.name = " Deploy "
        draft.say = "ship, , release"
        draft.program = " ~/bin/deploy "
        draft.arguments = "--env\n\n  {text}  \n\n"
        #expect(draft.script == VoiceCommandScript(name: "Deploy", say: ["ship", "release"], run: ["~/bin/deploy", "--env", "", "  {text}  "]))
    }

    @Test func openingAndSavingAScriptChangesNoArgument() {
        for arguments in [["one", "", "three"], ["  ", "x"], [], ["a", ""], [""]] {
            let script = VoiceCommandScript(name: "Tool", run: ["/bin/tool"] + arguments)
            #expect(ScriptDraft(script).script == script, "\(arguments)")
        }
    }

    @Test func onlyArgumentsTheEditorCannotShowAreHeldFixed() {
        #expect(ScriptDraft(VoiceCommandScript(name: "T", run: ["/bin/t", "one", "", "three"])).fixedArguments == nil)
        #expect(ScriptDraft(VoiceCommandScript(name: "T", run: ["/bin/t", "a", ""])).fixedArguments == ["a", ""])
    }

    @Test func aShortcutDraftNamesItselfAfterTheChosenShortcutUntilRenamed() {
        var draft = ShortcutDraft()
        draft.choose(VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98"))
        #expect(draft.name == "Journal Entry")
        draft.choose(VoiceCommandShortcut(name: "Share Wi-Fi", identifier: "CADB"))
        #expect(draft.name == "Share Wi-Fi")
        draft.name = "Wi-Fi"
        draft.choose(VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98"))
        #expect(draft.name == "Wi-Fi")
        #expect(draft.script.shortcut == VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98"))
    }

    @Test func aShortcutDraftKeepsInputOnlyWhenGiven() {
        var draft = ShortcutDraft(VoiceCommandScript(
            name: "Journal", say: ["log"], shortcut: VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98", input: "{text}")))
        #expect(draft.script == VoiceCommandScript(
            name: "Journal", say: ["log"], shortcut: VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98", input: "{text}")))
        draft.input = "  "
        #expect(draft.script.shortcut?.input == nil)
        #expect(!draft.script.takesText)
    }

    @Test func eachListHasItsOwnWarning() {
        let kinds: [VoiceCommandNotices.Kind] = [.places, .scripts, .shortcuts]
        #expect(Set(kinds.map(\.title)).count == kinds.count)
        #expect(Set(kinds.map(\.message)).count == kinds.count)
        #expect(VoiceCommandNotices.Kind.shortcuts.message.contains("send messages"))
        #expect(VoiceCommandNotices.Kind.shortcuts.message.contains("online services"))
    }

    @Test func aShortcutExampleUsesItsActualSpokenNameAndInput() {
        var draft = ShortcutDraft()
        #expect(draft.example == nil)
        draft.choose(VoiceCommandShortcut(name: "Journal Entry"))
        #expect(draft.example == "Say “run Journal Entry” to run “Journal Entry” with no input.")
        draft.name = "journal"
        draft.input = "Note: {text}"
        #expect(draft.example == "Say “run journal buy milk” to pass “Note: buy milk” to “Journal Entry”.")
        draft.input = "Daily check-in"
        #expect(draft.example == "Say “run journal” to pass “Daily check-in” to “Journal Entry”.")
    }
}
