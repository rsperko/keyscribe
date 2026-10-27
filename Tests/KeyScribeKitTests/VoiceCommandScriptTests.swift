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
            transcript, catalog: VoiceCommandCatalog(
                places: places, scripts: scripts, runningApps: running, tabs: [], windows: .complete([])))
    }

    @Test func decodesScriptsBesidePlaces() throws {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Gmail"
        url = "https://mail.google.com/"

        [[command]]
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

    private static let interpreters = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "osascript", "python", "perl", "ruby", "node",
        "nodejs", "swift", "awk", "gawk", "mawk", "nawk", "env",
    ]

    @Test func refusesAnInterpreterGivenSpokenText() {
        let script = VoiceCommandScript(name: "X", run: ["/bin/sh", "-c", "{text}"])
        #expect(script.issue == nil)
        #expect(script.executionRefusal()
            == "With {text}, “sh” could run spoken words as code. Put the logic in an executable script file and choose that file instead.")
    }

    @Test(arguments: interpreters)
    func refusesEveryKnownInterpreterGivenSpokenText(_ name: String) {
        #expect(VoiceCommandScript(name: "X", run: ["/usr/bin/\(name)", "-c", "{text}"]).executionRefusal()?.hasPrefix("With {text}, “\(name)”") == true)
        #expect(VoiceCommandScript(name: "X", run: ["/usr/bin/\(name)", "-c", "echo hi"]).executionRefusal() == nil)
    }

    @Test(arguments: [
        ["/opt/homebrew/bin/python3", "-c", "{text}"],
        ["/opt/homebrew/bin/python3.12", "-c", "{text}"],
        ["/usr/bin/Python3", "-c", "{text}"],
        ["/BIN/BASH", "-c", "{text}"],
        ["~/.local/bin/node22", "-e", "{text}"],
        ["/usr/bin/env", "sh", "-c", "{text}"],
        ["/usr/bin/ruby", "--input={text}"],
        ["/bin/zsh", "-c", "{text}", "{text}"],
        ["/bin/sh", "/Users/alex/bin/note.sh", "{text}"],
        ["/usr/bin/python3", "/Users/alex/bin/note.py", "say {text} now"],
    ])
    func refusesInterpreterInvocationsThatUseTheText(_ run: [String]) {
        let name = (run[0] as NSString).lastPathComponent
        #expect(VoiceCommandScript(name: "X", run: run).executionRefusal()?.hasPrefix("With {text}, “\(name)”") == true)
    }

    @Test(arguments: [
        (["/usr/bin/nice", "-n", "10", "/bin/sh", "-c", "{text}"], "sh"),
        (["/usr/bin/xcrun", "swift", "-e", "{text}"], "swift"),
        (["/usr/bin/xcrun", "--sdk", "macosx", "swift", "-e", "{text}"], "swift"),
        (["/usr/bin/nohup", "/opt/homebrew/bin/python3.12", "-c", "{text}"], "python3.12"),
        (["/usr/bin/caffeinate", "-i", "/usr/bin/env", "sh", "-c", "{text}"], "env"),
        (["/usr/bin/timeout", "5", "/bin/sh", "-c", "{text}"], "sh"),
        (["/usr/bin/timeout", "-k", "1", "--", "5", "/bin/sh", "-c", "{text}"], "sh"),
        (["/usr/bin/nice", "/usr/bin/nohup", "/usr/bin/perl", "-e", "{text}"], "perl"),
        (["/usr/bin/nice", "{text}"], "nice"),
    ])
    func refusesAWrapperThatLaunchesAnInterpreterWithTheText(_ run: [String], interpreter: String) {
        #expect(VoiceCommandScript(name: "X", run: run).executionRefusal()?.hasPrefix("With {text}, “\(interpreter)”") == true)
    }

    @Test func refusesAProgramWhoseResolvedFileIsAnInterpreter() {
        let script = VoiceCommandScript(name: "X", run: ["/Users/alex/bin/mysh", "-c", "{text}"])
        #expect(script.executionRefusal() == nil)
        #expect(script.executionRefusal(resolvedProgram: "/bin/zsh")?.hasPrefix("With {text}, “zsh”") == true)
        #expect(script.executionRefusal(resolvedProgram: "/Users/alex/bin/mysh") == nil)
    }

    @Test(arguments: [
        ["/usr/bin/nice", "/Users/alex/bin/note.sh", "{text}"],
        ["/usr/bin/xcrun", "notarytool", "history", "{text}"],
        ["/usr/bin/nice", "/bin/sh", "/Users/alex/bin/fixed.sh"],
        ["/usr/bin/nice", "/Users/alex/bin/record", "--category", "python", "{text}"],
        ["/usr/bin/timeout", "5", "/usr/local/bin/tool", "sh", "{text}"],
        ["/usr/bin/xcrun", "--sdk", "python", "notarytool", "{text}"],
    ])
    func allowsAWrapperAroundAnOrdinaryProgramOrWithoutText(_ run: [String]) {
        #expect(VoiceCommandScript(name: "X", run: run).executionRefusal() == nil)
    }

    @Test(arguments: [
        ["/usr/bin/osascript", "-e", "tell application \"Music\" to play"],
        ["/usr/bin/env", "FOO=1", "/usr/local/bin/tool"],
        ["/Users/alex/bin/note.sh", "{text}"],
        ["~/bin/note", "{text}"],
        ["/usr/local/bin/bashful", "{text}"],
        ["/usr/local/bin/awkward", "{text}"],
        ["/usr/local/bin/python-tool", "{text}"],
        ["/usr/local/bin/python3x", "{text}"],
        ["/usr/local/bin/sh.py", "{text}"],
        ["/usr/local/bin/mysh", "{text}"],
    ])
    func allowsOrdinaryProgramsAndInterpretersWithoutText(_ run: [String]) {
        #expect(VoiceCommandScript(name: "X", run: run).issue == nil)
        #expect(VoiceCommandScript(name: "X", run: run).executionRefusal() == nil)
    }

    @Test func earlierProgramErrorsComeBeforeTheInterpreterRule() {
        #expect(VoiceCommandScript(name: "X", run: ["sh", "-c", "{text}"]).issue
            == "Program: Use a full path, such as /usr/local/bin/tool or ~/bin/tool.")
        #expect(VoiceCommandScript(name: "X", run: ["/bin/sh\n", "{text}"]).issue == "Program: Use one line.")
        #expect(VoiceCommandScript(name: "X", run: ["/bin/sh{text}", "{text}"]).issue
            == "Program: {text} can only be used in an argument.")
        #expect(VoiceCommandScript(name: "X", run: ["/bin/sh", "-c", "a\nb"]).issue == "Argument 2: Use one line.")
    }

    @Test func aRefusedScriptLeavesTheRestOfTheFileLoaded() throws {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Gmail"
        url = "https://mail.google.com/"

        [[command]]
        name = "Shell"
        run = ["/bin/sh", "-c", "{text}"]
        """
        let config = try VoiceCommandStore.decode(from: toml)
        #expect(config.places.map(\.name) == ["Gmail"])
        #expect(config.scripts.map(\.name) == ["Shell"])
        #expect(config.scripts[0].executionRefusal() != nil)
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
        #expect(config.issue == "command \"Deploy\": another command already uses this name")
    }

    @Test func rejectsDuplicateScriptNames() {
        let config = VoiceCommandConfig(scripts: [deploy, VoiceCommandScript(name: "deploy", run: ["/bin/x"])])
        #expect(config.issue == "command \"deploy\": another command already uses this name")
    }

    @Test func aScriptRunsByItsNameAlone() {
        #expect(resolve("Herdr.", scripts: [herdr]) == .action(.script(herdr, arguments: ["attach"])))
        #expect(resolve("deploy staging", scripts: [deploy]) == .action(.script(deploy, arguments: ["--env", "staging"])))
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

    @Test func soundAlikeAppPrefixesNeverRunAnAction() {
        let shortcut = VoiceCommandScript(name: "Journal", shortcut: .init(name: "Journal"))
        #expect(resolve("witch too herdr", scripts: [herdr]) == .noMatch("herdr"))
        #expect(resolve("go two journal", scripts: [shortcut]) == .noMatch("journal"))
    }

    @Test func soundAlikePrefixesInsideActionInputStayAsSpoken() {
        #expect(resolve("run ship Which to choose, witch too?", scripts: [deploy])
            == .action(.script(deploy, arguments: ["--env", "Which to choose, witch too"])))
    }

    @Test func aScriptWithoutTextSaysItTakesNoWords() {
        #expect(resolve("run herdr please", scripts: [herdr]) == .takesNoText("herdr"))
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

    @Test func aLongerNameWithoutTextNeverGivesWayToTheShorterOne() {
        let ticket = VoiceCommandScript(name: "Ticket", run: ["/bin/ticket", "{text}"])
        let board = VoiceCommandScript(name: "Ticket board", run: ["/bin/board"])
        #expect(resolve("run ticket board", scripts: [ticket, board]) == .action(.script(board, arguments: [])))
        #expect(resolve("run ticket board two", scripts: [ticket, board]) == .takesNoText("Ticket board"))
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

        [[command]]
        name = "Journal"
        say = ["log"]
        shortcut = "Journal Entry"
        shortcut_id = "6E982466-2036-4362-BDEC-983051029F6A"
        input = "{text}"

        [[command]]
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
        let both = "schema_version = 1\n[[command]]\nname = \"X\"\nrun = [\"/bin/x\"]\nshortcut = \"X\"\n"
        let neither = "schema_version = 1\n[[command]]\nname = \"X\"\n"
        let inputOnAProgram = "schema_version = 1\n[[command]]\nname = \"X\"\nrun = [\"/bin/x\"]\ninput = \"{text}\"\n"
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

struct VoiceCommandScriptOptionTests {
    private let channels = VoiceCommandScript(name: "Channel", run: ["~/bin/channel", "{text}"])

    private func option(_ value: String, _ label: String, script: VoiceCommandScript? = nil) -> VoiceCommandCandidate {
        .option(VoiceCommandScriptOption(script: script ?? channels, arguments: ["gen"], value: value, label: label))
    }

    @Test func anOptionReadsAsItsLabelUnderItsScript() {
        let candidate = option("C1", "#general")
        #expect(candidate.name == "#general")
        #expect(candidate.detail(appName: { _ in nil }, among: [candidate]) == "Channel")
        #expect(!candidate.takesWords)
    }

    @Test func optionsOfOneScriptAreToldApartByValue() {
        #expect(option("C1", "#general").identity != option("C2", "#general").identity)
    }

    @Test func choosingAnOptionRunsTheScriptAgainWithItsArgumentsAndTheChoice() {
        let catalog = VoiceCommandCatalog(places: [], scripts: [channels])
        #expect(VoiceCommandResolver.resolve(option("C1", "#general"), text: "", reach: .opening, catalog: catalog)
            == .action(.script(channels, arguments: ["gen"], choice: "C1")))
    }

    @Test func anOptionWhoseScriptWasRemovedIsUnavailable() {
        let catalog = VoiceCommandCatalog(places: [], scripts: [])
        #expect(VoiceCommandResolver.resolve(option("C1", "#general"), text: "", reach: .opening, catalog: catalog) == .unavailable("Channel"))
    }

    @Test func anOptionWhoseScriptChangedIsUnavailable() {
        let edited = VoiceCommandScript(name: "Channel", run: ["~/bin/other", "{text}"])
        let catalog = VoiceCommandCatalog(places: [], scripts: [edited])
        #expect(VoiceCommandResolver.resolve(option("C1", "#general"), text: "", reach: .opening, catalog: catalog) == .unavailable("Channel"))
    }

    @Test func aTooLongOtherNameIsReportedAsAnOtherName() {
        let script = VoiceCommandScript(name: "Deploy", say: [String(repeating: "a", count: 257)], run: ["/usr/bin/true"])
        #expect(script.issue?.hasPrefix("Other names: ") == true)
    }
}
