import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandsSettingsModelTests {
    // No installed apps or browsers: a preview that falls through to browser tabs would otherwise ask macOS for
    // Automation consent on behalf of the test runner and wait on a prompt nobody answers.
    private func isolatedModel(_ repository: ConfigRepository) -> VoiceCommandsSettingsModel {
        VoiceCommandsSettingsModel(repository: repository, system: LiveVoiceCommandSystem(roots: [], handlers: { [] }))
    }

    private func make() -> (VoiceCommandsSettingsModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        return (isolatedModel(repository), dir)
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
        #expect(model.save(other, replacing: nil) == VoiceCommandsSettingsModel.nameTakenMessage)
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
        #expect(model.delete(id: mail.id) == nil)
        #expect(model.places.isEmpty)
    }

    @Test func aMalformedFileBlocksEditingAndExplainsWhy() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "schema_version = 1\n[[command]]\nname = \"Nowhere\"\n"
            .write(to: dir.appendingPathComponent(VoiceCommandStore.fileName), atomically: true, encoding: .utf8)
        model.reload()
        #expect(model.fileNotice?.title == "\(VoiceCommandStore.fileName) needs fixing")
        #expect(model.save(mail, replacing: nil) != nil)
    }

    @Test func tryItDescribesWithoutRunning() {
        let summary = VoiceCommandsSettingsModel.describe(.noMatch("banana"), heard: "go to banana", appName: { _ in nil })
        #expect(!summary.resolved)
        #expect(summary.summary == "No match")
        let action = VoiceCommandsSettingsModel.describe(
            .action(.app(.init(name: "Ghostty", bundleId: "com.mitchellh.ghostty"))), heard: "switch to ghostty", appName: { _ in nil })
        #expect(action.resolved)
        #expect(action.summary == "Switch to Ghostty")
    }

    @Test func tryItShowsTheChoiceItWouldOfferWithoutOfferingIt() {
        let personal = VoiceCommandPlace(name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"))
        let work = VoiceCommandPlace(name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"))
        let choice = VoiceCommandChoice(family: .navigation, target: "mail", matches: [.place(personal), .place(work)])
        let asked = VoiceCommandsSettingsModel.describe(.ambiguous(choice), heard: "switch to mail", appName: { _ in nil })
        #expect(!asked.resolved)
        #expect(asked.summary == "Would ask \u{201C}Which one?\u{201D}")
        #expect(asked.asksChoice)
        #expect(asked.choices == [
            .init(name: "1. Personal Mail", detail: "Default browser \u{00B7} mail.example.net"),
            .init(name: "2. Work Mail", detail: "Default browser \u{00B7} inbox.example.org"),
        ])
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
        #expect(model.conflicts(for: .place(work))
                == ["\u{201C}mail\u{201D} is also a name for Personal Mail, so saying it will ask you to choose. Give this one a name of its own."])
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
        let model = isolatedModel(ConfigRepository(supportDir: dir, config: config))
        _ = config.resolved

        try "not toml".write(to: modesDir.appendingPathComponent("\(Mode.voiceCommandsId).toml"), atomically: true, encoding: .utf8)

        #expect(model.readAs("switch to herder") == "switch to herdr")
    }

    @Test func theEditorPreviewAppliesTheModesReplacements() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let repository = ConfigRepository(supportDir: dir, config: config)
        var commands = Mode.voiceCommands
        commands.replacements.rules = [.init(heard: "inbox", replace: "switch to inbox", regex: false)]
        try repository.writeMode(commands)
        let model = isolatedModel(repository)
        let inbox = VoiceCommandScript(name: "Inbox", run: ["/usr/bin/true"])
        #expect(model.example(for: .script(inbox)).conflict
                == "Your replacements read \u{201C}inbox\u{201D} as \u{201C}switch to inbox\u{201D}, so it does not run this command.")
    }

    @Test func anOtherNameAReplacementTakesAwayIsFlaggedOnceInTheEditor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let repository = ConfigRepository(supportDir: dir, config: config)
        var commands = Mode.voiceCommands
        commands.replacements.rules = [.init(heard: "inbox", replace: "switch to inbox", regex: false)]
        try repository.writeMode(commands)
        let model = isolatedModel(repository)
        let mail = VoiceCommandScript(name: "Mail", say: ["inbox"], run: ["/usr/bin/true"])
        let lost = "Your replacements read \u{201C}inbox\u{201D} as \u{201C}switch to inbox\u{201D}, so it does not run this command."
        #expect(model.example(for: .script(mail)).conflict == nil)
        #expect(model.namesLostToReplacements(for: .script(mail)) == [lost])
        #expect(model.conflicts(for: .script(mail)) == [lost])
        let inbox = VoiceCommandScript(name: "Inbox", run: ["/usr/bin/true"])
        #expect(model.conflicts(for: .script(inbox)).isEmpty)
    }

    @Test func tryItNeverCountsAReplacementAsUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = ReplacementUsageStore(supportDir: dir)
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let repository = ConfigRepository(supportDir: dir, config: config, replacementUsage: usage)
        var commands = Mode.voiceCommands
        commands.replacements.rules = [.init(heard: "male", replace: "mail", regex: false)]
        try repository.writeMode(commands)
        let model = isolatedModel(repository)
        #expect(model.readAs("switch to male") == "switch to mail")
        usage.flush()
        #expect(usage.snapshot().rules["mode:\(Mode.voiceCommandsId)|l|male"]?.count == 0)
    }

    @Test func aSidebarPreviewSaysTiesOpenTheFirstItemWithoutAsking() {
        let result = VoiceCommandsSettingsModel.describe(
            .needsSidebar("com.tinyspeck.slackmacgap"), heard: "slack general", readAs: "slack general",
            appName: { _ in "Slack" })
        #expect(result.summary == "Opens the best match in the Slack sidebar")
        #expect(result.detail == "The preview does not read sidebars, so it cannot name the item. Slack opens first if needed, and if several items match equally, the first one opens.")
    }

    @Test func tryItShowsWhatTheVocabularyChanged() {
        let cleaned = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "bitch to herder", readAs: "switch to herdr", appName: { _ in nil })
        #expect(cleaned.readAs == "switch to herdr")
        let unchanged = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "go to herdr", readAs: "go to herdr", appName: { _ in nil })
        #expect(unchanged.readAs == nil)
    }

    @Test func anAppLinkPlaceSavesWithoutABrowser() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = VoiceCommandPlace(name: "Web Hooks", say: ["web hooks"], target: .url("slack://channel?team=T1&id=C1"))
        #expect(model.save(channel, replacing: nil) == nil)
        #expect(model.places == [channel])
        let browsed = VoiceCommandPlace(name: "Other", target: .url("slack://open"), browser: "com.example.browser")
        #expect(model.save(browsed, replacing: nil) != nil)
    }

    @Test func tryItRefreshesWhenAPlaceIsSaved() async throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.tryIt("switch to zzqvplace")
        try await waitFor { model.tryResult?.summary == "No match" }
        let place = VoiceCommandPlace(name: "Zzqvplace", target: .app(bundleId: "com.apple.finder"))
        #expect(model.save(place, replacing: nil) == nil)
        try await waitFor { model.tryResult?.resolved == true }
        #expect(model.tryResult?.summary == "Switch to Finder")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    @Test func aCommandRowShowsPhrasesThatActuallyWork() {
        #expect(VoiceCommandExample.phrases(for: .place(mail)) == ["Mail", "inbox"])
        let log = VoiceCommandScript(name: "Log", say: ["note"], run: ["/usr/bin/printf", "{text}"])
        #expect(VoiceCommandExample.phrases(for: .script(log)) == ["Log \u{2026}", "note \u{2026}"])
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

    @Test func aPlacePreviewFollowsTheDraft() {
        let draft = PlaceDraft(name: "Mail", kind: .app, bundleId: "com.apple.mail")
        #expect(VoiceCommandExample.make(for: .place(draft.place), appName: { _ in "Mail" })
                == VoiceCommandExample(heard: "mail", result: "Brings Mail to the front, opening it if needed."))
        let search = PlaceDraft(name: "Chrome", kind: .tabSearch, browser: "com.google.Chrome")
        #expect(search.place == VoiceCommandPlace(id: search.commandId, name: "Chrome", target: .tabSearch, browser: "com.google.Chrome"))
    }

    @Test func theFirstExamplesNeedNothingSaved() {
        #expect(VoiceCommandsEditorView.examples(findsInApps: true).map(\.phrase)
                == ["\u{201C}open Mail\u{201D}", "\u{201C}open Slack general\u{201D}", "\u{201C}go back\u{201D}"])
        #expect(VoiceCommandsEditorView.examples(findsInApps: false).map(\.phrase)
                == ["\u{201C}open Mail\u{201D}", "\u{201C}go back\u{201D}"])
    }

    @Test func anOldSidebarCommandEditsAsAPlainAppCommand() {
        let slack = "com.tinyspeck.slackmacgap"
        let saved = VoiceCommandPlace(name: "Slack", say: ["chat"], target: .app(bundleId: slack))
        let draft = PlaceDraft(saved)
        #expect(draft.kind == .app)
        #expect(draft.place == saved)
    }

    @Test func theEditorPreviewIsCheckedAgainstSavedCommands() {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.save(mail, replacing: nil) == nil)
        let mailer = VoiceCommandScript(name: "Mailer", say: ["mail"], run: ["/usr/bin/true"])
        #expect(model.example(for: .script(mailer)).conflict == nil)
        let clash = VoiceCommandScript(name: "Mail it", say: ["inbox"], run: ["/usr/bin/true"])
        #expect(model.example(for: .script(clash)).conflict == nil)
        let same = VoiceCommandScript(name: "Inbox", run: ["/usr/bin/true"])
        #expect(model.example(for: .script(same)).conflict
                == "Saying \u{201C}inbox\u{201D} would ask you to choose between this command and Mail.")
        #expect(model.example(for: .place(mail)).conflict == nil)
    }

    @Test func theScriptEditorPreviewsItsDraftWithoutRunningIt() {
        var draft = ScriptDraft()
        draft.name = "  Log note  "
        draft.program = "/usr/bin/printf"
        draft.arguments = "%s\nNote: {text}"
        draft.say = "remember"
        #expect(VoiceCommandExample.make(for: .script(draft.script))
                == VoiceCommandExample(heard: "log note buy milk", result: "Runs /usr/bin/printf %s 'Note: buy milk' in the background."))
        draft.arguments = "Daily check-in"
        #expect(VoiceCommandExample.make(for: .script(draft.script))
                == VoiceCommandExample(heard: "log note", result: "Runs /usr/bin/printf 'Daily check-in' in the background."))
    }

    @Test func theScriptPreviewPreservesArgumentsTheEditorCannotRepresent() {
        let draft = ScriptDraft(VoiceCommandScript(name: "Log", run: ["/usr/bin/printf", "{text}", ""]))
        #expect(VoiceCommandExample.make(for: .script(draft.script)).result == "Runs /usr/bin/printf 'buy milk' '' in the background.")
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
        #expect(model.delete(id: renamed.id) == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).scripts.isEmpty)
    }

    @Test func aScriptCannotTakeAPlacesName() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        let clash = VoiceCommandScript(name: "Mail", run: ["/usr/bin/true"])
        #expect(model.saveScript(clash, replacing: nil) == VoiceCommandsSettingsModel.nameTakenMessage)
        #expect(model.save(VoiceCommandPlace(name: "deploy", target: .app(bundleId: "com.example")), replacing: nil) == nil)
        #expect(model.saveScript(deploy, replacing: nil) == VoiceCommandsSettingsModel.nameTakenMessage)
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

    @Test func aSavedFileWithARefusedScriptStillLoadsItsOtherEntries() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = VoiceCommandScript(name: "Shell", run: ["/usr/bin/xcrun", "swift", "-e", "{text}"])
        try VoiceCommandStore.write(VoiceCommandConfig(places: [mail], scripts: [shell, deploy]), to: dir)
        model.reload()
        #expect(!model.hasUnreadableFile)
        #expect(model.places == [mail])
        #expect(model.scripts == [shell, deploy])
    }

    @Test func editingAPlaceRemovedElsewhereIsRefusedAndAddingStillWorks() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        try VoiceCommandStore.write(VoiceCommandConfig(), to: dir)
        let file = dir.appendingPathComponent(VoiceCommandStore.fileName)
        let before = try String(contentsOf: file, encoding: .utf8)
        var edited = mail
        edited.say = ["email"]
        #expect(model.save(edited, replacing: "Mail") == VoiceCommandsSettingsModel.staleEditMessage)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
        #expect(model.save(edited, replacing: nil) == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).places == [edited])
    }

    @Test func aRenameKeepsTheCommandsIdentity() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = VoiceCommandScript(id: "a1", name: "Deploy", run: ["/bin/deploy"])
        _ = model.saveScript(original, replacing: nil)
        var renamed = original
        renamed.name = "Release"
        #expect(model.saveScript(renamed, replacing: "Deploy") == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).commands == [.script(renamed)])
        let newcomer = VoiceCommandScript(id: "b2", name: "Deploy", run: ["/bin/other"])
        #expect(model.saveScript(newcomer, replacing: nil) == nil)
        #expect(model.commands.map(\.id) == ["a1", "b2"])
    }

    @Test func scriptValidationExplainsWhatPreventsSavingWithoutWriting() {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.scriptIssue(deploy) == nil)
        #expect(model.scriptIssue(VoiceCommandScript(name: "", run: ["/bin/tool"])) != nil)
        #expect(model.scriptIssue(VoiceCommandScript(name: "Tool", run: ["tool"]))
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(VoiceCommandStore.fileName).path))

        _ = model.saveScript(deploy, replacing: nil)
        #expect(model.scriptIssue(VoiceCommandScript(id: "other", name: "deploy", run: ["/bin/x"])) == "Another command already uses this name.")
        #expect(model.scriptIssue(deploy) == nil)
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
        #expect(result.summary == "Run Deploy")
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
        #expect(draft.script == VoiceCommandScript(
            id: draft.commandId, name: "Deploy", say: ["ship", "release"], run: ["~/bin/deploy", "--env", "", "  {text}  "]))
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
        draft.choose(VoiceCommandShortcut(name: "Journal Entry"))
        #expect(VoiceCommandExample.make(for: .script(draft.script))
                == VoiceCommandExample(heard: "journal entry", result: "Runs the shortcut \u{201C}Journal Entry\u{201D}."))
        draft.name = "journal"
        draft.input = "Note: {text}"
        #expect(VoiceCommandExample.make(for: .script(draft.script))
                == VoiceCommandExample(heard: "journal buy milk", result: "Runs the shortcut \u{201C}Journal Entry\u{201D} with \u{201C}Note: buy milk\u{201D} as its input."))
    }
}
