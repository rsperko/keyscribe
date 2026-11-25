import Foundation

public struct SpokenHelp: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let said: String
        public let effect: String
        public let note: String?

        public init(said: String, effect: String, note: String? = nil) {
            self.said = said
            self.effect = effect
            self.note = note
        }
    }

    public struct Group: Equatable, Sendable {
        public let heading: String
        public let rows: [Row]

        public init(heading: String, rows: [Row]) {
            self.heading = heading
            self.rows = rows
        }
    }

    public enum Heading {
        public static let commands = "Commands"
        public static let saved = "Saved commands"
        public static let edits = "Spoken edits"
        public static let replacements = "Replacements"
        public static let suffixes = "End your dictation with"
    }

    public let title: String
    public let status: String?
    public let groups: [Group]

    public var rows: [Row] { groups.flatMap(\.rows) }

    public func group(_ heading: String) -> [Row] {
        groups.first { $0.heading == heading }?.rows ?? []
    }

    public init(title: String, status: String? = nil, groups: [Group]) {
        self.title = title
        self.status = status
        self.groups = groups.filter { !$0.rows.isEmpty }
    }

    private static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { $0.said.localizedStandardCompare($1.said) == .orderedAscending }
    }

    static let nothingToRepeat = "There\u{2019}s nothing to repeat yet"
    static let openAConversation = "Open a conversation first"
    static let sampleInstruction = "run the unit tests"

    private static func noting(_ rows: [Row], _ note: String, when matches: (Row) -> Bool) -> [Row] {
        rows.map { matches($0) ? Row(said: $0.said, effect: $0.effect, note: note) : $0 }
    }

    private static func notingRepeat(_ rows: [Row], canRepeat: Bool, canRead: Bool) -> [Row] {
        let unavailable = (canRepeat ? [] : [VoiceCommandGrammar.repeatSummary[0]]) + (canRead ? [] : [VoiceCommandGrammar.readReply[0]])
        return noting(rows, nothingToRepeat) { unavailable.contains($0.said) }
    }

    public static func agent(
        title: String, focused: String?, example: String?, readsReplies: Bool, canRepeat: Bool, canRead: Bool = false,
        stages: [any PipelineStage]
    ) -> SpokenHelp {
        var commands = notingRepeat(
            agentPhrases(name: focused ?? example, inFront: focused, readsReplies: readsReplies), canRepeat: canRepeat, canRead: canRead)
        if focused == nil {
            commands = noting(commands, openAConversation) { $0.said == sampleInstruction || $0.said == renameRow(inFront: nil).said }
        }
        return SpokenHelp(
            title: title, status: focused.map { "Unnamed instructions go to \($0)" } ?? AgentRecipient.nothingFocusedLine,
            groups: [
                Group(heading: Heading.commands, rows: commands),
                Group(heading: Heading.edits, rows: editRows(stages, forMessage: true)),
                Group(heading: Heading.replacements, rows: ruleRows(stages)),
            ])
    }

    private static func renameRow(inFront: String?) -> Row {
        Row(said: "rename this conversation to \u{2026}", effect: inFront.map { "Renames \($0)." } ?? "Renames the conversation in front.")
    }

    public static func agentPhrases(name: String?, inFront: String? = nil, readsReplies: Bool) -> [Row] {
        let bare = Row(
            said: sampleInstruction,
            effect: inFront.map { "Sends it to \($0), the conversation in front." } ?? "Sends it to the conversation in front when you start speaking.")
        var rows: [Row] = []
        if let name {
            rows += [
                Row(said: "tell \(name) \(sampleInstruction)", effect: "Sends this instruction to \(name)."),
                bare,
                Row(said: "ask \(name) what changed", effect: "Sends this question to \(name)."),
                Row(said: "tell conversation one \u{2026}", effect: "Sends it to number 1 in the list shown while recording."),
                Row(said: "open \(name)", effect: "Brings \(name) to the front. Nothing is sent."),
                Row(said: "check on \(name)", effect: "Reports \(name)\u{2019}s status. Nothing is sent."),
            ]
        } else {
            rows.append(bare)
        }
        rows.append(Row(said: "check on all conversations", effect: "Names the conversations waiting for you. Nothing is sent."))
        rows.append(renameRow(inFront: inFront))
        rows += replyRows(readsReplies: readsReplies)
        rows.append(Row(said: VoiceCommandGrammar.goBack, effect: "Returns to where you were."))
        rows.append(Row(said: VoiceCommandGrammar.cancel[0], effect: "Stops this recording. Nothing is sent."))
        return rows
    }

    private static func replyRows(readsReplies: Bool) -> [Row] {
        guard readsReplies else { return [] }
        return [
            Row(said: VoiceCommandGrammar.repeatSummary[0], effect: "Gives the last reply or notice again."),
            Row(said: VoiceCommandGrammar.readReply[0], effect: "Reads the last reply in full, without its code or links."),
            Row(said: VoiceCommandGrammar.keepReply[0], effect: "Keeps the last reply\u{2019}s audio and report in History."),
        ]
    }

    public static func voiceCommands(
        title: String, apps: [String], browser: String? = nil, places: [VoiceCommandPlace], scripts: [VoiceCommandScript],
        findsInApps: Bool = false, readsReplies: Bool = false, canRepeat: Bool = false, canRead: Bool = false, stages: [any PipelineStage]
    ) -> SpokenHelp {
        let commands = notingRepeat(
            voiceCommandPhrases(apps: apps, browser: browser, findsInApps: findsInApps, readsReplies: readsReplies),
            canRepeat: canRepeat, canRead: canRead)
        return SpokenHelp(title: title, groups: [
            Group(heading: Heading.commands, rows: commands),
            Group(heading: Heading.saved, rows: savedRows(places: places, scripts: scripts)),
            Group(heading: Heading.replacements, rows: ruleRows(stages)),
        ])
    }

    public static func voiceCommandPhrases(apps: [String], browser: String?, findsInApps: Bool, readsReplies: Bool) -> [Row] {
        var rows: [Row] = []
        if let first = apps.first {
            rows.append(Row(said: "open \(first)", effect: "Opens \(first) or brings it forward."))
            let open = apps.dropFirst().first ?? first
            rows.append(Row(said: "switch to \(open)", effect: "Brings \(open) forward if it\u{2019}s already running."))
            if findsInApps {
                rows.append(findRow(in: browser ?? first, browser: browser != nil))
            }
        }
        rows += replyRows(readsReplies: readsReplies)
        rows.append(Row(said: VoiceCommandGrammar.goBack, effect: "Returns to where you were."))
        rows.append(Row(said: VoiceCommandGrammar.cancel[0], effect: "Stops this recording. Nothing runs."))
        return rows
    }

    private static func findRow(in app: String, browser: Bool) -> Row {
        Row(said: "open \(app) \u{2026}", effect: browser
            ? "Finds the open tab or window in \(app) that best matches what you say."
            : "Finds a window or sidebar item you name in \(app).")
    }

    public static func savedRows(places: [VoiceCommandPlace], scripts: [VoiceCommandScript]) -> [Row] {
        let opened = places.map { place in
            let said = "\(VoiceCommandGrammar.openingVerbs[0]) \(VoiceCommandText.key(place.name))"
            return place.isTabSearch
                ? Row(said: "\(said) \(VoiceCommandExample.sampleTabWords)", effect: "Switches to the open tab that best matches the words after its name.")
                : Row(said: said, effect: "Opens \(place.name).")
        }
        let run = scripts.map { script in
            let said = "\(VoiceCommandGrammar.run) \(VoiceCommandText.key(script.name))"
            return script.takesText
                ? Row(said: "\(said) \(VoiceCommandExample.sampleWords)", effect: "Runs \(script.name) with the words after its name.")
                : Row(said: said, effect: "Runs \(script.name).")
        }
        return sorted(opened + run)
    }

    public static func dictation(
        title: String, stages: [any PipelineStage], current: String? = nil, eligible: [Mode] = [], context: RoutingContext = .init()
    ) -> SpokenHelp {
        let groups = [
            Group(heading: Heading.edits, rows: editRows(stages, forMessage: false)),
            Group(heading: Heading.replacements, rows: ruleRows(stages)),
            Group(heading: Heading.suffixes, rows: sorted(suffixRows(current: current, eligible: eligible, context: context))),
        ]
        let help = SpokenHelp(title: title, groups: groups)
        return help.groups.isEmpty ? SpokenHelp(title: title, status: noCommands, groups: []) : help
    }

    static func editRows(_ stages: [any PipelineStage], forMessage: Bool) -> [Row] {
        guard let edits = stages.lazy.compactMap({ $0 as? LiveEditsStage }).first?.commands else { return [] }
        let place = forMessage ? " in the message" : ""
        return [
            edits.newLine.first.map { Row(said: $0, effect: "New line\(place)") },
            edits.newParagraph.first.map { Row(said: $0, effect: "New paragraph\(place)") },
            edits.tab.first.map { Row(said: $0, effect: "Tab\(place)") },
            edits.scratchThat.first.map { Row(said: $0, effect: "Removes what you just said") },
        ].compactMap { $0 } + [
            Row(
                said: ClipboardTokenizer.defaultPhrases[0],
                effect: forMessage ? "Adds what you copied to the message" : "Inserts what you copied"),
            Row(
                said: ClipboardTokenizer.codePhrases[0],
                effect: forMessage
                    ? "Adds copied text to the message inside a Markdown code block" : "Inserts copied text inside a Markdown code block"),
            Row(
                said: "\(VerbatimTokenizer.beginPhrase) \u{2026} \(VerbatimTokenizer.endPhrase)",
                effect: "Keeps those words literal, without edits or rewriting"),
        ]
    }

    static func suffixRows(current: String?, eligible: [Mode], context: RoutingContext) -> [Row] {
        let sample = "sample words"
        return eligible.filter { $0.id != current }.compactMap { mode in
            let phrase = mode.triggerPhrases.first { phrase in
                guard phrase.allSatisfy({ $0.isLetter || $0 == " " }) else { return false }
                let routed = ModeResolver.resolvePhaseB(eligibleModes: eligible, transcript: "\(sample) \(phrase)", context: context)
                return routed.routedModeId == mode.id && routed.transcript == sample
            }
            return phrase.map { Row(said: "\u{2026} \($0)", effect: "Uses \(mode.name) for this take") }
        }
    }

    public static let noCommands = "No spoken commands in this mode. Turn on spoken edits in its settings to add some."

    public static let selectionGuidance = "Select text first, then say how to change it, such as \u{201C}make this shorter\u{201D}."

    public static let answerGuidance = "Select text first, then ask about it, such as \u{201C}summarize this\u{201D} or \u{201C}what do I need to do?\u{201D} The answer appears here, and is read aloud unless the voice is off."

    public static func selection(title: String, answers: Bool = false) -> SpokenHelp {
        SpokenHelp(title: title, status: answers ? answerGuidance : selectionGuidance, groups: [])
    }

    static func ruleRows(_ stages: [any PipelineStage]) -> [Row] {
        let rulesAt = stages.first { $0 is ReplacementsStage }
        let pipeline = Pipeline(stages.filter { stage in
            rulesAt.map { stage.position < $0.position || (stage.position == $0.position && stage.order <= $0.order) } ?? true
        })
        func applies(_ example: RuleExample) -> Bool {
            guard VoiceCommandGrammar.parse(example.tried) != .help else { return false }
            let run = pipeline.forward(example.tried)
            let produced = run.bareReplacement?.text ?? pipeline.restore(run.text)
            return produced.trimmingCharacters(in: .whitespacesAndNewlines) == example.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seen = Set<String>()
        return sorted(stages.compactMap { $0 as? ReplacementsStage }.flatMap(\.rules).compactMap { rule in
            guard let example = RuleExample.examples(for: rule).first(where: applies), seen.insert(example.said.lowercased()).inserted
            else { return nil }
            return Row(said: example.said, effect: example.result, note: rule.wholeDictation ? "Say alone" : nil)
        })
    }
}
