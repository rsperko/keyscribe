import Foundation

// What one replacement rule does to dictations, judged by running the scope's real local text stages (live
// edits, replacements, numbers, dictionary recovery) with and without it. It describes local processing with
// today's settings only: verbatim protection and the AI rewrite are not replayed.
public struct RuleEffectPreview: Sendable {
    public struct Config: Sendable {
        public let modes: [Mode]
        public let dictionary: DictionarySet
        public let replacements: ReplacementsSet

        public init(modes: [Mode], dictionary: DictionarySet, replacements: ReplacementsSet) {
            self.modes = modes
            self.dictionary = dictionary
            self.replacements = replacements
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let submit: Mode.Submit?
        public let skipsRewrite: Bool
    }

    // What the rule is compared against. `.current` is today's saved rules, so an edit shows only what
    // saving it would change — a repair appears as damaged text coming back. `.withoutRule` isolates what
    // the rule does at all, for a rule left as it is and for the audit.
    public enum Baseline: Sendable {
        case current
        case withoutRule
    }

    public struct Entry: Sendable {
        public let reference: HistorySnapshot.Reference?
        public let modeName: String?
        public let date: Date?
        public let before: Outcome
        public let after: Outcome
        public let changes: [ReplacementPreview.Change]
        // The draft rule's own effect on this text, from its winning matches.
        public let rule: ReplacementEffect?

        public var differs: Bool { before != after }
    }

    public let entries: [Entry]
    // Dictations where the rule's own winning matches landed inside a word or dropped a Return, whether or not
    // the output differs from the baseline — a dropped Return can leave every word the same.
    public let flagged: [Entry]
    public let checked: Int

    public static func make(
        draft: ReplacementsSet.Rule?, replacing original: ReplacementsSet.Rule?,
        scope: ReplacementPreview.Destination, config: Config,
        history: [HistorySnapshot.Item], limit: Int, baseline: Baseline = .current
    ) throws -> RuleEffectPreview {
        let comparison = try Comparison(draft: draft, replacing: original, scope: scope, config: config, baseline: baseline)
        let modesByName = Dictionary(grouping: config.modes, by: \.name)
        let recent = history
            .filter { !$0.entry.outcome.isCommand }
            .sorted { $0.entry.timestamp > $1.entry.timestamp }
        var checked = 0
        var entries: [Entry] = []
        var flagged: [Entry] = []
        for item in recent {
            guard checked < limit else { break }
            try Task.checkCancellation()
            let named = modesByName[item.entry.modeName] ?? []
            let resolved = named.count == 1 ? named.first : nil
            guard comparison.reaches(resolved) else { continue }
            checked += 1
            let entry = comparison.entry(
                item.entry.heard, mode: comparison.mode(running: resolved), reference: item.reference,
                modeName: item.entry.modeName, date: item.entry.timestamp)
            if entry.differs { entries.append(entry) }
            if entry.rule?.insideWord == true || entry.rule?.returnOmitted == true { flagged.append(entry) }
        }
        return RuleEffectPreview(entries: entries, flagged: flagged, checked: checked)
    }

    public static func sample(
        _ text: String, draft: ReplacementsSet.Rule?, replacing original: ReplacementsSet.Rule?,
        scope: ReplacementPreview.Destination, config: Config, baseline: Baseline = .current
    ) throws -> Entry {
        let comparison = try Comparison(draft: draft, replacing: original, scope: scope, config: config, baseline: baseline)
        return comparison.entry(text, mode: comparison.scopeMode, reference: nil, modeName: nil, date: nil)
    }

    public struct Finding: Sendable {
        public let rule: ReplacementsSet.Rule
        public let insideWord: Int
        public let returnOmitted: Int
        public let example: Entry?
    }

    public struct Audit: Sendable {
        public let findings: [Finding]
        public let checked: Int
    }

    // Every rule in a scope replayed over past dictations with today's rules, keeping the ones that changed
    // text inside a word or matched mid-sentence where their Return is dropped. Unlike usage counts this
    // works for rules edited by hand and for dictations made before the rule existed.
    public static func audit(
        scope: ReplacementPreview.Destination, config: Config, history: [HistorySnapshot.Item], limit: Int
    ) throws -> Audit {
        let rules: [ReplacementsSet.Rule]
        switch scope {
        case .global: rules = config.replacements.rules
        case .mode(let id):
            guard let mode = config.modes.first(where: { $0.id == id }) else { throw ReplacementPreview.Failure.destinationMissing }
            rules = mode.replacements.rules
        }
        var findings: [Finding] = []
        var checked = 0
        for rule in rules {
            try Task.checkCancellation()
            let preview = try make(
                draft: rule, replacing: rule, scope: scope, config: config, history: history, limit: limit,
                baseline: .withoutRule)
            checked = preview.checked
            let flagged = preview.flagged
            guard !flagged.isEmpty else { continue }
            findings.append(Finding(
                rule: rule,
                insideWord: flagged.filter { $0.rule?.insideWord == true }.count,
                returnOmitted: flagged.filter { $0.rule?.returnOmitted == true }.count,
                example: flagged.first))
        }
        if rules.isEmpty {
            checked = try make(draft: nil, replacing: nil, scope: scope, config: config, history: history, limit: limit).checked
        }
        return Audit(findings: findings, checked: checked)
    }

    private struct Comparison {
        let without: ResolvedConfig
        let with: ResolvedConfig
        let target: Mode?
        let draft: ReplacementRule?

        var scopeMode: Mode? { target }

        init(
            draft: ReplacementsSet.Rule?, replacing original: ReplacementsSet.Rule?,
            scope: ReplacementPreview.Destination, config: Config, baseline: Baseline
        ) throws {
            let target: Mode?
            switch scope {
            case .global: target = nil
            case .mode(let id):
                guard let mode = config.modes.first(where: { $0.id == id }) else {
                    throw ReplacementPreview.Failure.destinationMissing
                }
                target = mode
            }
            let current = target?.replacements.rules ?? config.replacements.rules
            let position = original.flatMap { current.firstIndex(of: $0) }
            var withoutOriginal = current
            if let position { withoutOriginal.remove(at: position) }
            var withRules = withoutOriginal
            if let draft { withRules.insert(draft, at: position ?? withRules.endIndex) }
            let withoutRules = baseline == .current ? current : withoutOriginal
            func resolved(_ rules: [ReplacementsSet.Rule]) -> ResolvedConfig {
                var modes = config.modes
                var global = config.replacements
                if let target, let i = modes.firstIndex(where: { $0.id == target.id }) {
                    modes[i].replacements.rules = rules
                } else {
                    global.rules = rules
                }
                return ResolvedConfig(
                    modes: modes, dictionary: config.dictionary, replacements: global,
                    connections: ConnectionSet(), fragments: [:])
            }
            let with = resolved(withRules)
            self.without = resolved(withoutRules)
            self.with = with
            self.target = target.flatMap { t in with.modes.first { $0.id == t.id } }
            self.draft = draft?.toReplacementRule()
        }

        // A History entry from a mode this config no longer has (renamed, deleted, or a name two modes share)
        // cannot be placed, so only a Global scope, which applies without a mode, counts it.
        func reaches(_ resolved: Mode?) -> Bool {
            guard let resolved else { return target == nil }
            if let target { return resolved.id == target.id }
            return resolved.replacements.includeGlobal
        }

        func mode(running resolved: Mode?) -> Mode? {
            target ?? resolved.flatMap { m in with.modes.first { $0.id == m.id } }
        }

        func entry(
            _ heard: String, mode: Mode?, reference: HistorySnapshot.Reference?, modeName: String?, date: Date?
        ) -> Entry {
            let before = Self.run(without, mode: without.modes.first { $0.id == mode?.id }, heard)
            let after = Self.run(with, mode: mode, heard)
            let rule = draft.flatMap { draft in after.effects.first { $0.rule.sameRule(as: draft) } }
            return Entry(
                reference: reference, modeName: modeName, date: date, before: before.outcome, after: after.outcome,
                changes: ReplacementPreview.hunks(from: before.outcome.text, to: after.outcome.text).map {
                    ReplacementPreview.Change(range: $0.range, before: $0.before, after: $0.after, phrase: nil)
                },
                rule: rule)
        }

        private static func run(_ config: ResolvedConfig, mode: Mode?, _ heard: String) -> (outcome: Outcome, effects: [ReplacementEffect]) {
            let pipeline = Pipeline(config.postSTTTextStages(for: mode))
            let payload = pipeline.forward(heard)
            let text = payload.bareReplacement?.text ?? pipeline.restore(payload.text)
            return (Outcome(text: text, submit: payload.bareReplacement?.submit, skipsRewrite: payload.bareReplacement != nil),
                    payload.replacementEffects)
        }
    }
}

extension ReplacementsSet.Rule {
    func toReplacementRule() -> ReplacementRule {
        ReplacementRule(heard: heard, replace: replace, isRegex: regex, wholeDictation: wholeDictation)
    }
}

extension ReplacementRule {
    func sameRule(as other: ReplacementRule) -> Bool {
        heard == other.heard && replace == other.replace && isRegex == other.isRegex && wholeDictation == other.wholeDictation
    }
}
