import Testing
@testable import KeyScribeKit

struct SpokenHelpTests {
    private let rules = ReplacementsStage(rules: [
        ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false, wholeDictation: true),
        ReplacementRule(heard: #"[\s,]*\b(?:my|insert)\s+sign[- ]?off[\s,.]*"#, replace: #"\n\nBest,"#, isRegex: true),
        ReplacementRule(heard: #"(?<=x)y"#, replace: "z", isRegex: true),
    ])

    @Test func codingAgentHelpNamesTheRecipientAndUsesItsName() {
        let help = SpokenHelp.codingAgent(title: "Coding agent", recipient: "backend", example: "api", readsReplies: true, canRepeat: true, stages: [])
        #expect(help.status == "Recipient: backend")
        #expect(help.rows.map(\.said) == [
            "cancel", "go back", "open backend", "repeat that", "select backend", "tell backend run the unit tests",
            "what is backend waiting for?", "who needs me?",
        ])
        for row in help.rows { #expect(!row.effect.isEmpty) }
    }

    @Test func codingAgentHelpWithoutARecipientUsesAConversationThatExists() {
        let help = SpokenHelp.codingAgent(title: "Coding agent", recipient: nil, example: "api", readsReplies: false, canRepeat: false, stages: [])
        #expect(help.status == "No recipient selected")
        #expect(help.rows.contains { $0.said == "tell api run the unit tests" })
        #expect(!help.rows.contains { $0.said == "repeat that" })
    }

    @Test func codingAgentHelpWithNoConversationInventsNoName() {
        let help = SpokenHelp.codingAgent(title: "Coding agent", recipient: nil, example: nil, readsReplies: false, canRepeat: false, stages: [])
        #expect(help.rows.map(\.said) == ["cancel", "go back", "who needs me?"])
    }

    @Test func repeatSaysWhenThereIsNothingToRepeat() {
        let help = SpokenHelp.codingAgent(title: "Coding agent", recipient: "backend", example: nil, readsReplies: true, canRepeat: false, stages: [])
        #expect(help.rows.first { $0.said == "repeat that" }?.note == "Nothing to repeat yet")
    }

    @Test func dictationHelpListsSpokenEditsSuffixesAndRulesThatHaveExamples() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [LiveEditsStage(), rules], suffixes: [(said: "as a prompt", mode: "AI Prompt")])
        let said = help.rows.map(\.said)
        #expect(said.contains("insert tab character"))
        #expect(said.contains("scratch that"))
        #expect(said.contains("\u{2026} as a prompt"))
        #expect(said.contains("slash resume"))
        #expect(said.contains("my sign off"))
        #expect(help.rows.first { $0.said == "insert tab character" }?.effect == "Tab")
        #expect(help.rows.first { $0.said == "slash resume" } == .init(said: "slash resume", effect: "/resume", note: "Say alone"))
        #expect(help.rows.first { $0.said == "my sign off" }?.effect == "New paragraph + Best,")
        #expect(help.rows.count == said.count)
    }

    @Test func dictationWithoutSpokenEditsShowsNoEditOrClipboardPhrases() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [rules], suffixes: [])
        #expect(help.rows.map(\.said) == ["my sign off", "slash resume"])
        #expect(help.status == nil)
    }

    @Test func aModeWithNothingToSayExplainsInsteadOfShowingAnEmptyList() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [], suffixes: [])
        #expect(help.rows.isEmpty)
        #expect(help.status == SpokenHelp.noCommands)
    }

    @Test func aRuleTheTakeWouldNotApplyIsNotListed() {
        let shadowed = [
            ReplacementRule(heard: "insert new line", replace: "NEWLINE", isRegex: false),
            ReplacementRule(heard: "what can I say", replace: "help text", isRegex: false),
            ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false),
        ]
        let withEdits = SpokenHelp.dictation(
            title: "Email", stages: TakeStages.text(liveEdits: true, rules: shadowed, numbers: false, dictionary: []), suffixes: [])
        #expect(!withEdits.rows.contains { $0.effect == "NEWLINE" })
        #expect(!withEdits.rows.contains { $0.effect == "help text" })
        #expect(withEdits.rows.contains { $0.said == "slash resume" })
        let without = SpokenHelp.dictation(
            title: "Plain", stages: TakeStages.text(liveEdits: false, rules: shadowed, numbers: false, dictionary: []), suffixes: [])
        #expect(without.rows.contains { $0.effect == "NEWLINE" })
    }

    @Test func aRuleWhoseCapturedWordsLaterStagesPolishIsStillListed() {
        let rules = [ReplacementRule(heard: #"^note (.+)$"#, replace: "memo: $1", isRegex: true)]
        let help = SpokenHelp.dictation(
            title: "Email", stages: TakeStages.text(liveEdits: true, rules: rules, numbers: true, dictionary: ["Sample"]), suffixes: [])
        #expect(help.rows.contains { $0.said == "note \u{2026}" && $0.effect == "memo: \u{2026}" })
    }

    @Test func spokenEditsIncludeANewParagraph() {
        let help = SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage()], suffixes: [])
        #expect(help.rows.first { $0.said == "insert new paragraph" }?.effect == "New paragraph")
    }

    @Test func selectionHelpPromisesNoEditsOrRules() {
        let help = SpokenHelp.selection(title: "Edit Selection")
        #expect(help.rows.isEmpty)
        #expect(help.status == SpokenHelp.selectionGuidance)
    }

    @Test func voiceCommandHelpWithNoAppsInventsNone() {
        let said = SpokenHelp.voiceCommands(title: "Voice Commands", apps: [], places: [], scripts: [], stages: []).rows.map(\.said)
        #expect(said == ["cancel", "go back"])
    }

    @Test func voiceCommandHelpUsesSavedCommandsWithTheirVerbs() {
        let place = VoiceCommandPlace(name: "Reading list", target: .url("https://example.com/list"))
        let note = VoiceCommandScript(name: "New note", run: ["/bin/note", "{text}"])
        let help = SpokenHelp.voiceCommands(title: "Voice Commands", apps: ["Notes", "Safari"], places: [place], scripts: [note], stages: [])
        let said = help.rows.map(\.said)
        #expect(said == said.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(said.contains("open Notes") && said.contains("switch to Safari"))
        #expect(!said.contains { $0.contains("Slack") || $0.contains("Mail") })
        #expect(said.contains("open reading list"))
        #expect(said.contains("run new note buy milk"))
        let catalog = VoiceCommandCatalog(places: [place], scripts: [note], tabs: [], windows: .complete([]))
        for phrase in ["open reading list", "run new note buy milk"] {
            guard case .action = VoiceCommandResolver.resolve(phrase, catalog: catalog) else {
                Issue.record("\(phrase) does not run its command"); continue
            }
        }
        #expect(said.contains("go back"))
        #expect(said.contains("cancel"))
    }

    @Test func everyBuiltInPhraseIsRecognizedAsWhatItSays() {
        let agent = SpokenHelp.codingAgent(title: "", recipient: "backend", example: nil, readsReplies: true, canRepeat: true, stages: []).rows.map(\.said)
        #expect(AgentAddress.parse("tell backend run the unit tests", names: ["backend"]) == .name("backend", body: "run the unit tests"))
        #expect(AgentAddress.parse("select backend", names: ["backend"]) == .select(.name("backend", body: "")))
        #expect(AgentAddress.parse("open backend", names: ["backend"]) == .open(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse("what is backend waiting for?", names: ["backend"]) == .waiting(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse("who needs me?", names: ["backend"]) == .whoNeedsMe)
        for phrase in ["tell backend run the unit tests", "select backend", "open backend", "what is backend waiting for?", "who needs me?"] {
            #expect(agent.contains(phrase))
        }
        for (phrase, intent) in [("repeat that", VoiceCommandIntent.repeatSummary), ("go back", .goBack), ("cancel", .cancel)] {
            #expect(agent.contains(phrase))
            #expect(VoiceCommandGrammar.parse(phrase) == intent)
        }
    }
}
