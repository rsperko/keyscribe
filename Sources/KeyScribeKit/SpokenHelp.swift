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

    public let title: String
    public let status: String?
    public let rows: [Row]

    public init(title: String, status: String? = nil, rows: [Row]) {
        self.title = title
        self.status = status
        self.rows = rows.sorted { $0.said.localizedStandardCompare($1.said) == .orderedAscending }
    }

    public static func codingAgent(
        title: String, recipient: String?, example: String?, readsReplies: Bool, canRepeat: Bool, stages: [any PipelineStage]
    ) -> SpokenHelp {
        let unnamed = "\u{E000}"
        let name = recipient ?? example
        let rows = codingAgentPhrases(name: name ?? unnamed, readsReplies: readsReplies)
            .filter { !$0.said.contains(unnamed) }
            .map { row in
            row.said == VoiceCommandGrammar.repeatSummary[0] && !canRepeat
                ? Row(said: row.said, effect: row.effect, note: "There\u{2019}s nothing to repeat yet") : row
        }
        return SpokenHelp(
            title: title, status: recipient.map { "Recipient: \($0)" } ?? "No recipient selected",
            rows: rows + ruleRows(stages))
    }

    public static func codingAgentPhrases(name: String, readsReplies: Bool) -> [Row] {
        var rows = [
            Row(said: "tell \(name) run the unit tests", effect: "Sends the instruction to \(name). Later instructions go there too."),
            Row(said: "select \(name)", effect: "Makes \(name) the recipient. Nothing is sent."),
            Row(said: "open \(name)", effect: "Brings \(name) to the front and makes it the recipient. Nothing is sent."),
            Row(said: "check on \(name)", effect: "Reports \(name)\u{2019}s status. Nothing is sent."),
            Row(said: "check on all conversations", effect: "Names the conversations waiting for you. Nothing is sent."),
        ]
        if readsReplies { rows.append(Row(said: VoiceCommandGrammar.repeatSummary[0], effect: "Reads the last spoken reply again.")) }
        rows.append(Row(said: VoiceCommandGrammar.goBack, effect: "Returns to where you were."))
        rows.append(Row(said: VoiceCommandGrammar.cancel[0], effect: "Stops this recording. Nothing is sent."))
        return rows
    }

    public static func voiceCommands(
        title: String, apps: [String], places: [VoiceCommandPlace], scripts: [VoiceCommandScript], stages: [any PipelineStage]
    ) -> SpokenHelp {
        var rows: [Row] = []
        if let first = apps.first {
            rows.append(Row(said: "open \(first)", effect: "Opens \(first) or brings it forward."))
            let open = apps.dropFirst().first ?? first
            rows.append(Row(said: "switch to \(open)", effect: "Brings \(open) forward if it\u{2019}s already running."))
        }
        let back = Row(said: VoiceCommandGrammar.goBack, effect: "Returns to where you were.")
        if let place = places.first {
            let said = "\(VoiceCommandGrammar.openingVerbs[0]) \(VoiceCommandText.key(place.name))"
            rows.append(Row(said: place.isTabSearch ? "\(said) \(VoiceCommandExample.sampleTabWords)" : said, effect: "Opens \(place.name)."))
        }
        if let script = scripts.first {
            let said = "\(VoiceCommandGrammar.run) \(VoiceCommandText.key(script.name))"
            rows.append(Row(said: script.takesText ? "\(said) \(VoiceCommandExample.sampleWords)" : said, effect: "Runs \(script.name)."))
        }
        rows += [back, Row(said: VoiceCommandGrammar.cancel[0], effect: "Stops this recording. Nothing runs.")]
        return SpokenHelp(title: title, rows: rows + ruleRows(stages))
    }

    public static func voiceCommandPhrases(findsInApps: Bool) -> [Row] {
        let open = Row(said: "open Mail", effect: "Opens Mail or brings it forward.")
        let inside = Row(said: "open Slack general", effect: "Opens general in Slack.")
        let back = Row(said: VoiceCommandGrammar.goBack, effect: "Returns to where you were.")
        return findsInApps ? [open, inside, back] : [open, back]
    }

    public static func dictation(title: String, stages: [any PipelineStage], suffixes: [(said: String, mode: String)]) -> SpokenHelp {
        var rows: [Row] = []
        if let edits = stages.lazy.compactMap({ $0 as? LiveEditsStage }).first?.commands {
            rows += [
                edits.newLine.first.map { Row(said: $0, effect: "New line") },
                edits.newParagraph.first.map { Row(said: $0, effect: "New paragraph") },
                edits.tab.first.map { Row(said: $0, effect: "Tab") },
                edits.scratchThat.first.map { Row(said: $0, effect: "Removes what you just said") },
                edits.discard.first.map { Row(said: $0, effect: "Discards this take", note: "Say it last") },
            ].compactMap { $0 }
            rows.insert(Row(said: ClipboardTokenizer.defaultPhrases[0], effect: "Inserts what you copied"), at: min(rows.count, 4))
        }
        rows += suffixes.map { Row(said: "\u{2026} \($0.said)", effect: "Uses \($0.mode) for this take") }
        rows += ruleRows(stages)
        return SpokenHelp(title: title, status: rows.isEmpty ? noCommands : nil, rows: rows)
    }

    public static let noCommands = "No spoken commands in this mode. Turn on spoken edits in its settings to add some."

    public static let selectionGuidance = "Select text first, then say how to change it, such as \u{201C}make this shorter\u{201D}."

    public static func selection(title: String) -> SpokenHelp {
        SpokenHelp(title: title, status: selectionGuidance, rows: [])
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
        return stages.compactMap { $0 as? ReplacementsStage }.flatMap(\.rules).compactMap { rule in
            guard let example = RuleExample.examples(for: rule).first(where: applies), seen.insert(example.said.lowercased()).inserted
            else { return nil }
            return Row(said: example.said, effect: example.result, note: rule.wholeDictation ? "Say alone" : nil)
        }
    }
}
