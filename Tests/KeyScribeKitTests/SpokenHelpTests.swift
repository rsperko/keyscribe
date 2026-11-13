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
            "cancel", "check on all conversations", "check on backend", "go back", "open backend", "repeat that", "select backend",
            "tell backend run the unit tests", "that sounded wrong",
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
        #expect(help.rows.map(\.said) == ["cancel", "check on all conversations", "go back"])
    }

    @Test func codingAgentHelpListsSpokenEditsWordedForAMessageOnlyWhenTheyAreOn() {
        let on = SpokenHelp.codingAgent(
            title: "Coding agent", recipient: "backend", example: nil, readsReplies: false, canRepeat: false,
            stages: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []))
        let effects = Dictionary(on.rows.map { ($0.said, $0.effect) }, uniquingKeysWith: { first, _ in first })
        #expect(effects["insert tab character"] == "Tab in the message")
        #expect(effects["insert new line"] == "New line in the message")
        #expect(effects["insert clipboard contents"] == "Adds what you copied to the message")
        #expect(effects["insert clipboard as code"] == "Adds copied text to the message inside a Markdown code block")
        #expect(effects["begin verbatim \u{2026} end verbatim"] == "Keeps those words literal, without edits or rewriting")
        #expect(effects["never mind"] == "Discards this message. Nothing is sent.")
        #expect(on.rows.first { $0.said == "never mind" }?.note == "Say it last")
        #expect(on.rows.map(\.said) == on.rows.map(\.said).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let off = SpokenHelp.codingAgent(
            title: "Coding agent", recipient: "backend", example: nil, readsReplies: false, canRepeat: false,
            stages: TakeStages.text(liveEdits: false, rules: [], numbers: false, dictionary: []))
        #expect(!off.rows.contains { $0.said.hasPrefix("insert") || $0.said.contains("verbatim") || $0.said == "never mind" })
        #expect(off.rows.contains { $0.said == "tell backend run the unit tests" })
    }

    @Test func repeatSaysWhenThereIsNothingToRepeat() {
        let help = SpokenHelp.codingAgent(title: "Coding agent", recipient: "backend", example: nil, readsReplies: true, canRepeat: false, stages: [])
        #expect(help.rows.first { $0.said == "repeat that" }?.note == "There\u{2019}s nothing to repeat yet")
    }

    private func mode(_ id: String, _ name: String, phrases: [String], output: Mode.Output = .cursor) -> Mode {
        var mode = Mode(id: id, name: name)
        mode.triggerPhrases = phrases
        mode.output = output
        return mode
    }

    @Test func dictationHelpListsSpokenEditsSuffixesAndRulesThatHaveExamples() {
        let prompt = mode("ai-prompt", "AI Prompt", phrases: ["as a prompt", "as prompt"])
        let help = SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage(), rules], current: "email", eligible: [prompt])
        let said = help.rows.map(\.said)
        #expect(said.contains("insert tab character"))
        #expect(said.contains("scratch that"))
        #expect(help.suffixes == [.init(said: "\u{2026} as a prompt", effect: "Uses AI Prompt for this take")])
        #expect(!said.contains { $0.contains("as a prompt") })
        #expect(said.contains("slash resume"))
        #expect(said.contains("my sign off"))
        #expect(help.rows.first { $0.said == "insert tab character" }?.effect == "Tab")
        #expect(help.rows.first { $0.said == "slash resume" } == .init(said: "slash resume", effect: "/resume", note: "Say alone"))
        #expect(help.rows.first { $0.said == "my sign off" }?.effect == "New paragraph + Best,")
        #expect(help.rows.count == said.count)
    }

    @Test func dictationWithoutSpokenEditsShowsNoEditOrClipboardPhrases() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [rules])
        #expect(help.rows.map(\.said) == ["my sign off", "slash resume"])
        #expect(help.status == nil)
    }

    @Test func aModeWithNothingToSayExplainsInsteadOfShowingAnEmptyList() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [])
        #expect(help.rows.isEmpty)
        #expect(help.suffixes.isEmpty)
        #expect(help.status == SpokenHelp.noCommands)
    }

    @Test func aModeWithOnlySuffixesIsNotEmpty() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [], eligible: [mode("markdown", "Markdown", phrases: ["markdown"])])
        #expect(help.status == nil)
        #expect(help.suffixes.map(\.said) == ["\u{2026} markdown"])
    }

    @Test func ordinaryPhrasesComeFirstAndSuffixesFollowEachSortedAlphabetically() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [LiveEditsStage(), rules],
            eligible: [mode("z", "Zed", phrases: ["as zed"]), mode("md", "Markdown", phrases: ["as markdown"]), mode("p", "AI Prompt", phrases: ["as a prompt"])])
        let said = help.rows.map(\.said)
        #expect(said == said.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(!said.contains { $0.hasPrefix("\u{2026}") })
        #expect(help.suffixes.map(\.said) == ["\u{2026} as a prompt", "\u{2026} as markdown", "\u{2026} as zed"])
        #expect(SpokenHelp.suffixHeading == "End your dictation with")
    }

    @Test func aSuffixShowsTheConfiguredPhraseUnchangedAndOneFormPerMode() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [],
            eligible: [mode("md", "Markdown", phrases: ["markdown"]), mode("p", "AI Prompt", phrases: ["as a prompt", "as prompt"])])
        #expect(help.suffixes == [
            .init(said: "\u{2026} as a prompt", effect: "Uses AI Prompt for this take"),
            .init(said: "\u{2026} markdown", effect: "Uses Markdown for this take"),
        ])
    }

    @Test func onlySuffixesThatRouteToTheirModeAreListed() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [], current: "email",
            eligible: [
                mode("email", "Email", phrases: ["as an email"]),
                mode("agent", "Agent", phrases: ["to the agent"], output: .agent),
                mode("regex", "Regex", phrases: [#"as (?:a )?memo"#]),
                mode("first", "First", phrases: ["as notes"]),
                mode("second", "Second", phrases: ["as notes"]),
            ])
        #expect(help.suffixes.map(\.said) == ["\u{2026} as notes"])
        #expect(help.suffixes.first?.effect == "Uses First for this take")
    }

    @Test func everyListedSuffixRoutesToTheModeItNames() {
        let modes = ModeStore.starterModes().map { mode -> Mode in
            var mode = mode
            mode.enabled = true
            return mode
        }
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [], current: "direct", eligible: modes)
        #expect(!help.suffixes.isEmpty)
        for row in help.suffixes {
            let phrase = String(row.said.dropFirst(2))
            let routed = ModeResolver.resolvePhaseB(eligibleModes: modes, transcript: "lunch is at noon \(phrase)")
            let name = modes.first { $0.id == routed.routedModeId }?.name
            #expect(row.effect == "Uses \(name ?? "nothing") for this take")
            #expect(routed.transcript == "lunch is at noon")
        }
    }

    @Test func spokenEditsListClipboardAsCodeAndVerbatimAndTheyDoWhatTheySay() {
        let help = SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage()])
        #expect(help.rows.first { $0.said == "insert clipboard contents" } != nil)
        #expect(help.rows.first { $0.said == "insert clipboard as code" }?.effect == "Inserts copied text inside a Markdown code block")
        #expect(help.rows.first { $0.said == "begin verbatim \u{2026} end verbatim" }?.effect
            == "Keeps those words literal, without edits or rewriting")
        let pipeline = TakeStages.dictation(
            text: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []),
            clip: { ClipboardTokenizer.Clip(text: "COPIED") }, redaction: false)
        func run(_ text: String) -> String { pipeline.restore(pipeline.forward(text).text) }
        #expect(run("see this, insert clipboard as code, thanks") == "see this\n```\nCOPIED\n```\nthanks")
        #expect(run("say begin verbatim scratch that end verbatim now") == "say scratch that now")
    }

    @Test func withoutSpokenEditsThereIsNoClipboardOrVerbatimRow() {
        let said = SpokenHelp.dictation(title: "Plain", stages: [rules]).rows.map(\.said)
        #expect(!said.contains { $0.contains("clipboard") || $0.contains("verbatim") })
    }

    @Test func aRuleTheTakeWouldNotApplyIsNotListed() {
        let shadowed = [
            ReplacementRule(heard: "insert new line", replace: "NEWLINE", isRegex: false),
            ReplacementRule(heard: "what can I say", replace: "help text", isRegex: false),
            ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false),
        ]
        let withEdits = SpokenHelp.dictation(
            title: "Email", stages: TakeStages.text(liveEdits: true, rules: shadowed, numbers: false, dictionary: []))
        #expect(!withEdits.rows.contains { $0.effect == "NEWLINE" })
        #expect(!withEdits.rows.contains { $0.effect == "help text" })
        #expect(withEdits.rows.contains { $0.said == "slash resume" })
        let without = SpokenHelp.dictation(
            title: "Plain", stages: TakeStages.text(liveEdits: false, rules: shadowed, numbers: false, dictionary: []))
        #expect(without.rows.contains { $0.effect == "NEWLINE" })
    }

    @Test func aRuleWhoseCapturedWordsLaterStagesPolishIsStillListed() {
        let rules = [ReplacementRule(heard: #"^note (.+)$"#, replace: "memo: $1", isRegex: true)]
        let help = SpokenHelp.dictation(
            title: "Email", stages: TakeStages.text(liveEdits: true, rules: rules, numbers: true, dictionary: ["Sample"]))
        #expect(help.rows.contains { $0.said == "note \u{2026}" && $0.effect == "memo: \u{2026}" })
    }

    @Test func spokenEditsIncludeANewParagraph() {
        let help = SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage()])
        #expect(help.rows.first { $0.said == "insert new paragraph" }?.effect == "New paragraph")
    }

    @Test func selectionHelpPromisesNoEditsOrRules() {
        let help = SpokenHelp.selection(title: "Edit Selection")
        #expect(help.rows.isEmpty)
        #expect(help.status == SpokenHelp.selectionGuidance)
    }

    @Test func answerHelpSaysToAskAboutTheSelection() {
        let help = SpokenHelp.selection(title: "Ask About Selection", answers: true)
        #expect(help.rows.isEmpty)
        #expect(help.status == SpokenHelp.answerGuidance)
        #expect(SpokenHelp.answerGuidance.contains("what do I need to do"))
        #expect(SpokenHelp.answerGuidance.hasSuffix("The answer appears here, and is read aloud unless the voice is off."))
    }

    @Test func repeatHelpHoldsWhetherTheLastReplyWasSpokenOrShown() {
        let row = SpokenHelp.codingAgentPhrases(name: "api", readsReplies: true).first { $0.said == VoiceCommandGrammar.repeatSummary[0] }
        #expect(row?.effect == "Gives the last reply update again.")
        let keep = SpokenHelp.codingAgentPhrases(name: "api", readsReplies: true).first { $0.said == VoiceCommandGrammar.keepReply[0] }
        #expect(keep?.effect == "Keeps the last reply\u{2019}s audio and report in History.")
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
        #expect(AgentStatusQuery.parse("check on backend", names: ["backend"]) == .check(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse("check on all conversations", names: ["backend"]) == .all)
        for phrase in ["tell backend run the unit tests", "select backend", "open backend", "check on backend", "check on all conversations"] {
            #expect(agent.contains(phrase))
        }
        for (phrase, intent) in [("repeat that", VoiceCommandIntent.repeatSummary), ("go back", .goBack), ("cancel", .cancel)] {
            #expect(agent.contains(phrase))
            #expect(VoiceCommandGrammar.parse(phrase) == intent)
        }
    }
}
