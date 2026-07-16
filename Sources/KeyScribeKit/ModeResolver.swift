import Foundation

public struct RoutingContext: Equatable, Sendable {
    public var bundleId: String?
    public var url: String?
    public var windowTitle: String?
    public init(bundleId: String? = nil, url: String? = nil, windowTitle: String? = nil) {
        self.bundleId = bundleId
        self.url = url
        self.windowTitle = windowTitle
    }
}

// Why a mode was chosen for a dictation, recorded for the History "how this was chosen" line.
// User-facing copy lives in the app; this is the durable, Codable key.
public enum ModeChoiceReason: String, Codable, Sendable, Equatable {
    case oneShot = "one_shot"           // menu "Dictate with" pick
    case triggerKey = "trigger_key"     // the pressed key selected the mode
    case contextRule = "context_rule"   // constraints won Phase-A resolution
    case spokenPhrase = "spoken_phrase" // Phase-B suffix route
    case fallback = "fallback"          // Direct floor caught it
}

// Phase-A result carries the resolved mode AND why it was chosen (key / context / fallback — the cases the
// resolver itself can distinguish; oneShot is applied by DictationController before resolution).
public struct PhaseAResult: Equatable, Sendable {
    public var mode: Mode
    public var reason: ModeChoiceReason
    public init(mode: Mode, reason: ModeChoiceReason) {
        self.mode = mode
        self.reason = reason
    }
}

public struct PhaseBResult: Equatable, Sendable {
    public var routedModeId: String?
    public var transcript: String
    public var matchedPhrase: String?
    public init(routedModeId: String?, transcript: String, matchedPhrase: String? = nil) {
        self.routedModeId = routedModeId
        self.transcript = transcript
        self.matchedPhrase = matchedPhrase
    }
}

// Two-phase routing (design.md §4.3). Phase A runs before STT from key + routing context;
// Phase B runs after STT from trigger-phrase suffixes, constrained to Phase A's eligible set.
public enum ModeResolver {
    public static func eligibleModes(_ modes: [Mode], context: RoutingContext) -> [Mode] {
        modes.filter { $0.enabled && isEligible($0, context) }
    }

    public static func resolvePhaseA(
        modes: [Mode], directFallback: Mode, context: RoutingContext, triggerKey: String?,
        eligible eligibleOverride: [Mode]? = nil
    ) -> Mode {
        resolvePhaseAWithReason(
            modes: modes, directFallback: directFallback, context: context, triggerKey: triggerKey,
            eligible: eligibleOverride).mode
    }

    // Same resolution as resolvePhaseA, plus WHY the mode was chosen. Semantics are unchanged — the reason
    // just names which branch won.
    public static func resolvePhaseAWithReason(
        modes: [Mode], directFallback: Mode, context: RoutingContext, triggerKey: String?,
        eligible eligibleOverride: [Mode]? = nil
    ) -> PhaseAResult {
        let enabled = modes.filter(\.enabled)
        // Reuse the caller's eligible set (also needed for Phase B) so the enabled∧isEligible constraint-
        // regex scan isn't repeated.
        let eligible = eligibleOverride ?? enabled.filter { isEligible($0, context) }

        // 1. Explicit key binding, gated by context. Among eligible modes bound to the pressed key, the
        //    most specific wins (ties → declaration order). If modes are bound but none eligible here, fall
        //    through to `directFallback`, the always-on-device no-LLM floor (design.md §4.3).
        if let key = triggerKey {
            let wanted = normalizeKey(key)
            let bound = enabled.filter { $0.triggerKeys.contains { normalizeKey($0.key) == wanted } }
            if !bound.isEmpty {
                if let m = mostSpecific(bound.filter { isEligible($0, context) }, context) {
                    // A bound mode that also carries a matching context rule is still "started by its shortcut"
                    // from the user's view — the key is what fired it.
                    return PhaseAResult(mode: m, reason: .triggerKey)
                }
                return PhaseAResult(mode: directFallback, reason: .fallback)
            }
        }
        // 2. Context auto-start: the most specific eligible *constrained* mode (ties → declaration
        //    order). Only constrained modes auto-start; unconstrained modes need a key or voice phrase.
        if let m = mostSpecific(eligible.filter { !$0.constraints.isEmpty }, context) {
            return PhaseAResult(mode: m, reason: .contextRule)
        }
        // 3. Nothing else applies → the Direct floor (no separate "default mode"; design.md §4.3).
        return PhaseAResult(mode: directFallback, reason: .fallback)
    }

    public static func resolvePhaseB(
        eligibleModes: [Mode], transcript: String, context: RoutingContext = .init()
    ) -> PhaseBResult {
        // Among eligible modes whose phrase matches the suffix, pick by specificity → declaration order
        // (strict `>` in declaration order keeps the earliest-declared on a tie).
        var best: (mode: Mode, stripped: String, phrase: String)?
        var bestScore = Int.min
        for mode in eligibleModes {
            for phrase in mode.triggerPhrases {
                guard let stripped = matchSuffix(phrase, in: transcript) else { continue }
                let score = specificity(mode, context)
                if score > bestScore {
                    bestScore = score
                    best = (mode, stripped, phrase)
                }
                break
            }
        }
        if let best {
            return PhaseBResult(routedModeId: best.mode.id, transcript: best.stripped, matchedPhrase: best.phrase)
        }
        return PhaseBResult(routedModeId: nil, transcript: transcript)
    }

    // Whether any enabled mode could match on URL — the gate for probing the browser URL at all
    // (the probe needs Apple Events + the Automation prompt, so it's opt-in; design.md §4.4).
    public static func requiresURLContext(_ modes: [Mode]) -> Bool {
        modes.contains { mode in
            mode.enabled && mode.constraints.contains { constraint in
                constraint.urlPattern.map { RegexCache.routingRegex($0) != nil } ?? false
            }
        }
    }

    // Whether any enabled mode could match on the window title — the gate for reading the focused
    // window's title at all (an extra AX round trip, so it is read only when a mode actually needs it).
    public static func requiresWindowTitleContext(_ modes: [Mode]) -> Bool {
        modes.contains { mode in
            mode.enabled && mode.constraints.contains { constraint in
                constraint.windowTitle.map { RegexCache.routingRegex($0) != nil } ?? false
            }
        }
    }

    private static func isEligible(_ mode: Mode, _ context: RoutingContext) -> Bool {
        if mode.constraints.isEmpty { return true }
        return mode.constraints.contains { matches($0, context) }
    }

    // Specificity of a mode in this context: the most specific *matching* constraint wins. A constraint
    // ANDs all of its fields, and the score sums the narrowness of each present field — narrowest first:
    // url_pattern=4 > window_title=3 > bundle_id=2 > bundle_prefix=1 > unconstrained=0. Fields combine, so
    // bundle_id+url_pattern (6) beats url_pattern alone (4) (design.md §4.3).
    private static func specificity(_ mode: Mode, _ context: RoutingContext) -> Int {
        mode.constraints.filter { matches($0, context) }.map(constraintScore).max() ?? 0
    }

    private static func constraintScore(_ c: Mode.Constraint) -> Int {
        (c.bundlePrefix != nil ? 1 : 0) + (c.bundleId != nil ? 2 : 0)
            + (c.windowTitle != nil ? 3 : 0) + (c.urlPattern != nil ? 4 : 0)
    }

    private static func mostSpecific(_ modes: [Mode], _ context: RoutingContext) -> Mode? {
        var best: Mode?
        var bestScore = Int.min
        for m in modes {
            let score = specificity(m, context)
            if score > bestScore { bestScore = score; best = m }
        }
        return best
    }

    private static func matches(_ constraint: Mode.Constraint, _ context: RoutingContext) -> Bool {
        if let bundle = constraint.bundleId, bundle != context.bundleId { return false }
        if let prefix = constraint.bundlePrefix {
            guard let bundle = context.bundleId,
                  bundle.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        }
        if let pattern = constraint.urlPattern {
            guard let url = context.url, regexFound(pattern, in: url) else { return false }
        }
        if let pattern = constraint.windowTitle {
            guard let title = context.windowTitle, regexFound(pattern, in: title) else { return false }
        }
        return true
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static func regexFound(_ pattern: String, in text: String) -> Bool {
        guard let re = RegexCache.routingRegex(pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // Returns the transcript with the matched suffix removed (trimmed), or nil if the phrase doesn't match
    // at the end. The phrase is a regex (a plain phrase is itself valid), with three guarantees that make a
    // bare phrase route reliably:
    //   1. case-insensitive by default ((?-i) opts back in);
    //   2. anchored to the end — trailing whitespace/punctuation trimmed first, then the matched span must
    //      reach the end (a bare phrase has no `$`, so scan for the last match at the end);
    //   3. a leading word boundary, so "as prompt" doesn't fire inside "has prompt".
    private static func matchSuffix(_ pattern: String, in transcript: String) -> String? {
        let trimmed = trimTrailingNoise(transcript)
        guard let re = RegexCache.routingRegex(pattern, options: [.caseInsensitive]) else { return nil }
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = re.matches(in: trimmed, range: full).last,
              match.range.length > 0,
              match.range.location + match.range.length == full.length,
              let r = Range(match.range, in: trimmed),
              startsOnWordBoundary(r, in: trimmed) else { return nil }
        return String(trimmed[trimmed.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    // `\b`-style boundary at the match start: reject only when the match begins with a word char glued to a
    // word char before it ("h|as prompt"). A match beginning on whitespace/punctuation needs no boundary.
    private static func startsOnWordBoundary(_ r: Range<String.Index>, in s: String) -> Bool {
        guard r.lowerBound > s.startIndex else { return true }
        let first = s[r.lowerBound]
        let before = s[s.index(before: r.lowerBound)]
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        return !(isWord(first) && isWord(before))
    }

    private static func trimTrailingNoise(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            guard s[prev].isWhitespace || s[prev].isPunctuation else { break }
            end = prev
        }
        return String(s[s.startIndex..<end])
    }
}
