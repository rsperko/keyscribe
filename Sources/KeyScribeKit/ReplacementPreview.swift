import Foundation

public struct ReplacementPreview: Sendable {
    public enum Destination: Hashable, Sendable {
        case global
        case mode(String)
    }

    public enum Failure: Error, Equatable {
        case destinationMissing
    }

    public struct PhraseStatus: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case add
            case alreadyAdded
            case conflicts(currentOutput: String)
            case overridesGlobal(globalOutput: String)
        }

        public let phrase: String
        public let kind: Kind

        public var isSaved: Bool {
            switch kind {
            case .add, .overridesGlobal: true
            case .alreadyAdded, .conflicts: false
            }
        }
    }

    public struct Change: Sendable {
        public let range: Range<String.Index>
        public let before: String
        public let after: String
        public let phrase: String?
    }

    public struct EntryEffect: Sendable {
        public let reference: HistorySnapshot.Reference
        public let modeName: String
        public let modeUnknown: Bool
        public let isAdditional: Bool
        public let currentText: String
        public let proposedText: String
        public let wholeUtterance: Bool
        public let changes: [Change]
    }

    public let destination: Destination
    public let replacement: String
    public let statuses: [PhraseStatus]
    public let proposedRules: [ReplacementsSet.Rule]
    public let effects: [EntryEffect]

    public var replacementCount: Int { statuses.filter(\.isSaved).count }
    public var changeCount: Int { effects.reduce(0) { $0 + $1.changes.count } }
    public var affectedDictations: Int { effects.count }
    public var additionalMatches: Int { effects.filter(\.isAdditional).reduce(0) { $0 + $1.changes.count } }

    public static func make(
        phrases: [String], replacement: String, destination: Destination,
        global: ReplacementsSet, modes: [Mode],
        history: [HistorySnapshot.Item], searched: Set<HistorySnapshot.Reference>
    ) throws -> ReplacementPreview {
        let target: Mode?
        switch destination {
        case .global: target = nil
        case .mode(let id):
            guard let mode = modes.first(where: { $0.id == id }) else { throw Failure.destinationMissing }
            target = mode
        }
        let currentLocal = target?.replacements.rules ?? global.rules
        var proposed = ReplacementsSet(rules: currentLocal)
        var statuses: [PhraseStatus] = []
        var seen = Set<String>()
        for raw in phrases {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            let kind = status(of: phrase, replacement: replacement, local: currentLocal, target: target, global: global)
            statuses.append(.init(phrase: phrase, kind: kind))
            if statuses.last!.isSaved { proposed = proposed.addingLiteral(heard: phrase, replace: replacement) }
        }
        let modesByName = Dictionary(grouping: modes, by: \.name)
        var current: [String: ReplacementsStage] = [:]
        var next: [String: ReplacementsStage] = [:]
        func stages(for mode: Mode?) -> (ReplacementsStage, ReplacementsStage) {
            let key = mode?.id ?? ""
            if let c = current[key], let n = next[key] { return (c, n) }
            let globalRules = target == nil ? proposed.rules : global.rules
            let localRules = mode.map { $0.id == target?.id ? proposed.rules : $0.replacements.rules } ?? []
            let includeGlobal = mode?.replacements.includeGlobal ?? true
            let c = ReplacementsStage(rules: VocabularyMerge.rules(
                global: global.toRules(), local: (mode?.replacements.rules ?? []).toReplacementRules(),
                includeGlobal: includeGlobal))
            let n = ReplacementsStage(rules: VocabularyMerge.rules(
                global: globalRules.toReplacementRules(), local: localRules.toReplacementRules(),
                includeGlobal: includeGlobal))
            current[key] = c
            next[key] = n
            return (c, n)
        }
        let savedPhrases = statuses.filter(\.isSaved).map(\.phrase)
        var effects: [EntryEffect] = []
        for item in history {
            try Task.checkCancellation()
            let matches = modesByName[item.entry.modeName] ?? []
            let resolved = matches.count == 1 ? matches.first : nil
            let evaluated: Mode?
            if let target {
                if let resolved, resolved.id != target.id { continue }
                evaluated = target
            } else {
                if let resolved, !resolved.replacements.includeGlobal { continue }
                evaluated = resolved
            }
            let (currentStage, nextStage) = stages(for: evaluated)
            let before = run(currentStage, item.entry.heard)
            let after = run(nextStage, item.entry.heard)
            guard before.text != after.text else { continue }
            let attribution = Dictionary(
                savedPhrases.flatMap { phrase in
                    [(attributionKey(phrase), phrase), (attributionKey(run(currentStage, phrase).text), phrase)]
                },
                uniquingKeysWith: { first, _ in first })
            let changes = hunks(from: before.text, to: after.text).map { hunk in
                Change(range: hunk.range, before: hunk.before, after: hunk.after,
                       phrase: attribution[attributionKey(hunk.before)])
            }
            effects.append(EntryEffect(
                reference: item.reference, modeName: item.entry.modeName, modeUnknown: resolved == nil,
                isAdditional: !searched.contains(item.reference), currentText: before.text, proposedText: after.text,
                wholeUtterance: after.wholeUtterance && !before.wholeUtterance, changes: changes))
        }
        let ordered = effects.filter(\.isAdditional) + effects.filter { !$0.isAdditional }
        return ReplacementPreview(
            destination: destination, replacement: replacement, statuses: statuses,
            proposedRules: proposed.rules, effects: ordered)
    }

    private static func status(
        of phrase: String, replacement: String, local: [ReplacementsSet.Rule], target: Mode?, global: ReplacementsSet
    ) -> PhraseStatus.Kind {
        func literal(_ rules: [ReplacementsSet.Rule]) -> ReplacementsSet.Rule? {
            rules.first { !$0.regex && $0.heard.caseInsensitiveCompare(phrase) == .orderedSame }
        }
        if let existing = literal(local) {
            return existing.replace == replacement ? .alreadyAdded : .conflicts(currentOutput: existing.replace)
        }
        if let target, target.replacements.includeGlobal, let inherited = literal(global.rules) {
            return inherited.replace == replacement ? .alreadyAdded : .overridesGlobal(globalOutput: inherited.replace)
        }
        return .add
    }

    private static func run(_ stage: ReplacementsStage, _ text: String) -> (text: String, wholeUtterance: Bool) {
        var context = PipelineContext(text: text)
        stage.apply(&context)
        return (context.bareReplacement?.text ?? context.text, context.bareReplacement != nil)
    }

    private static func attributionKey(_ text: String) -> String {
        words(text).map { FuzzyCorrector.normalize(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private static func hunks(from old: String, to new: String) -> [(range: Range<String.Index>, before: String, after: String)] {
        let a = words(old), b = words(new)
        let difference = b.map(String.init).difference(from: a.map(String.init))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(range: Range<String.Index>, before: String, after: String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
                i += 1; j += 1
                continue
            }
            let startI = i, startJ = j
            while i < a.count, removed.contains(i) { i += 1 }
            while j < b.count, inserted.contains(j) { j += 1 }
            let lower = startI < a.count ? a[startI].startIndex : old.endIndex
            let upper = i > startI ? a[i - 1].endIndex : lower
            let after = j > startJ ? String(new[b[startJ].startIndex..<b[j - 1].endIndex]) : ""
            result.append(trimmed(old, lower..<upper, after: after))
        }
        return result
    }

    private static func trimmed(
        _ old: String, _ range: Range<String.Index>, after: String
    ) -> (range: Range<String.Index>, before: String, after: String) {
        var lower = range.lowerBound, upper = range.upperBound
        var after = Substring(after)
        func isEdge(_ c: Character) -> Bool { !c.isLetter && !c.isNumber }
        while lower < upper, let first = after.first, old[lower] == first, isEdge(first) {
            lower = old.index(after: lower)
            after = after.dropFirst()
        }
        while lower < upper, let last = after.last, old[old.index(before: upper)] == last, isEdge(last) {
            upper = old.index(before: upper)
            after = after.dropLast()
        }
        return (lower..<upper, String(old[lower..<upper]), String(after))
    }
}
