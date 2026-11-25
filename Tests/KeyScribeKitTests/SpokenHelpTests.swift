import Testing
@testable import KeyScribeKit

struct SpokenHelpTests {
    private let rules = ReplacementsStage(rules: [
        ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false, wholeDictation: true),
        ReplacementRule(heard: #"[\s,]*\b(?:my|insert)\s+sign[- ]?off[\s,.]*"#, replace: #"\n\nBest,"#, isRegex: true),
        ReplacementRule(heard: #"(?<=x)y"#, replace: "z", isRegex: true),
    ])

    private typealias Heading = SpokenHelp.Heading

    private func agent(
        focused: String? = "backend", example: String? = nil, readsReplies: Bool = false, canRepeat: Bool = false, canRead: Bool = false,
        stages: [any PipelineStage] = []
    ) -> SpokenHelp {
        SpokenHelp.agent(
            title: "Agent", focused: focused, example: example, readsReplies: readsReplies, canRepeat: canRepeat, canRead: canRead, stages: stages)
    }

    private func voice(
        apps: [String] = [], browser: String? = nil, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [],
        findsInApps: Bool = false,
        readsReplies: Bool = false, canRepeat: Bool = false, stages: [any PipelineStage] = []
    ) -> SpokenHelp {
        SpokenHelp.voiceCommands(
            title: "Voice Commands", apps: apps, browser: browser, places: places, scripts: scripts, findsInApps: findsInApps,
            readsReplies: readsReplies, canRepeat: canRepeat, stages: stages)
    }

    @Test func agentCommandsAreOrderedByTaskWithGoBackAndCancelLast() {
        let help = agent(readsReplies: true, canRepeat: true)
        #expect(help.status == "Unnamed instructions go to backend")
        #expect(help.groups.map(\.heading) == [Heading.commands])
        #expect(help.group(Heading.commands).map(\.said) == [
            "tell backend run the unit tests", "run the unit tests", "ask backend what changed", "tell conversation one \u{2026}",
            "open backend", "check on backend", "check on all conversations", "rename this conversation to \u{2026}",
            "repeat that", "read the whole reply", "that sounded wrong", "go back", "cancel",
        ])
        #expect(!help.rows.contains { $0.effect.localizedCaseInsensitiveContains("recipient") || $0.effect.contains("Later instructions") })
        for row in help.rows { #expect(!row.effect.isEmpty) }
    }

    @Test func theAgentCommandsNameTheConversationInFront() {
        let effects = Dictionary(agent().rows.map { ($0.said, $0.effect) }, uniquingKeysWith: { first, _ in first })
        #expect(effects["run the unit tests"] == "Sends it to backend, the conversation in front.")
        #expect(effects["rename this conversation to \u{2026}"] == "Renames backend.")
        #expect(effects["tell conversation one \u{2026}"] == "Sends it to number 1 in the list shown while recording.")
        #expect(effects["ask backend what changed"] == "Sends this question to backend.")
        #expect(agent().rows.allSatisfy { $0.note == nil })
    }

    @Test func withNothingInFrontTheRowsThatNeedItSaySoAndKeepTheirPlace() {
        let help = agent(focused: nil, example: "api")
        #expect(help.status == AgentRecipient.nothingFocusedLine)
        let said = help.rows.map(\.said)
        #expect(said.first == "tell api run the unit tests")
        #expect(said.firstIndex(of: "rename this conversation to \u{2026}") == said.firstIndex(of: "check on all conversations").map { $0 + 1 })
        let notes = Dictionary(help.rows.map { ($0.said, $0.note) }, uniquingKeysWith: { first, _ in first })
        #expect(notes["rename this conversation to \u{2026}"] == "Open a conversation first")
        #expect(notes["run the unit tests"] == "Open a conversation first")
        #expect(notes["tell api run the unit tests"] == .some(nil))
        #expect(!said.contains("repeat that"))
    }

    @Test func agentHelpWithNoConversationInventsNoNameAndNoNumber() {
        let help = agent(focused: nil, example: nil)
        #expect(help.rows.map(\.said) == [
            "run the unit tests", "check on all conversations", "rename this conversation to \u{2026}", "go back", "cancel",
        ])
    }

    @Test func noRowShowsABracketPlaceholder() {
        let helps = [
            agent(readsReplies: true, canRepeat: true, stages: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: [])),
            voice(apps: ["Mail", "Notes"], places: [VoiceCommandPlace(name: "Reading list", target: .url("https://example.com"))],
                  findsInApps: true, readsReplies: true),
            SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage(), rules]),
        ]
        for row in helps.flatMap(\.rows) {
            #expect(!row.said.contains("[") && !row.said.contains("<"), "\(row.said)")
        }
    }

    @Test func agentHelpPutsSpokenEditsWordedForAMessageAfterTheCommandsOnlyWhenTheyAreOn() {
        let on = agent(stages: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []))
        #expect(on.groups.map(\.heading) == [Heading.commands, Heading.edits])
        let effects = Dictionary(on.group(Heading.edits).map { ($0.said, $0.effect) }, uniquingKeysWith: { first, _ in first })
        #expect(effects["insert tab character"] == "Tab in the message")
        #expect(effects["insert new line"] == "New line in the message")
        #expect(effects["insert clipboard contents"] == "Adds what you copied to the message")
        #expect(effects["insert clipboard as code"] == "Adds copied text to the message inside a Markdown code block")
        #expect(effects["begin verbatim \u{2026} end verbatim"] == "Keeps those words literal, without edits or rewriting")
        #expect(!on.rows.contains { $0.said == "never mind" || $0.said.hasPrefix("discard") })
        let off = agent(stages: TakeStages.text(liveEdits: false, rules: [], numbers: false, dictionary: []))
        #expect(off.groups.map(\.heading) == [Heading.commands])
        #expect(!off.rows.contains { $0.said == "never mind" })
    }

    @Test func repeatSaysWhenThereIsNothingToRepeat() {
        #expect(agent(readsReplies: true).rows.first { $0.said == "repeat that" }?.note == "There\u{2019}s nothing to repeat yet")
        #expect(voice(readsReplies: true).rows.first { $0.said == "repeat that" }?.note == "There\u{2019}s nothing to repeat yet")
        #expect(voice(readsReplies: true, canRepeat: true).rows.first { $0.said == "repeat that" }?.note == nil)
        #expect(agent(readsReplies: true).rows.first { $0.said == "read the whole reply" }?.note == "There\u{2019}s nothing to repeat yet")
        #expect(agent(readsReplies: true, canRepeat: true).rows.first { $0.said == "read the whole reply" }?.note == "There\u{2019}s nothing to repeat yet")
        #expect(agent(readsReplies: true, canRepeat: true, canRead: true).rows.first { $0.said == "read the whole reply" }?.note == nil)
    }

    private func mode(_ id: String, _ name: String, phrases: [String], output: Mode.Output = .cursor) -> Mode {
        var mode = Mode(id: id, name: name)
        mode.triggerPhrases = phrases
        mode.output = output
        return mode
    }

    @Test func dictationGroupsSpokenEditsThenReplacementsThenSuffixes() {
        let prompt = mode("ai-prompt", "AI Prompt", phrases: ["as a prompt", "as prompt"])
        let help = SpokenHelp.dictation(title: "Email", stages: [LiveEditsStage(), rules], current: "email", eligible: [prompt])
        #expect(help.groups.map(\.heading) == [Heading.edits, Heading.replacements, Heading.suffixes])
        #expect(help.group(Heading.edits).map(\.said) == [
            "insert new line", "insert new paragraph", "insert tab character", "scratch that", "insert clipboard contents",
            "insert clipboard as code", "begin verbatim \u{2026} end verbatim",
        ])
        #expect(help.group(Heading.edits).first { $0.said == "insert tab character" }?.effect == "Tab")
        #expect(help.group(Heading.replacements) == [
            .init(said: "my sign off", effect: "New paragraph + Best,"),
            .init(said: "slash resume", effect: "/resume", note: "Say alone"),
        ])
        #expect(help.group(Heading.suffixes) == [.init(said: "\u{2026} as a prompt", effect: "Uses AI Prompt for this take")])
        #expect(help.status == nil)
    }

    @Test func dictationWithoutSpokenEditsShowsOnlyItsReplacements() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [rules])
        #expect(help.groups.map(\.heading) == [Heading.replacements])
        #expect(help.rows.map(\.said) == ["my sign off", "slash resume"])
        #expect(help.status == nil)
    }

    @Test func aModeWithNothingToSayExplainsInsteadOfShowingAnEmptyList() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [])
        #expect(help.groups.isEmpty)
        #expect(help.status == SpokenHelp.noCommands)
    }

    @Test func aModeWithOnlySuffixesIsNotEmpty() {
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [], eligible: [mode("markdown", "Markdown", phrases: ["markdown"])])
        #expect(help.status == nil)
        #expect(help.groups.map(\.heading) == [Heading.suffixes])
        #expect(help.rows.map(\.said) == ["\u{2026} markdown"])
    }

    @Test func emptyGroupsAreDropped() {
        let help = SpokenHelp(title: "", groups: [.init(heading: Heading.commands, rows: []), .init(heading: Heading.edits, rows: [.init(said: "a", effect: "b")])])
        #expect(help.groups.map(\.heading) == [Heading.edits])
    }

    @Test func savedCommandsReplacementsAndSuffixesAreAlphabetical() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [LiveEditsStage(), rules],
            eligible: [mode("z", "Zed", phrases: ["as zed"]), mode("md", "Markdown", phrases: ["as markdown"]), mode("p", "AI Prompt", phrases: ["as a prompt"])])
        #expect(help.group(Heading.suffixes).map(\.said) == ["\u{2026} as a prompt", "\u{2026} as markdown", "\u{2026} as zed"])
        let saved = voice(
            places: [VoiceCommandPlace(name: "Zoo", target: .url("https://zoo.example")), VoiceCommandPlace(name: "Atlas", target: .url("https://a.example"))],
            scripts: [VoiceCommandScript(name: "Make note", run: ["/bin/note"])])
        #expect(saved.group(Heading.saved).map(\.said) == ["open atlas", "open zoo", "run make note"])
        #expect(SpokenHelp.Heading.suffixes == "End your dictation with")
    }

    @Test func aSuffixShowsTheConfiguredPhraseUnchangedAndOneFormPerMode() {
        let help = SpokenHelp.dictation(
            title: "Email", stages: [],
            eligible: [mode("md", "Markdown", phrases: ["markdown"]), mode("p", "AI Prompt", phrases: ["as a prompt", "as prompt"])])
        #expect(help.group(Heading.suffixes) == [
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
        #expect(help.group(Heading.suffixes).map(\.said) == ["\u{2026} as notes"])
        #expect(help.group(Heading.suffixes).first?.effect == "Uses First for this take")
    }

    @Test func everyListedSuffixRoutesToTheModeItNames() {
        let modes = ModeStore.starterModes().map { mode -> Mode in
            var mode = mode
            mode.enabled = true
            return mode
        }
        let help = SpokenHelp.dictation(title: "Plain Dictation", stages: [], current: "direct", eligible: modes)
        #expect(!help.group(Heading.suffixes).isEmpty)
        for row in help.group(Heading.suffixes) {
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
        #expect(withEdits.group(Heading.replacements).contains { $0.said == "slash resume" })
        let without = SpokenHelp.dictation(
            title: "Plain", stages: TakeStages.text(liveEdits: false, rules: shadowed, numbers: false, dictionary: []))
        #expect(without.group(Heading.replacements).contains { $0.effect == "NEWLINE" })
    }

    @Test func aRuleWhoseCapturedWordsLaterStagesPolishIsStillListed() {
        let rules = [ReplacementRule(heard: #"^note (.+)$"#, replace: "memo: $1", isRegex: true)]
        let help = SpokenHelp.dictation(
            title: "Email", stages: TakeStages.text(liveEdits: true, rules: rules, numbers: true, dictionary: ["Sample"]))
        #expect(help.group(Heading.replacements).contains { $0.said == "note \u{2026}" && $0.effect == "memo: \u{2026}" })
    }

    @Test func rulesNeverAppearUnderCommands() {
        for help in [agent(stages: [rules]), voice(apps: ["Mail"], stages: [rules])] {
            #expect(!help.group(Heading.commands).contains { $0.said == "slash resume" || $0.said == "my sign off" })
            #expect(help.group(Heading.replacements).map(\.said) == ["my sign off", "slash resume"])
            #expect(help.groups.last?.heading == Heading.replacements)
        }
    }

    @Test func selectionHelpPromisesNoEditsOrRules() {
        let help = SpokenHelp.selection(title: "Edit Selection")
        #expect(help.groups.isEmpty)
        #expect(help.status == SpokenHelp.selectionGuidance)
    }

    @Test func answerHelpSaysToAskAboutTheSelection() {
        let help = SpokenHelp.selection(title: "Ask About Selection", answers: true)
        #expect(help.groups.isEmpty)
        #expect(help.status == SpokenHelp.answerGuidance)
        #expect(SpokenHelp.answerGuidance.contains("what do I need to do"))
        #expect(SpokenHelp.answerGuidance.hasSuffix("The answer appears here, and is read aloud unless the voice is off."))
    }

    @Test func repeatHelpHoldsWhetherTheLastReplyWasSpokenOrShown() {
        let rows = SpokenHelp.agentPhrases(name: "api", readsReplies: true)
        #expect(rows.first { $0.said == VoiceCommandGrammar.repeatSummary[0] }?.effect == "Gives the last reply or notice again.")
        #expect(rows.first { $0.said == VoiceCommandGrammar.keepReply[0] }?.effect == "Keeps the last reply\u{2019}s audio and report in History.")
    }

    @Test func voiceCommandHelpWithNoAppsInventsNone() {
        #expect(voice().rows.map(\.said) == ["go back", "cancel"])
        #expect(voice(findsInApps: true).rows.map(\.said) == ["go back", "cancel"])
    }

    @Test func theFindExampleUsesARunningBrowserAndSaysWhatItFindsThere() {
        let browsing = voice(apps: ["Notes", "Safari"], browser: "Safari", findsInApps: true).rows.first { $0.said.hasSuffix("\u{2026}") }
        #expect(browsing == .init(said: "open Safari \u{2026}", effect: "Finds the open tab or window in Safari that best matches what you say."))
        let other = voice(apps: ["Notes", "Mail"], findsInApps: true).rows.first { $0.said.hasSuffix("\u{2026}") }
        #expect(other == .init(said: "open Notes \u{2026}", effect: "Finds a window or sidebar item you name in Notes."))
    }

    @Test func voiceCommandHelpOffersRepeatAndKeepOnlyWhenRepliesAreReadAloud() {
        #expect(voice(apps: ["Notes", "Safari"]).rows.map(\.said) == ["open Notes", "switch to Safari", "go back", "cancel"])
        #expect(voice(apps: ["Notes", "Safari"], findsInApps: true, readsReplies: true, canRepeat: true).group(Heading.commands).map(\.said) == [
            "open Notes", "switch to Safari", "open Notes \u{2026}", "repeat that", "read the whole reply", "that sounded wrong", "go back", "cancel",
        ])
    }

    @Test func voiceCommandHelpListsEverySavedCommandWithItsVerb() {
        let places = [
            VoiceCommandPlace(name: "Reading list", target: .url("https://example.com/list")),
            VoiceCommandPlace(name: "Calendar", target: .url("https://calendar.example.com")),
            VoiceCommandPlace(name: "Browser", target: .tabSearch),
        ]
        let scripts = [
            VoiceCommandScript(name: "New note", run: ["/bin/note", "{text}"]),
            VoiceCommandScript(name: "Lock screen", run: ["/bin/lock"]),
        ]
        let help = voice(apps: ["Notes", "Safari"], places: places, scripts: scripts)
        #expect(help.groups.map(\.heading) == [Heading.commands, Heading.saved])
        #expect(help.group(Heading.commands).map(\.said) == ["open Notes", "switch to Safari", "go back", "cancel"])
        #expect(help.group(Heading.saved).map(\.said) == [
            "open browser inbox", "open calendar", "open reading list", "run lock screen", "run new note buy milk",
        ])
        let catalog = VoiceCommandCatalog(places: places, scripts: scripts, tabs: [], windows: .complete([]))
        for row in help.group(Heading.saved) where !row.said.contains("browser") {
            guard case .action = VoiceCommandResolver.resolve(row.said, catalog: catalog) else {
                Issue.record("\(row.said) does not run its command"); continue
            }
        }
    }

    @Test func theSettingsListsShareTheCommandRows() {
        let shared = SpokenHelp.voiceCommandPhrases(apps: ["Mail", "Notes"], browser: nil, findsInApps: true, readsReplies: true)
        #expect(shared.map(\.said) == voice(apps: ["Mail", "Notes"], findsInApps: true, readsReplies: true, canRepeat: true).group(Heading.commands).map(\.said))
        #expect(SpokenHelp.agentPhrases(name: "backend", inFront: "backend", readsReplies: false).map(\.said) == agent().group(Heading.commands).map(\.said))
        #expect(SpokenHelp.agentPhrases(name: "backend", readsReplies: false).first?.said == "tell backend run the unit tests")
    }

    @Test func everyBuiltInPhraseIsRecognizedAsWhatItSays() {
        let said = agent(readsReplies: true, canRepeat: true).rows.map(\.said)
        #expect(said.contains("tell backend run the unit tests"))
        #expect(AgentAddress.parse("tell backend run the unit tests", names: ["backend"]) == .name("backend", body: "run the unit tests"))
        #expect(AgentAddress.parse("run the unit tests", names: ["backend"]) == .none(body: "run the unit tests"))
        #expect(AgentAddress.parse("ask backend what changed", names: ["backend"]) == .name("backend", body: "what changed"))
        #expect(AgentAddress.parse("tell conversation one run the tests", names: ["backend"]) == .row(1, body: "run the tests"))
        #expect(AgentAddress.parse("open backend", names: ["backend"]) == .open(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse("check on backend", names: ["backend"]) == .check(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse("check on all conversations", names: ["backend"]) == .all)
        #expect(AgentRename.parse("rename this conversation to api") == .rename("api"))
        for (phrase, intent) in [("repeat that", VoiceCommandIntent.repeatSummary), ("go back", .goBack), ("cancel", .cancel)] {
            #expect(said.contains(phrase))
            #expect(VoiceCommandGrammar.parse(phrase) == intent)
        }
    }
}
