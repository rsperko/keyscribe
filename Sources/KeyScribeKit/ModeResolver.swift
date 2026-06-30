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

public struct PhaseBResult: Equatable, Sendable {
    public var routedModeId: String?
    public var transcript: String
    public init(routedModeId: String?, transcript: String) {
        self.routedModeId = routedModeId
        self.transcript = transcript
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
        let enabled = modes.filter(\.enabled)
        // The caller usually already computed the eligible set (it needs it for Phase B); reuse it so
        // the enabled∧isEligible scan — which runs each mode's constraint regexes — is not repeated.
        let eligible = eligibleOverride ?? enabled.filter { isEligible($0, context) }

        // 1. Explicit key binding. App constraints gate the press too: only modes eligible in the
        //    current context can run. Among the eligible modes bound to the pressed key, the most
        //    specific wins (ties → declaration order). When modes are bound to the key but none is
        //    eligible here, the press neither blocks nor substitutes a different mode — it falls through
        //    to `directFallback`, the always-on-device, no-LLM floor (design.md §4.3).
        if let key = triggerKey {
            let wanted = normalizeKey(key)
            let bound = enabled.filter { $0.triggerKeys.contains { normalizeKey($0.key) == wanted } }
            if !bound.isEmpty {
                if let m = mostSpecific(bound.filter { isEligible($0, context) }, context) { return m }
                return directFallback
            }
        }
        // 2. Context auto-start: the most specific eligible *constrained* mode (ties → declaration
        //    order). Only constrained modes auto-start; unconstrained modes need a key or voice phrase.
        if let m = mostSpecific(eligible.filter { !$0.constraints.isEmpty }, context) { return m }
        // 3. Nothing else applies → the Direct floor (no separate "default mode"; design.md §4.3).
        return directFallback
    }

    public static func resolvePhaseB(
        eligibleModes: [Mode], transcript: String, context: RoutingContext = .init()
    ) -> PhaseBResult {
        // Among eligible modes whose phrase matches the suffix, pick by specificity → declaration
        // order (same resolver as Phase A). Iterating in declaration order with a strict `>` keeps
        // the earliest-declared on a specificity tie.
        var best: (mode: Mode, stripped: String)?
        var bestScore = Int.min
        for mode in eligibleModes {
            for phrase in mode.triggerPhrases {
                guard let stripped = matchSuffix(phrase, in: transcript) else { continue }
                let score = specificity(mode, context)
                if score > bestScore {
                    bestScore = score
                    best = (mode, stripped)
                }
                break
            }
        }
        if let best { return PhaseBResult(routedModeId: best.mode.id, transcript: best.stripped) }
        return PhaseBResult(routedModeId: nil, transcript: transcript)
    }

    // Whether any enabled mode could match on URL — the gate for probing the browser URL at all
    // (the probe needs Apple Events + the Automation prompt, so it's opt-in; design.md §4.4).
    public static func requiresURLContext(_ modes: [Mode]) -> Bool {
        modes.contains { $0.enabled && $0.constraints.contains { $0.urlPattern != nil } }
    }

    // Whether any enabled mode could match on the window title — the gate for reading the focused
    // window's title at all (an extra AX round trip, so it is read only when a mode actually needs it).
    public static func requiresWindowTitleContext(_ modes: [Mode]) -> Bool {
        modes.contains { $0.enabled && $0.constraints.contains { $0.windowTitle != nil } }
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
        guard let re = RegexCache.regex(pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // Returns the transcript with the matched suffix removed (trimmed), or nil if the phrase does
    // not match at the end. The phrase is a regex (a plain spoken phrase like "as prompt" is itself a
    // valid regex), so power users can write `(?i)\bas (a |an )?note$` while the common case stays a
    // bare phrase. Three guarantees make a bare phrase route reliably without any regex syntax:
    //   1. case-insensitive by default ((?-i) opts back in), as replacement rules are;
    //   2. anchored to the *end* — STT commonly capitalizes and appends a period, so trailing
    //      whitespace/punctuation is trimmed first, then the matched span must reach the end (a bare
    //      phrase carries no `$`, so the first match may sit earlier — scan for the one at the end);
    //   3. a leading word boundary, so "as prompt" does not fire inside "has prompt".
    private static func matchSuffix(_ pattern: String, in transcript: String) -> String? {
        let trimmed = trimTrailingNoise(transcript)
        guard let re = RegexCache.regex(pattern, options: [.caseInsensitive]) else { return nil }
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = re.matches(in: trimmed, range: full).last,
              match.range.length > 0,
              match.range.location + match.range.length == full.length,
              let r = Range(match.range, in: trimmed),
              startsOnWordBoundary(r, in: trimmed) else { return nil }
        return String(trimmed[trimmed.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    // A `\b`-style boundary at the match start: reject only when a word character would be split —
    // i.e. the match begins with a word char that is glued to a word char before it ("h|as prompt").
    // A match that begins on whitespace/punctuation needs no boundary (there is no word to split).
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
