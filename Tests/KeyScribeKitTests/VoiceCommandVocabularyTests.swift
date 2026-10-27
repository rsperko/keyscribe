import Testing
@testable import KeyScribeKit

struct VoiceCommandVocabularyTests {
    private func plan(
        mode: Mode, globalWords: [String] = [], globalRules: [ReplacementsSet.Rule] = []
    ) -> ResolvedConfig {
        ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(words: globalWords),
            replacements: ReplacementsSet(rules: globalRules), connections: ConnectionSet(), fragments: [:])
    }

    private func commands(words: [String] = [], rules: [ReplacementsSet.Rule] = []) -> Mode {
        var mode = Mode.voiceCommands
        mode.dictionary.words = words
        mode.replacements.rules = rules
        return mode
    }

    @Test func aReplacementRepairsAMisheardVerb() {
        let mode = commands(rules: [.init(heard: "bitch to", replace: "switch to", regex: false)])
        #expect(plan(mode: mode).voiceCommandText(heard: "Bitch to Ghostty.", mode: mode) == "switch to Ghostty.")
    }

    @Test func theMiddleInputRecipeRunsTheSavedActionWithTheCapturedWordsAndLeavesNavigationAlone() {
        let rule = ReplacementsSet.Rule(
            heard: #"(?i)^\s*go\s+to\s+(.+?)\s+manager[.!?]?\s*$"#, replace: "run manager $1", regex: true)
        let mode = commands(rules: [rule])
        let plan = plan(mode: mode)
        let manager = VoiceCommandScript(name: "Manager", run: ["/bin/nav", "{text}"])
        let read = plan.voiceCommandText(heard: "Go to project alpha manager.", mode: mode)
        #expect(read == "run manager project alpha")
        #expect(VoiceCommandResolver.resolve(read, catalog: VoiceCommandCatalog(scripts: [manager]))
                == .action(.script(manager, arguments: ["project alpha"])))
        #expect(plan.voiceCommandText(heard: "go to Slack", mode: mode) == "go to Slack")
    }

    @Test func aRegexReplacementRepairsEveryMishearingItCovers() {
        let mode = commands(rules: [.init(heard: #"\b(?:bitch|which|stitch) to\b"#, replace: "switch to", regex: true)])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "Which to Safari", mode: mode) == "switch to Safari")
        #expect(plan.voiceCommandText(heard: "stitch to Safari", mode: mode) == "switch to Safari")
    }

    @Test func aDictionaryWordSnapsAMisheardTargetToItsRealName() {
        let mode = commands(words: ["herdr"])
        #expect(plan(mode: mode).voiceCommandText(heard: "switch to herder", mode: mode) == "switch to herdr")
    }

    @Test(arguments: [
        "switch two", "switch too", "which to", "which two", "which too",
        "witch to", "witch two", "witch too", "go two", "go too",
    ])
    func soundAlikePrefixesAllowTargetCorrectionWithoutRewritingThePrefix(_ prefix: String) {
        let mode = commands(words: ["herdr"])
        let heard = "\(prefix) herder"
        let corrected = plan(mode: mode).voiceCommandText(heard: heard, mode: mode)
        #expect(corrected == "\(prefix) herdr")
        #expect(VoiceCommandGrammar.parse(corrected) == .focus(target: "herdr", reach: .running))
    }

    @Test func aPunctuatedSoundAlikePrefixStillAllowsTargetCorrection() {
        let mode = commands(words: ["herdr"])
        #expect(plan(mode: mode).voiceCommandText(heard: "Witch-too, the herder.", mode: mode)
            == "Witch-too, the herdr.")
    }

    @Test func aDictionaryWordNeverRewritesTheCommandWords() {
        let mode = commands(words: ["Lunch", "Bach"])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "launch Safari", mode: mode) == "launch Safari")
        #expect(plan.voiceCommandText(heard: "go back", mode: mode) == "go back")
        #expect(plan.voiceCommandText(heard: "Launch lunch.", mode: mode) == "Launch Lunch.")
    }

    @Test func aDictionaryWordFixesOnlyTheTargetAfterAReplacementRepairsTheVerb() {
        let mode = commands(words: ["herdr"], rules: [.init(heard: "bitch to", replace: "switch to", regex: false)])
        #expect(plan(mode: mode).voiceCommandText(heard: "Bitch to herder", mode: mode) == "switch to herdr")
    }

    @Test func theTargetIsFoundHoweverTheVerbIsPunctuated() {
        let mode = commands(words: ["herdr"])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "Switch-to herder", mode: mode) == "Switch-to herdr")
        #expect(plan.voiceCommandText(heard: "Focus on the herder", mode: mode) == "Focus on the herdr")
    }

    @Test func aWholeUtteranceReplacementBecomesTheCommand() {
        let mode = commands(rules: [.init(heard: "code", replace: "switch to Visual Studio Code", regex: false)])
        #expect(plan(mode: mode).voiceCommandText(heard: "Code.", mode: mode) == "switch to Visual Studio Code")
    }

    @Test func aReturnMarkerOnAWholeUtteranceReplacementIsDropped() {
        let mode = commands(rules: [.init(heard: "code", replace: "switch to Visual Studio Code<CR>", regex: true)])
        #expect(plan(mode: mode).voiceCommandText(heard: "Code.", mode: mode) == "switch to Visual Studio Code")
    }

    @Test func globalVocabularyAppliesUnlessTheModeLeavesItOut() {
        let global = [ReplacementsSet.Rule(heard: "switch to", replace: "swap", regex: false)]
        var mode = commands()
        #expect(plan(mode: mode, globalRules: global).voiceCommandText(heard: "switch to Safari", mode: mode) == "swap Safari")
        mode.replacements.includeGlobal = false
        #expect(plan(mode: mode, globalRules: global).voiceCommandText(heard: "switch to Safari", mode: mode) == "switch to Safari")
    }

    @Test func withoutTheVoiceCommandsModeACommandIsReadAsHeard() {
        let plan = ResolvedConfig(
            modes: [.direct], dictionary: DictionarySet(words: ["herdr"]),
            replacements: ReplacementsSet(), connections: ConnectionSet(), fragments: [:])
        #expect(plan.voiceCommandText(heard: "switch to herder") == "switch to herder")
    }

    @Test func spokenEditingCommandsNeverReachTheParser() {
        let mode = commands()
        #expect(plan(mode: mode).voiceCommandText(heard: "go to new line", mode: mode) == "go to new line")
    }

    @Test func theDictionaryLeavesTheWordsPassedToAScriptAlone() {
        let mode = commands(words: ["Postgres"])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "run deploy postgrass", mode: mode)
            == "run deploy postgrass")
        #expect(plan.voiceCommandText(heard: "switch to postgrass", mode: mode) == "switch to Postgres")
    }

    @Test func theDictionaryNeverTurnsAPhraseIntoAScript() {
        let mode = commands(words: ["herdr", "Postgres"])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "run herder postgrass", mode: mode)
            == "run herder postgrass")
        #expect(plan.voiceCommandText(heard: "run herder", mode: mode) == "run herder")
        #expect(plan.voiceCommandText(heard: "switch to herder", mode: mode) == "switch to herdr")
    }
}
