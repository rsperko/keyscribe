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
        #expect(model.save(other, replacing: nil) == "Another place or script already uses this name.")
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
        #expect(model.saveScript(clash, replacing: nil) == "Another place or script already uses this name.")
        #expect(model.save(VoiceCommandPlace(name: "deploy", target: .app(bundleId: "com.example")), replacing: nil) == nil)
        #expect(model.saveScript(deploy, replacing: nil) == "Another place or script already uses this name.")
    }

    @Test func anInvalidScriptIsRefusedWithItsIssue() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.saveScript(VoiceCommandScript(name: "X", run: ["deploy"]), replacing: nil)
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
        #expect(model.scripts.isEmpty)
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
}
