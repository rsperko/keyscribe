import Foundation

public enum ReplacementOrigin: Sendable, Hashable {
    case global
    case mode(String)
}

public struct ReplacementRule: Sendable, Equatable {
    public let heard: String
    public let replace: String
    public let isRegex: Bool
    // Acts only when it matches everything said — a spoken command, never a word fix inside a sentence.
    public let wholeDictation: Bool
    public let origin: ReplacementOrigin?

    public init(
        heard: String, replace: String, isRegex: Bool, wholeDictation: Bool = false, origin: ReplacementOrigin? = nil
    ) {
        self.heard = heard
        self.replace = replace
        self.isRegex = isRegex
        self.wholeDictation = wholeDictation
        self.origin = origin
    }

    public func from(_ origin: ReplacementOrigin) -> ReplacementRule {
        ReplacementRule(heard: heard, replace: replace, isRegex: isRegex, wholeDictation: wholeDictation, origin: origin)
    }
}

// What one rule did to one dictation, from its winning matches. The flags are independent: a match can both
// land inside a word and drop its Return.
public struct ReplacementEffect: Sendable, Equatable {
    public var rule: ReplacementRule
    public var changedText: Bool
    public var insideWord: Bool
    public var returnOmitted: Bool
    public var ownsWholeDictation: Bool

    public init(rule: ReplacementRule, changedText: Bool, insideWord: Bool, returnOmitted: Bool, ownsWholeDictation: Bool) {
        self.rule = rule
        self.changedText = changedText
        self.insideWord = insideWord
        self.returnOmitted = returnOmitted
        self.ownsWholeDictation = ownsWholeDictation
    }

    // Owning the dictation is an effect even when the words come out the same: it skips the AI rewrite and can
    // press Return.
    public var isMeaningful: Bool { changedText || ownsWholeDictation }
}

// Post-STT text stage. Literal matches are case-insensitive and word-boundary constrained ("pipe" never
// replaces inside "pipeline"; use a regex rule for substring matching). Literal replacement text is inserted
// verbatim ($ / \ are not template refs); regex rules use NSRegularExpression template substitution ($1, \$)
// and interpret `\n`/`\t`/`\r` as control chars (see ReplacementEscapes). An invalid regex is skipped, not
// fatal. Runs before tokenization (design.md §4.2.1); not protected from a later LLM rewrite (design.md §4.2).
public struct ReplacementsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.replacements
    public let rules: [ReplacementRule]

    // Regex + template resolved once at construction, so the per-dictation path is just matching. Invalid or
    // unsafe rules are dropped here.
    private struct PreparedRule {
        let source: ReplacementRule
        let regex: NSRegularExpression
        let template: String
        let submit: Mode.Submit?
        var wholeDictation: Bool { source.wholeDictation }
    }

    private struct PreparedMatch {
        let rule: PreparedRule
        let result: NSTextCheckingResult
        let range: Range<String.Index>
    }

    private let preparedRulesHighestTiePriorityFirst: [PreparedRule]

    // When the transform leaves text unchanged, the only possible whole-utterance owner is an *identity*
    // replacement (output == matched span); absent any such rule we skip the whole-utterance scan. A literal
    // rule is identity-capable iff heard == replace (case-insensitively); a regex can reproduce its input in
    // ways we can't cheaply rule out, so every regex is treated as identity-capable.
    private let mayHaveIdentityReplacement: Bool
    private let hasWholeDictationRule: Bool

    // Rules dropped specifically because their expanded template has an unescaped non-terminal `<CR>` (a key
    // action is only valid at the very end). Surfaced so the host can log a vanished rule — the drop itself is
    // unchanged. Other drop reasons (unsafe/invalid regex) are not tracked here.
    public let droppedForReturnMarker: [ReplacementRule]

    enum Preparation {
        case ready(regex: NSRegularExpression, template: String, submit: Mode.Submit?)
        case droppedForReturnMarker
        case dropped
    }

    static func prepare(_ rule: ReplacementRule) -> Preparation {
        func compile(_ pattern: String) -> NSRegularExpression? {
            RegexCache.regex(pattern, options: [.caseInsensitive])
        }
        if rule.isRegex {
            // Case-insensitive by default: match input is STT output, whose casing the engine chooses, so
            // a case-sensitive pattern would silently miss. Opt back in with an inline `(?-i)`.
            guard ReplacementSafety.isSafe(rule.heard), let re = compile(rule.heard) else { return .dropped }
            // Recognize a terminal `<CR>` submit marker after escape expansion; an unescaped
            // non-terminal marker is invalid config and drops the rule.
            guard let parsed = ReturnSuffix.parse(ReplacementEscapes.expandTemplate(rule.replace)) else {
                return .droppedForReturnMarker
            }
            return .ready(regex: re, template: parsed.template, submit: parsed.submit)
        }
        guard let first = rule.heard.first, let last = rule.heard.last else { return .dropped }
        // `\b` only exists between a word and a non-word char, so wrapping a term whose edge is already
        // punctuation ("/resume", "c++") in `\b` makes it unmatchable. Anchor `\b` only on a word-char
        // edge; a punctuation/space edge stays a plain substring boundary. So "pipe" still skips
        // "pipeline" and a leading-space glue term (" at gmail dot com") still matches — both of which
        // `(?<!\w)…(?!\w)` would get wrong.
        let lead = Self.isWordCharacter(first) ? #"\b"# : ""
        let trail = Self.isWordCharacter(last) ? #"\b"# : ""
        let pattern = "\(lead)\(NSRegularExpression.escapedPattern(for: rule.heard))\(trail)"
        guard let re = compile(pattern) else { return .dropped }
        // Literal rules are never interpreted: `<CR>` in a literal replacement is inserted verbatim.
        return .ready(regex: re, template: NSRegularExpression.escapedTemplate(for: rule.replace), submit: nil)
    }

    public enum InactiveReason: Sendable, Equatable {
        case invalidPattern, unsafePattern, returnNotAtEnd

        public var phrase: String {
            switch self {
            case .invalidPattern: "pattern doesn’t compile"
            case .unsafePattern: "pattern could take too long to match"
            case .returnNotAtEnd: "<CR> not at the end"
            }
        }
    }

    // Rules this stage would drop. Settings refuses to save them, so they come from a hand-edited file, where
    // a rule that silently never runs is otherwise invisible.
    public static func inactiveRules(_ rules: [ReplacementRule]) -> [(heard: String, reason: InactiveReason)] {
        rules.compactMap { rule in
            switch prepare(rule) {
            case .ready: return nil
            case .droppedForReturnMarker: return (rule.heard, .returnNotAtEnd)
            case .dropped:
                guard rule.isRegex else { return nil }
                return (rule.heard, ReplacementSafety.isSafe(rule.heard) ? .invalidPattern : .unsafePattern)
            }
        }
    }

    public init(rules: [ReplacementRule]) {
        self.rules = rules
        var prepared: [PreparedRule] = []
        var droppedForReturnMarker: [ReplacementRule] = []
        for rule in rules {
            switch Self.prepare(rule) {
            case .ready(let regex, let template, let submit):
                prepared.append(PreparedRule(source: rule, regex: regex, template: template, submit: submit))
            case .droppedForReturnMarker:
                droppedForReturnMarker.append(rule)
            case .dropped:
                continue
            }
        }
        self.preparedRulesHighestTiePriorityFirst = prepared
        self.droppedForReturnMarker = droppedForReturnMarker
        self.hasWholeDictationRule = prepared.contains(where: \.wholeDictation)
        self.mayHaveIdentityReplacement = rules.contains { rule in
            guard !rule.heard.isEmpty else { return false }
            return rule.isRegex || rule.heard.lowercased() == rule.replace.lowercased()
        }
    }

    public func apply(_ context: inout PipelineContext) {
        let input = context.text
        let (transformed, effects) = transform(input)
        context.text = transformed
        // Scan for a whole-utterance owner unless nothing could match: text unchanged, no identity rule, no
        // whole-dictation rule (the transform never runs those, so an unchanged text says nothing about them),
        // and no pause punctuation to bridge.
        let mayOwnUtterance = transformed != input || mayHaveIdentityReplacement || hasWholeDictationRule
            || Self.containsPauseMark(input)
        let owner = mayOwnUtterance ? owningReplacement(for: input) : nil
        context.bareReplacement = owner?.replacement
        context.bareSegments = owner?.segments
        context.firedReplacements = owner.map { [$0.rule] } ?? effects.map(\.rule)
        context.replacementEffects = owner.map {
            [ReplacementEffect(rule: $0.rule, changedText: $0.changed, insideWord: false, returnOmitted: false, ownsWholeDictation: true)]
        } ?? effects
    }

    // Transform only the plain runs between ⟦SN:…⟧ tokens so a rule can never rewrite a verbatim/clipboard
    // token body minted upstream (design.md §4.2).
    private func transform(_ text: String) -> (text: String, effects: [ReplacementEffect]) {
        var effects: [ReplacementEffect] = []
        let transformed = SentinelText.mappingOutsideSentinels(text) { run in
            var result = ""
            var cursor = run.startIndex
            while cursor < run.endIndex {
                if let winner = winningMatch(in: run, at: cursor, includingWholeDictation: false) {
                    let output = winner.rule.regex.replacementString(
                        for: winner.result, in: run, offset: 0, template: winner.rule.template)
                    let changed = output != run[winner.range]
                    let effect = ReplacementEffect(
                        rule: winner.rule.source, changedText: changed,
                        insideWord: changed && Self.landsInsideWord(winner.range, in: run),
                        returnOmitted: winner.rule.submit != nil, ownsWholeDictation: false)
                    if let i = effects.firstIndex(where: { $0.rule == effect.rule }) {
                        effects[i].changedText = effects[i].changedText || effect.changedText
                        effects[i].insideWord = effects[i].insideWord || effect.insideWord
                    } else {
                        effects.append(effect)
                    }
                    result += output
                    cursor = winner.range.upperBound
                } else {
                    let next = run.index(after: cursor)
                    result.append(contentsOf: run[cursor..<next])
                    cursor = next
                }
            }
            return SentinelText.neutralizeOpen(result)
        }
        return (transformed, effects)
    }

    // A match edge that splits two word characters cut a word in half ("copy" → "co|py"). Uses the same
    // regex `\w` a pattern's own boundaries use, so a rule wrapped to match whole words is never flagged.
    static func landsInsideWord(_ range: Range<String.Index>, in text: String) -> Bool {
        guard !range.isEmpty else { return false }
        let first = text[range.lowerBound]
        let last = text[text.index(before: range.upperBound)]
        if range.lowerBound > text.startIndex,
           isRegexWordCharacter(text[text.index(before: range.lowerBound)]), isRegexWordCharacter(first) { return true }
        if range.upperBound < text.endIndex,
           isRegexWordCharacter(text[range.upperBound]), isRegexWordCharacter(last) { return true }
        return false
    }

    private static let wordCharacter = try! NSRegularExpression(pattern: #"^\w+$"#)
    static func isRegexWordCharacter(_ c: Character) -> Bool {
        let s = String(c)
        return wordCharacter.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func winningMatch(in text: String, at cursor: String.Index, includingWholeDictation: Bool) -> PreparedMatch? {
        let searchRange = NSRange(cursor..<text.endIndex, in: text)
        let options: NSRegularExpression.MatchingOptions = [
            .anchored, .withTransparentBounds, .withoutAnchoringBounds,
        ]
        var winner: PreparedMatch?
        for rule in preparedRulesHighestTiePriorityFirst where includingWholeDictation || !rule.wholeDictation {
            guard let result = rule.regex.firstMatch(in: text, options: options, range: searchRange),
                  result.range.length > 0,
                  let range = Range(result.range, in: text)
            else { continue }
            if winner == nil || result.range.length > winner!.result.range.length {
                winner = PreparedMatch(rule: rule, result: result, range: range)
            }
        }
        return winner
    }

    public func bareReplacement(for input: String) -> BareReplacement? {
        owningReplacement(for: input)?.replacement
    }

    private func owningReplacement(
        for input: String
    ) -> (replacement: BareReplacement, rule: ReplacementRule, changed: Bool, segments: [BareSegment]?)? {
        let (core, leading, trailing) = utteranceCore(of: input)
        guard !core.isEmpty else { return nil }
        // A protected token (verbatim/clipboard) means no single rule cleanly owns the utterance — fall
        // through rather than let a rule match across the opaque token.
        guard !SentinelText.containsSentinel(core) else { return nil }
        // A mid-utterance pause is sentence punctuation the contiguous match can't cross; retry across a
        // de-paused core (whole-utterance only — still requires an end-to-end match).
        let dePaused = Self.dePause(core)
        guard let owned = wholeUtteranceOutput(of: core) ?? (dePaused != core ? wholeUtteranceOutput(of: dePaused) : nil)
        else { return nil }
        let segments = owned.segments.map { [.literal(leading)] + $0 + [.literal(trailing)] }
        return (BareReplacement(text: leading + owned.text + trailing, submit: owned.submit), owned.rule, owned.text != core,
                segments)
    }

    private func wholeUtteranceOutput(
        of core: String
    ) -> (text: String, submit: Mode.Submit?, rule: ReplacementRule, segments: [BareSegment]?)? {
        let coreRange = NSRange(core.startIndex..., in: core)
        guard let winner = winningMatch(in: core, at: core.startIndex, includingWholeDictation: true),
              winner.result.range == coreRange else { return nil }
        let raw = winner.rule.regex.replacementString(
            for: winner.result, in: core, offset: 0, template: winner.rule.template)
        let segments = Self.segments(of: winner.rule.template, filledFrom: winner.result, in: core)
        let joined = segments?.map { segment -> String in
            switch segment {
            case .literal(let s), .captured(let s): s
            }
        }.joined()
        // Splitting is only trusted when it reproduces the engine's own output; otherwise the output stays frozen.
        return (SentinelText.neutralizeOpen(raw), winner.rule.submit, winner.rule.source, joined == raw ? segments : nil)
    }

    // Mirrors NSRegularExpression's template rules: a backslash makes the next character literal, and `$` takes
    // digits for as long as they still name a group in the pattern.
    static func segments(
        of template: String, filledFrom result: NSTextCheckingResult, in text: String
    ) -> [BareSegment]? {
        let groups = result.numberOfRanges
        var segments: [BareSegment] = []
        var literal = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                literal.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count, let first = chars[i + 1].wholeNumberValue, chars[i + 1].isASCII, first < groups {
                var group = first
                var j = i + 2
                while j < chars.count, chars[j].isASCII, let digit = chars[j].wholeNumberValue, group * 10 + digit < groups {
                    group = group * 10 + digit
                    j += 1
                }
                if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
                let range = result.range(at: group)
                let captured = range.location == NSNotFound ? "" : (Range(range, in: text).map { String(text[$0]) } ?? "")
                segments.append(.captured(captured))
                i = j
                continue
            }
            literal.append(c)
            i += 1
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }

    // Sentence punctuation STT inserts at a boundary — one set for both trailing-trim and pause-bridging.
    // Dash excluded: word-internal (ranges, compounds), not a pause mark.
    static let sentencePunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    // A boundary mark adjacent to whitespace is a pause; one inside a word ("e.g.", "12:30") is not.
    private static func isPauseMark(_ chars: [Character], at i: Int) -> Bool {
        guard sentencePunctuation.contains(chars[i]) else { return false }
        let prevSpace = i == 0 || chars[i - 1].isWhitespace
        let nextSpace = i == chars.count - 1 || chars[i + 1].isWhitespace
        return prevSpace || nextSpace
    }

    // Gate predicate: lets a literal-only rule set reach the de-pause fallback.
    static func containsPauseMark(_ s: String) -> Bool {
        let chars = Array(s)
        return chars.indices.contains { isPauseMark(chars, at: $0) }
    }

    // "Duct tape. Get" → "Duct tape Get": drop pause marks, collapse whitespace.
    private static func dePause(_ core: String) -> String {
        let chars = Array(core)
        var out = ""
        var lastWasSpace = false
        for i in chars.indices {
            if isPauseMark(chars, at: i) { continue }
            let c = chars[i]
            if c.isWhitespace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        if out.last == " " { out.removeLast() }
        return out
    }

    // Matches regex `\w` closely enough for boundary placement: ASCII/Unicode letters, digits, "_".
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    // A LiveEdits control char (`\n` from "insert new line", `\t` from "insert tab") is command output, not
    // STT cruft: trim it off the core so a rule can own the words, then re-attach as `leading`/`trailing` so
    // the dictated newline/tab survives. Ordinary STT residue (whitespace, trailing sentence punctuation) is
    // discarded.
    private static let liveEditControl: Set<Character> = ["\n", "\t"]
    private func utteranceCore(of input: String) -> (core: String, leading: String, trailing: String) {
        let chars = Array(input)
        var lo = 0, hi = chars.count
        var leading = "", trailing = ""
        while lo < hi {
            let c = chars[lo]
            if Self.liveEditControl.contains(c) { leading.append(c); lo += 1 }
            else if c.isWhitespace { lo += 1 }
            else { break }
        }
        while hi > lo {
            let c = chars[hi - 1]
            if Self.liveEditControl.contains(c) { trailing.insert(c, at: trailing.startIndex); hi -= 1 }
            else if c.isWhitespace || Self.sentencePunctuation.contains(c) { hi -= 1 }
            else { break }
        }
        return (String(chars[lo..<hi]), leading, trailing)
    }
}
