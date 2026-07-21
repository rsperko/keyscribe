import Foundation

public struct ReplacementRule: Sendable, Equatable {
    public let heard: String
    public let replace: String
    public let isRegex: Bool

    public init(heard: String, replace: String, isRegex: Bool) {
        self.heard = heard
        self.replace = replace
        self.isRegex = isRegex
    }
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
        let regex: NSRegularExpression
        let template: String
        let submit: Mode.Submit?
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
            // non-terminal marker is invalid config and drops the rule (agent_notes/replace_with_return).
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

    public init(rules: [ReplacementRule]) {
        self.rules = rules
        var prepared: [PreparedRule] = []
        var droppedForReturnMarker: [ReplacementRule] = []
        for rule in rules {
            switch Self.prepare(rule) {
            case .ready(let regex, let template, let submit):
                prepared.append(PreparedRule(regex: regex, template: template, submit: submit))
            case .droppedForReturnMarker:
                droppedForReturnMarker.append(rule)
            case .dropped:
                continue
            }
        }
        self.preparedRulesHighestTiePriorityFirst = prepared
        self.droppedForReturnMarker = droppedForReturnMarker
        self.mayHaveIdentityReplacement = rules.contains { rule in
            guard !rule.heard.isEmpty else { return false }
            return rule.isRegex || rule.heard.lowercased() == rule.replace.lowercased()
        }
    }

    public func apply(_ context: inout PipelineContext) {
        let input = context.text
        let transformed = transform(input)
        context.text = transformed
        // Scan for a whole-utterance owner unless nothing could match: text unchanged, no identity rule,
        // and no pause punctuation to bridge.
        let mayOwnUtterance = transformed != input || mayHaveIdentityReplacement || Self.containsPauseMark(input)
        context.bareReplacement = mayOwnUtterance
            ? bareReplacement(for: input)
            : nil
    }

    // Transform only the plain runs between ⟦SN:…⟧ tokens so a rule can never rewrite a verbatim/clipboard
    // token body minted upstream (design.md §4.2).
    private func transform(_ text: String) -> String {
        SentinelText.mappingOutsideSentinels(text) { run in
            var result = ""
            var cursor = run.startIndex
            while cursor < run.endIndex {
                if let winner = winningMatch(in: run, at: cursor) {
                    result += winner.rule.regex.replacementString(
                        for: winner.result, in: run, offset: 0, template: winner.rule.template)
                    cursor = winner.range.upperBound
                } else {
                    let next = run.index(after: cursor)
                    result.append(contentsOf: run[cursor..<next])
                    cursor = next
                }
            }
            return SentinelText.neutralizeOpen(result)
        }
    }

    private func winningMatch(in text: String, at cursor: String.Index) -> PreparedMatch? {
        let searchRange = NSRange(cursor..<text.endIndex, in: text)
        let options: NSRegularExpression.MatchingOptions = [
            .anchored, .withTransparentBounds, .withoutAnchoringBounds,
        ]
        var winner: PreparedMatch?
        for rule in preparedRulesHighestTiePriorityFirst {
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
        let (core, leading, trailing) = utteranceCore(of: input)
        guard !core.isEmpty else { return nil }
        // A protected token (verbatim/clipboard) means no single rule cleanly owns the utterance — fall
        // through rather than let a rule match across the opaque token.
        guard !SentinelText.containsSentinel(core) else { return nil }
        if let owned = wholeUtteranceOutput(of: core) {
            return BareReplacement(text: leading + owned.text + trailing, submit: owned.submit)
        }
        // A mid-utterance pause is sentence punctuation the contiguous match can't cross; retry across a
        // de-paused core (whole-utterance only — still requires an end-to-end match).
        let dePaused = Self.dePause(core)
        if dePaused != core, let owned = wholeUtteranceOutput(of: dePaused) {
            return BareReplacement(text: leading + owned.text + trailing, submit: owned.submit)
        }
        return nil
    }

    private func wholeUtteranceOutput(of core: String) -> (text: String, submit: Mode.Submit?)? {
        let coreRange = NSRange(core.startIndex..., in: core)
        guard let winner = winningMatch(in: core, at: core.startIndex), winner.result.range == coreRange else { return nil }
        let generated = SentinelText.neutralizeOpen(
            winner.rule.regex.replacementString(
                for: winner.result, in: core, offset: 0, template: winner.rule.template))
        return (generated, winner.rule.submit)
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
