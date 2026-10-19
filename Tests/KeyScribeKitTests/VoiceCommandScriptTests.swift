import Foundation
import Testing
@testable import KeyScribeKit

struct VoiceCommandScriptTests {
    private let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["~/bin/deploy", "--env", "{text}"])
    private let herdr = VoiceCommandScript(name: "herdr", run: ["/usr/local/bin/herdr", "attach"])
    private let ghostty = VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")

    private func resolve(
        _ transcript: String, scripts: [VoiceCommandScript], places: [VoiceCommandPlace] = [],
        running: [VoiceCommandCatalog.App] = []
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(
            transcript, catalog: VoiceCommandCatalog(places: places, scripts: scripts, runningApps: running))
    }

    @Test func decodesScriptsBesidePlaces() throws {
        let toml = """
        schema_version = 1

        [[place]]
        name = "Gmail"
        url = "https://mail.google.com/"

        [[script]]
        name = "Deploy"
        say = ["ship"]
        run = ["~/bin/deploy", "--env", "{text}"]
        """
        let config = try VoiceCommandStore.decode(from: toml)
        #expect(config.scripts == [deploy])
        #expect(config.places.map(\.name) == ["Gmail"])
    }

    @Test func roundTripsThroughEncode() throws {
        let config = VoiceCommandConfig(scripts: [deploy, herdr])
        #expect(try VoiceCommandStore.decode(from: VoiceCommandStore.encode(config)) == config)
    }

    @Test func takesTextOnlyWhenAnArgumentUsesThePlaceholder() {
        #expect(deploy.takesText)
        #expect(!herdr.takesText)
    }

    @Test func argumentsReplaceEveryPlaceholderAndKeepTheTextWhole() {
        let script = VoiceCommandScript(name: "Note", run: ["/bin/note", "--title={text}", "{text}"])
        #expect(script.arguments(text: "buy milk; rm -rf ~") == ["--title=buy milk; rm -rf ~", "buy milk; rm -rf ~"])
        #expect(herdr.arguments(text: "") == ["attach"])
    }

    @Test func rejectsAScriptWithNothingToRun() {
        #expect(VoiceCommandScript(name: "X", run: []).issue == "Program: Choose a program to run.")
        #expect(VoiceCommandScript(name: "X", run: [" "]).issue == "Program: Choose a program to run.")
    }

    @Test func rejectsARelativeProgram() {
        #expect(VoiceCommandScript(name: "X", run: ["deploy"]).issue
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
    }

    @Test func rejectsThePlaceholderInTheProgram() {
        #expect(VoiceCommandScript(name: "X", run: ["/bin/{text}"]).issue
            == "Program: {text} can only be used in an argument.")
    }

    @Test func rejectsAMultilineArgument() {
        #expect(VoiceCommandScript(name: "X", run: ["/bin/x", "a\nb"]).issue == "Argument 1: Use one line.")
    }

    @Test func commandWordsCanBeScriptNamesBecauseRunSeparatesThem() {
        #expect(VoiceCommandScript(name: "Open", run: ["/bin/x"]).issue == nil)
        #expect(VoiceCommandScript(name: "Tool", say: ["go"], run: ["/bin/x"]).issue == nil)
        #expect(VoiceCommandScript(name: "Open ticket", run: ["/bin/x", "{text}"]).issue == nil)
        let back = VoiceCommandScript(name: "Go back", run: ["/bin/x"])
        #expect(back.issue == nil)
        #expect(resolve("run go back", scripts: [back]) == .action(.script(back, arguments: [])))
    }

    @Test func rejectsAScriptNamedLikeAPlace() {
        let config = VoiceCommandConfig(
            places: [VoiceCommandPlace(name: "Deploy", target: .app(bundleId: "com.example"))], scripts: [deploy])
        #expect(config.issue == "script \"Deploy\": a place or script already uses this name")
    }

    @Test func rejectsDuplicateScriptNames() {
        let config = VoiceCommandConfig(scripts: [deploy, VoiceCommandScript(name: "deploy", run: ["/bin/x"])])
        #expect(config.issue == "script \"deploy\": a place or script already uses this name")
    }

    @Test func aBareScriptNameDoesNotRunAnything() {
        #expect(resolve("Herdr.", scripts: [herdr]) == .notACommand)
        #expect(resolve("deploy staging", scripts: [deploy]) == .notACommand)
    }

    @Test func runUsesTheSpokenNameRatherThanTheProgramFileName() {
        let foo = VoiceCommandScript(name: "Foo", run: ["~/bin/bar.sh"])
        #expect(resolve("Run foo!", scripts: [foo]) == .action(.script(foo, arguments: [])))
    }

    @Test func runAcceptsAliasesAndPreservesTheSpokenArguments() {
        #expect(resolve("Run ship, Staging-2 now!", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "Staging-2 now"])))
        #expect(resolve("run deploy", scripts: [deploy]) == .scriptNeedsText("Deploy"))
    }

    @Test func runNeverLaunchesAnAppOrFuzzilyMatchesAScript() {
        #expect(resolve("run ghostty", scripts: [], running: [ghostty]) == .scriptNotFound("ghostty"))
        #expect(resolve("run herder", scripts: [herdr]) == .scriptNotFound("herder"))
    }

    @Test func runKeepsTheLongestNameAndAmbiguityRules() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let longer = VoiceCommandScript(name: "Ticket new", run: ["/bin/ticket", "new", "{text}"])
        #expect(resolve("run ticket new", scripts: [ticket, longer]) == .scriptNeedsText("Ticket new"))
        let other = VoiceCommandScript(name: "Other", say: ["ship"], run: ["/bin/other", "{text}"])
        #expect(ambiguousNames(resolve("run ship staging", scripts: [deploy, other])) == ["Deploy", "Other"])
    }

    @Test func appVerbsNeverRunAScript() {
        #expect(resolve("switch to herdr", scripts: [herdr]) == .noMatch("herdr"))
        #expect(resolve("open herdr", scripts: [herdr]) == .noMatch("herdr"))
    }

    @Test func aScriptWithoutTextIgnoresAnUtteranceWithMoreWords() {
        #expect(resolve("run herdr please", scripts: [herdr]) == .scriptNotFound("herdr please"))
    }

    @Test func whatFollowsTheNameBecomesTheText() {
        #expect(resolve("Run deploy staging.", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "staging"])))
        #expect(resolve("run ship, Staging-2 now!", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "Staging-2 now"])))
    }

    @Test func appVerbsDoNotPassWordsToAScript() {
        #expect(resolve("go to deploy production", scripts: [deploy]) == .noMatch("deploy production"))
    }

    @Test func aScriptThatTakesTextNeedsSome() {
        #expect(resolve("run deploy.", scripts: [deploy]) == .scriptNeedsText("Deploy"))
    }

    @Test func theNameMustBeWholeWords() {
        #expect(resolve("run deployment staging", scripts: [deploy]) == .scriptNotFound("deployment staging"))
    }

    @Test func theLongestSpokenNameWins() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let newTicket = VoiceCommandScript(name: "Ticket new", run: ["/bin/ticket", "new", "{text}"])
        #expect(resolve("run ticket new login bug", scripts: [ticket, newTicket])
            == .action(.script(newTicket, arguments: ["new", "login bug"])))
    }

    @Test func anIncompleteLongerNameNeverRunsTheShorterScript() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let newTicket = VoiceCommandScript(name: "Ticket new", run: ["/bin/ticket", "new", "{text}"])
        #expect(resolve("run ticket new.", scripts: [ticket, newTicket]) == .scriptNeedsText("Ticket new"))
        #expect(resolve("run ticket old", scripts: [ticket, newTicket]) == .action(.script(ticket, arguments: ["old"])))
    }

    @Test func aLongerNameWithoutTextGivesWayWhenMoreWordsFollow() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let board = VoiceCommandScript(name: "Ticket board", run: ["/bin/board"])
        #expect(resolve("run ticket board", scripts: [ticket, board]) == .action(.script(board, arguments: [])))
        #expect(resolve("run ticket board two", scripts: [ticket, board]) == .action(.script(ticket, arguments: ["board two"])))
    }

    @Test func twoScriptsWithTheSameSpokenNameAreAmbiguous() {
        let a = VoiceCommandScript(name: "Build", run: ["/bin/a"])
        let b = VoiceCommandScript(name: "Builder", say: ["build"], run: ["/bin/b"])
        #expect(ambiguousNames(resolve("run build", scripts: [a, b])) == ["Build", "Builder"])
    }

    @Test func theVerbChoosesBetweenAnAppAndAScriptOfTheSameName() {
        let script = VoiceCommandScript(name: "Ghostty", run: ["/bin/ghostty-layout"])
        #expect(resolve("switch to ghostty", scripts: [script], running: [ghostty])
            == .action(.app(ghostty)))
        #expect(resolve("run ghostty", scripts: [script], running: [ghostty])
            == .action(.script(script, arguments: [])))
    }

    @Test func goBackIsNeverAScript() {
        #expect(resolve("go back", scripts: [deploy]) == .action(.goBack))
    }

    @Test func aScriptIsNeverMatchedByANearMiss() {
        #expect(resolve("switch to herder", scripts: [herdr]) == .noMatch("herder"))
    }

    @Test func detailShowsTheProgramAndItsArguments() {
        let action = VoiceCommandAction.script(deploy, arguments: ["--env", "staging two"])
        #expect(action.summary(appName: { _ in nil }) == "Deploy")
        #expect(action.detail(appName: { _ in nil })
            == "Runs ~/bin/deploy --env 'staging two' in the background.")
    }

    @Test func theCommandLineQuotesArgumentsTheWayAShellWould() {
        #expect(deploy.commandLine(arguments: ["--env", "staging"]) == "~/bin/deploy --env staging")
        #expect(deploy.commandLine(arguments: ["buy milk; rm -rf ~", "", "  ", "it's", "~/x"])
            == "~/bin/deploy 'buy milk; rm -rf ~' '' '  ' 'it'\\''s' '~/x'")
    }

    @Test func theCommandLineQuotesAnArgumentThatStartsWithAnEqualsSign() {
        #expect(deploy.commandLine(arguments: ["=sh", "a=b"]) == "~/bin/deploy '=sh' a=b")
    }

    private let journal = VoiceCommandScript(
        name: "Journal", say: ["log"],
        shortcut: VoiceCommandShortcut(name: "Journal Entry", identifier: "6E982466-2036-4362-BDEC-983051029F6A", input: "{text}"))
    private let wifi = VoiceCommandScript(name: "Wi-Fi", shortcut: VoiceCommandShortcut(name: "Share Wi-Fi"))

    @Test func decodesAShortcutBesideAScript() throws {
        let toml = """
        schema_version = 1

        [[script]]
        name = "Journal"
        say = ["log"]
        shortcut = "Journal Entry"
        shortcut_id = "6E982466-2036-4362-BDEC-983051029F6A"
        input = "{text}"

        [[script]]
        name = "Deploy"
        say = ["ship"]
        run = ["~/bin/deploy", "--env", "{text}"]
        """
        #expect(try VoiceCommandStore.decode(from: toml).scripts == [journal, deploy])
    }

    @Test func aShortcutRoundTripsInOrderWithScripts() throws {
        let config = VoiceCommandConfig(scripts: [deploy, journal, wifi, herdr])
        #expect(try VoiceCommandStore.decode(from: VoiceCommandStore.encode(config)) == config)
    }

    @Test func anEntrySetsExactlyOneOfRunOrShortcut() {
        let both = "schema_version = 1\n[[script]]\nname = \"X\"\nrun = [\"/bin/x\"]\nshortcut = \"X\"\n"
        let neither = "schema_version = 1\n[[script]]\nname = \"X\"\n"
        let inputOnAProgram = "schema_version = 1\n[[script]]\nname = \"X\"\nrun = [\"/bin/x\"]\ninput = \"{text}\"\n"
        for toml in [both, neither, inputOnAProgram] {
            #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
        }
    }

    @Test func aShortcutTakesTextOnlyWhenItsInputUsesThePlaceholder() {
        #expect(journal.takesText)
        #expect(!wifi.takesText)
        #expect(journal.isShortcut)
        #expect(!deploy.isShortcut)
        #expect(journal.run.isEmpty)
    }

    @Test func aShortcutsInputReplacesThePlaceholder() {
        let prefixed = VoiceCommandScript(name: "Todo", shortcut: VoiceCommandShortcut(name: "Add Todo", input: "Todo: {text}"))
        #expect(prefixed.arguments(text: "buy milk") == ["Todo: buy milk"])
        #expect(wifi.arguments(text: "") == [])
    }

    @Test func aShortcutRunsByItsIdentifierWhenItHasOne() {
        #expect(journal.shortcut?.target == "6E982466-2036-4362-BDEC-983051029F6A")
        #expect(wifi.shortcut?.target == "Share Wi-Fi")
    }

    @Test func rejectsAShortcutWithNothingToRun() {
        #expect(VoiceCommandScript(name: "X", shortcut: VoiceCommandShortcut(name: " ")).issue
            == "Shortcut: Choose a shortcut to run.")
        #expect(VoiceCommandScript(name: "X", shortcut: VoiceCommandShortcut(name: "A", input: "a\nb")).issue
            == "Input: Use one line.")
    }

    @Test func aShortcutResolvesWithItsInput() {
        #expect(resolve("run log, buy milk.", scripts: [journal])
            == .action(.script(journal, arguments: ["buy milk"])))
        #expect(resolve("run wi-fi", scripts: [wifi]) == .action(.script(wifi, arguments: [])))
        #expect(resolve("run journal", scripts: [journal]) == .scriptNeedsText("Journal"))
    }

    @Test func aShortcutDescribesItselfInWords() {
        let withInput = VoiceCommandAction.script(journal, arguments: ["buy milk"])
        #expect(withInput.summary(appName: { _ in nil }) == "Journal")
        #expect(withInput.detail(appName: { _ in nil })
            == "Runs the shortcut \u{201C}Journal Entry\u{201D} with \u{201C}buy milk\u{201D} as its input.")
        #expect(withInput.command(appName: { _ in nil }) == withInput.detail(appName: { _ in nil }))
        #expect(VoiceCommandAction.script(wifi, arguments: []).detail(appName: { _ in nil })
            == "Runs the shortcut \u{201C}Share Wi-Fi\u{201D}.")
    }

    @Test func parsesTheShortcutsList() {
        let output = """
        Journal Entry (6E982466-2036-4362-BDEC-983051029F6A)
        Resize (2x) (0C404F77-528C-4E8B-B42F-A63EC54E2C90)

        No identifier
        """
        #expect(VoiceCommandShortcut.parseList(output) == [
            VoiceCommandShortcut(name: "Journal Entry", identifier: "6E982466-2036-4362-BDEC-983051029F6A"),
            VoiceCommandShortcut(name: "Resize (2x)", identifier: "0C404F77-528C-4E8B-B42F-A63EC54E2C90"),
            VoiceCommandShortcut(name: "No identifier"),
        ])
    }

    @Test func theCommandLineQuotesAProgramPathWithSpacesButKeepsItsHome() {
        let script = VoiceCommandScript(name: "Note", run: ["~/My Scripts/note", "{text}"])
        #expect(script.commandLine(arguments: ["hi"]) == "~/'My Scripts/note' hi")
        let absolute = VoiceCommandScript(name: "Note", run: ["/opt/my tools/note"])
        #expect(absolute.commandLine(arguments: []) == "'/opt/my tools/note'")
    }
}
