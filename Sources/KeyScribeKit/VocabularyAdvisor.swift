import Foundation

public enum VocabularyProposal: Equatable, Sendable {
    case word(String)
    case replacement(heard: String, replace: String, regex: Bool)
}

public struct VocabularyScope: Equatable, Sendable {
    public struct Local: Equatable, Sendable {
        public var words: [String]
        public var rules: [ReplacementsSet.Rule]
        public var includeGlobalWords: Bool
        public var includeGlobalRules: Bool

        public init(
            words: [String] = [], rules: [ReplacementsSet.Rule] = [],
            includeGlobalWords: Bool = true, includeGlobalRules: Bool = true
        ) {
            self.words = words
            self.rules = rules
            self.includeGlobalWords = includeGlobalWords
            self.includeGlobalRules = includeGlobalRules
        }
    }

    public var globalWords: [String]
    public var globalRules: [ReplacementsSet.Rule]
    public var local: Local?

    public init(globalWords: [String] = [], globalRules: [ReplacementsSet.Rule] = [], local: Local? = nil) {
        self.globalWords = globalWords
        self.globalRules = globalRules
        self.local = local
    }
}

public struct VocabularyAnalysis: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case addWord
        case addReplacement
        case updateWord(currentWord: String)
        case updateReplacement(currentReplace: String)
        case noChange(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case wordAlreadyListed
        case wordCoveredByGlobal
        case replacementAlreadyListed
        case replacementCoveredByGlobal
    }

    public struct Advisory: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case overridesGlobal
            case preempted
            case cascades
        }

        public let kind: Kind
        public let message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public let action: Action
    public let advisories: [Advisory]

    public init(action: Action, advisories: [Advisory] = []) {
        self.action = action
        self.advisories = advisories
    }
}

public enum VocabularyAdvisor {
    public static func analyze(_ proposal: VocabularyProposal, in scope: VocabularyScope) -> VocabularyAnalysis {
        switch proposal {
        case .word(let word):
            return analyzeWord(word, in: scope)
        case .replacement(let heard, let replace, let regex):
            return analyzeReplacement(heard: heard, replace: replace, isRegex: regex, in: scope)
        }
    }

    public static func ruleAdvisories(in scope: VocabularyScope) -> [[VocabularyAnalysis.Advisory]] {
        let target = scope.local?.rules ?? scope.globalRules
        guard !target.isEmpty else { return [] }
        let effective = effectiveRules(in: scope)
        let prepared: [Prepared?] = effective.map { rule in
            switch ReplacementsStage.prepare(rule) {
            case .ready(let regex, let template, _): return Prepared(regex: regex, template: template)
            case .droppedForReturnMarker, .dropped: return nil
            }
        }
        let offset = effective.count - target.count
        return target.indices.map { index in
            let position = offset + index
            var result = advisories(at: position, effective: effective, prepared: prepared)
            if scope.local != nil {
                result += incomingGlobalAdvisories(
                    at: position, globalCount: offset, effective: effective, prepared: prepared)
            }
            var seen = Set<String>()
            return result.filter { seen.insert($0.message).inserted }
        }
    }

    private static func analyzeWord(_ word: String, in scope: VocabularyScope) -> VocabularyAnalysis {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VocabularyAnalysis(action: .addWord) }
        func action(for words: [String]) -> VocabularyAnalysis.Action? {
            guard let existing = words.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else { return nil }
            return existing == trimmed
                ? .noChange(.wordAlreadyListed)
                : .updateWord(currentWord: existing)
        }
        if let local = scope.local {
            if let action = action(for: local.words) { return VocabularyAnalysis(action: action) }
            if local.includeGlobalWords, scope.globalWords.contains(trimmed) {
                return VocabularyAnalysis(action: .noChange(.wordCoveredByGlobal))
            }
            return VocabularyAnalysis(action: .addWord)
        }
        if let action = action(for: scope.globalWords) { return VocabularyAnalysis(action: action) }
        return VocabularyAnalysis(action: .addWord)
    }

    private static func analyzeReplacement(
        heard: String, replace: String, isRegex: Bool, in scope: VocabularyScope
    ) -> VocabularyAnalysis {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VocabularyAnalysis(action: .addReplacement) }
        func identityMatches(_ rule: ReplacementsSet.Rule) -> Bool {
            rule.regex == isRegex && sameIdentity(rule.heard, trimmed, isRegex: isRegex)
        }

        let targetRules = scope.local?.rules ?? scope.globalRules
        if let existing = targetRules.first(where: identityMatches) {
            if existing.replace == replace {
                return VocabularyAnalysis(action: .noChange(.replacementAlreadyListed))
            }
            return VocabularyAnalysis(action: .updateReplacement(currentReplace: existing.replace))
        }
        if let local = scope.local, local.includeGlobalRules,
           let global = scope.globalRules.first(where: identityMatches) {
            if global.replace == replace {
                return VocabularyAnalysis(action: .noChange(.replacementCoveredByGlobal))
            }
            return VocabularyAnalysis(action: .addReplacement, advisories: [VocabularyAnalysis.Advisory(
                kind: .overridesGlobal,
                message: "Overrides the global replacement for “\(global.heard)”, which currently becomes \(quoted(global.replace)).")])
        }
        return VocabularyAnalysis(action: .addReplacement)
    }

    private struct Prepared {
        let regex: NSRegularExpression
        let template: String
    }

    private static func effectiveRules(in scope: VocabularyScope) -> [ReplacementRule] {
        guard let local = scope.local else { return scope.globalRules.toReplacementRules() }
        return VocabularyMerge.rules(
            global: scope.globalRules.toReplacementRules(),
            local: local.rules.toReplacementRules(),
            includeGlobal: local.includeGlobalRules)
    }

    private static func advisories(
        at position: Int, effective: [ReplacementRule], prepared: [Prepared?]
    ) -> [VocabularyAnalysis.Advisory] {
        guard let rule = prepared[position] else { return [] }
        let subject = effective[position]
        var advisories: [VocabularyAnalysis.Advisory] = []

        var witnesses: [String] = []
        if subject.isRegex {
            for i in effective.indices where !effective[i].isRegex && prepared[i] != nil {
                if matches(rule.regex, effective[i].heard) { witnesses.append(effective[i].heard) }
            }
        } else {
            witnesses = [subject.heard]
        }
        for witness in witnesses {
            let propagation = propagate(witness, through: 0..<position, prepared: prepared)
            if propagation.value != witness, let changer = propagation.firstChanger,
               !matches(rule.regex, propagation.value) {
                advisories.append(VocabularyAnalysis.Advisory(
                    kind: .preempted,
                    message: "When you say “\(witness)”, the replacement for “\(effective[changer].heard)” runs first and changes it to \(quoted(propagation.value)), so this rule will not apply."))
            }
        }

        for execution in executions(at: position, effective: effective, prepared: prepared)
        where position + 1 < effective.count {
            let propagation = propagate(
                execution.output, through: (position + 1)..<effective.count, prepared: prepared)
            if propagation.value != execution.output, let changer = propagation.firstChanger {
                advisories.append(VocabularyAnalysis.Advisory(
                    kind: .cascades,
                    message: "When you say “\(execution.witness)”, this rule produces \(quoted(execution.output)), then the replacement for “\(effective[changer].heard)” changes it to \(quoted(propagation.value))."))
                break
            }
        }

        return advisories
    }

    private static func incomingGlobalAdvisories(
        at position: Int, globalCount: Int, effective: [ReplacementRule], prepared: [Prepared?]
    ) -> [VocabularyAnalysis.Advisory] {
        guard position >= globalCount, let subject = prepared[position] else { return [] }
        return (0..<globalCount).compactMap { globalPosition in
            let globalRule = effective[globalPosition]
            guard let execution = executions(
                at: globalPosition, effective: effective, prepared: prepared).first else { return nil }
            let propagation = propagate(
                execution.output, through: (globalPosition + 1)..<position, prepared: prepared)
            guard propagation.value == execution.output else { return nil }
            let changed = applying(subject, to: propagation.value)
            guard changed != propagation.value else { return nil }
            return VocabularyAnalysis.Advisory(
                kind: .cascades,
                message: "When you say “\(execution.witness)”, the global replacement for “\(globalRule.heard)” produces \(quoted(execution.output)), which this rule changes to \(quoted(changed)).")
        }
    }

    private struct Execution {
        let witness: String
        let output: String
    }

    private static func propagate(
        _ value: String, through indices: Range<Int>, prepared: [Prepared?]
    ) -> (value: String, firstChanger: Int?) {
        var value = value
        var firstChanger: Int?
        for index in indices {
            guard let rule = prepared[index] else { continue }
            let next = applying(rule, to: value)
            if next != value, firstChanger == nil { firstChanger = index }
            value = next
        }
        return (value, firstChanger)
    }

    private static func executions(
        at position: Int, effective: [ReplacementRule], prepared: [Prepared?]
    ) -> [Execution] {
        guard let subject = prepared[position] else { return [] }
        let candidates = effective[position].isRegex
            ? effective.filter { !$0.isRegex }.map(\.heard)
            : [effective[position].heard]
        var seen = Set<String>()
        return candidates.compactMap { witness in
            guard seen.insert(witness).inserted else { return nil }
            var input = witness
            for index in 0..<position {
                guard let earlier = prepared[index] else { continue }
                input = applying(earlier, to: input)
            }
            guard matches(subject.regex, input) else { return nil }
            return Execution(witness: witness, output: applying(subject, to: input))
        }
    }

    private static func sameIdentity(_ a: String, _ b: String, isRegex: Bool) -> Bool {
        isRegex ? a == b : a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func applying(_ rule: Prepared, to text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard rule.regex.firstMatch(in: text, range: range) != nil else { return text }
        return rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
    }

    private static func quoted(_ text: String) -> String {
        text.isEmpty ? "nothing" : "“\(ReplacementAuthoring.preview(for: text).text)”"
    }
}
