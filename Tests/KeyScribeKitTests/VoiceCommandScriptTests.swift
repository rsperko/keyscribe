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

    @Test func rejectsASpokenNameThatIsACommandWord() {
        #expect(VoiceCommandScript(name: "Open", run: ["/bin/x"]).issue
            == "Name: \u{201C}Open\u{201D} is already a command word. Choose another spoken name.")
        #expect(VoiceCommandScript(name: "Tool", say: ["go"], run: ["/bin/x"]).issue
            == "Spoken name: \u{201C}go\u{201D} is already a command word. Choose another spoken name.")
        #expect(VoiceCommandScript(name: "Open ticket", run: ["/bin/x", "{text}"]).issue == nil)
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

    @Test func aScriptWithoutTextRunsOnItsNameAlone() {
        #expect(resolve("Herdr.", scripts: [herdr]) == .action(.script(herdr, arguments: ["attach"])))
    }

    @Test func aScriptWithoutTextAlsoRunsAfterAFocusVerb() {
        #expect(resolve("switch to herdr", scripts: [herdr]) == .action(.script(herdr, arguments: ["attach"])))
    }

    @Test func aScriptWithoutTextIgnoresAnUtteranceWithMoreWords() {
        #expect(resolve("herdr please", scripts: [herdr]) == .notACommand)
    }

    @Test func whatFollowsTheNameBecomesTheText() {
        #expect(resolve("Deploy staging.", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "staging"])))
        #expect(resolve("ship, Staging-2 now!", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "Staging-2 now"])))
    }

    @Test func theTextFollowsAFocusVerbToo() {
        #expect(resolve("go to deploy production", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "production"])))
    }

    @Test func aScriptThatTakesTextNeedsSome() {
        #expect(resolve("deploy.", scripts: [deploy]) == .scriptNeedsText("Deploy"))
    }

    @Test func theNameMustBeWholeWords() {
        #expect(resolve("deployment staging", scripts: [deploy]) == .notACommand)
    }

    @Test func theLongestSpokenNameWins() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let newTicket = VoiceCommandScript(name: "Ticket new", run: ["/bin/ticket", "new", "{text}"])
        #expect(resolve("ticket new login bug", scripts: [ticket, newTicket])
            == .action(.script(newTicket, arguments: ["new", "login bug"])))
    }

    @Test func anIncompleteLongerNameNeverRunsTheShorterScript() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let newTicket = VoiceCommandScript(name: "Ticket new", run: ["/bin/ticket", "new", "{text}"])
        #expect(resolve("ticket new.", scripts: [ticket, newTicket]) == .scriptNeedsText("Ticket new"))
        #expect(resolve("ticket old", scripts: [ticket, newTicket]) == .action(.script(ticket, arguments: ["old"])))
    }

    @Test func aLongerNameWithoutTextGivesWayWhenMoreWordsFollow() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let board = VoiceCommandScript(name: "Ticket board", run: ["/bin/board"])
        #expect(resolve("ticket board", scripts: [ticket, board]) == .action(.script(board, arguments: [])))
        #expect(resolve("ticket board two", scripts: [ticket, board]) == .action(.script(ticket, arguments: ["board two"])))
    }

    @Test func twoScriptsWithTheSameSpokenNameAreAmbiguous() {
        let a = VoiceCommandScript(name: "Build", run: ["/bin/a"])
        let b = VoiceCommandScript(name: "Builder", say: ["build"], run: ["/bin/b"])
        #expect(resolve("build", scripts: [a, b]) == .ambiguous(["Build", "Builder"]))
    }

    @Test func aScriptBeatsAnAppOfTheSameName() {
        let script = VoiceCommandScript(name: "Ghostty", run: ["/bin/ghostty-layout"])
        #expect(resolve("switch to ghostty", scripts: [script], running: [ghostty])
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

    @Test func theCommandLineQuotesAProgramPathWithSpacesButKeepsItsHome() {
        let script = VoiceCommandScript(name: "Note", run: ["~/My Scripts/note", "{text}"])
        #expect(script.commandLine(arguments: ["hi"]) == "~/'My Scripts/note' hi")
        let absolute = VoiceCommandScript(name: "Note", run: ["/opt/my tools/note"])
        #expect(absolute.commandLine(arguments: []) == "'/opt/my tools/note'")
    }
}
