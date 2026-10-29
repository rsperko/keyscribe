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

    @Test func theDictionaryCorrectsTheWordsPassedToASavedCommandButNotItsName() {
        let mode = commands(words: ["Metafield", "Jaspar"])
        let plan = plan(mode: mode)
        let jasper = VoiceCommandScript(name: "Jasper", run: ["/bin/jasper", "{text}"])
        let read = plan.voiceCommandText(heard: "Jasper, fix the meta field errors.", mode: mode, scripts: [jasper])
        #expect(read == "Jasper, fix the Metafield errors.")
        #expect(VoiceCommandResolver.resolve(read, catalog: VoiceCommandCatalog(scripts: [jasper]))
                == .action(.script(jasper, arguments: ["fix the Metafield errors"])))
    }

    @Test func theDictionaryCorrectsTheWordsAfterRunAndASavedName() {
        let mode = commands(words: ["Postgres"])
        let deploy = VoiceCommandScript(name: "deploy", run: ["/bin/deploy", "{text}"])
        #expect(plan(mode: mode).voiceCommandText(heard: "run deploy postgrass", mode: mode, scripts: [deploy])
            == "run deploy Postgres")
    }

    @Test func theDictionaryCorrectsTheWordsAWholeTakeRuleHandsToASavedCommand() {
        let rule = ReplacementsSet.Rule(
            heard: #"(?s)^\s*(.*?)[\s,.!?]*\bend of transmission[\s,.!?]*$"#, replace: "jasper $1", regex: true)
        let mode = commands(words: ["Metafield"], rules: [rule])
        let jasper = VoiceCommandScript(name: "Jasper", run: ["/bin/jasper", "{text}"])
        #expect(plan(mode: mode).voiceCommandText(
            heard: "Find the meta field errors. End of transmission.", mode: mode, scripts: [jasper])
            == "jasper Find the Metafield errors")
    }

    @Test func theDictionaryCorrectsAPlacesFindText() {
        let mode = commands(words: ["Metafield"])
        let docs = VoiceCommandPlace(name: "Docs", target: .app(bundleId: "com.example.docs"))
        #expect(plan(mode: mode).voiceCommandText(heard: "docs meta field", mode: mode, places: [docs])
            == "docs Metafield")
    }

    @Test func withoutASavedCommandTheWordsAreLeftAsHeard() {
        let mode = commands(words: ["Postgres"])
        #expect(plan(mode: mode).voiceCommandText(heard: "run deploy postgrass", mode: mode)
            == "run deploy postgrass")
        #expect(plan(mode: mode).voiceCommandText(heard: "switch to postgrass", mode: mode) == "switch to Postgres")
    }

    @Test func aCorrectionNeverChangesWhichSavedCommandRuns() {
        let mode = commands(words: ["Postgres"])
        let plan = plan(mode: mode)
        let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["/bin/deploy", "{text}"])
        let deployPostgres = VoiceCommandScript(name: "Deploy Postgres", say: ["ship Postgres"], run: ["/bin/dp", "{text}"])
        let scripts = [deploy, deployPostgres]
        for heard in ["Deploy postgrass", "run deploy postgrass", "ship postgrass"] {
            let read = plan.voiceCommandText(heard: heard, mode: mode, scripts: scripts)
            #expect(read == heard)
            #expect(VoiceCommandResolver.resolve(read, catalog: VoiceCommandCatalog(scripts: scripts))
                    == .action(.script(deploy, arguments: ["postgrass"])))
        }
    }

    @Test func aCaptureHoldingTheCommandNameNeverChangesWhichCommandRuns() {
        let mode = commands(words: ["Postgres"], rules: [.init(heard: "^go (.*)$", replace: "$1", regex: true)])
        let deploy = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy", "{text}"])
        let deployPostgres = VoiceCommandScript(name: "Deploy Postgres", run: ["/bin/dp", "{text}"])
        #expect(plan(mode: mode).voiceCommandText(heard: "go deploy postgrass", mode: mode, scripts: [deploy, deployPostgres])
            == "deploy postgrass")
    }

    @Test func aCaptureNeverHasItsCommandWordsCorrected() {
        let mode = commands(words: ["Lunch", "herdr"], rules: [.init(heard: "^wrapped (.*)$", replace: "$1", regex: true)])
        let plan = plan(mode: mode)
        #expect(plan.voiceCommandText(heard: "wrapped launch Safari", mode: mode) == "launch Safari")
        #expect(plan.voiceCommandText(heard: "wrapped switch to herder", mode: mode) == "switch to herdr")
        #expect(plan.voiceCommandText(heard: "wrapped lunch herder", mode: mode) == "lunch herder")
    }

    @Test func aWholeTakeRulesOwnTextIsNeverCorrected() {
        let mode = commands(words: ["Postgres"], rules: [.init(heard: "shortcut", replace: "Deploy postgrass", regex: false)])
        let deploy = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy", "{text}"])
        #expect(plan(mode: mode).voiceCommandText(heard: "Shortcut.", mode: mode, scripts: [deploy]) == "Deploy postgrass")
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
