import Foundation

// Deterministic spoken-number → digits normalization ("twenty five" → "25"). Opt-in per mode
// (commands.numbers) and conservative: a run that does not form a single unambiguous cardinal is left
// exactly as spoken. That bail preserves year idioms like "twenty twenty six" / "nineteen ninety five"
// (two tens/teens with no scale word between) instead of mangling them — wrong number output is worse
// than none.
//
// Beyond bare cardinals it folds in low-ambiguity, locale-light decorators (Tier 1): leading sign
// ("minus five" → "-5", only when not preceded by a number so subtraction is left alone), decimals
// ("three point one four" → "3.14", fractional part single digits only), percent ("fifty percent" →
// "50%"), and ordinals ("twenty first" → "21st"). Each is parsed only around a validating cardinal;
// anything ambiguous echoes verbatim. Locale/context shaping (currency, thousands grouping, dates,
// times) is out of scope — the LLM rewrite's job (design.md §4.2, Tier 2).
public enum InverseTextNormalizer {
    private enum Kind { case ones, teen, tens, hundred, scale }

    private struct Token {
        let text: String
        let source: Int
        let original: String
        let isFirstPart: Bool
        let isLastPart: Bool
    }

    private static let words: [String: (value: Int, kind: Kind)] = {
        var m: [String: (Int, Kind)] = [
            "zero": (0, .ones), "one": (1, .ones), "two": (2, .ones), "three": (3, .ones),
            "four": (4, .ones), "five": (5, .ones), "six": (6, .ones), "seven": (7, .ones),
            "eight": (8, .ones), "nine": (9, .ones),
            "ten": (10, .teen), "eleven": (11, .teen), "twelve": (12, .teen), "thirteen": (13, .teen),
            "fourteen": (14, .teen), "fifteen": (15, .teen), "sixteen": (16, .teen),
            "seventeen": (17, .teen), "eighteen": (18, .teen), "nineteen": (19, .teen),
            "twenty": (20, .tens), "thirty": (30, .tens), "forty": (40, .tens), "fifty": (50, .tens),
            "sixty": (60, .tens), "seventy": (70, .tens), "eighty": (80, .tens), "ninety": (90, .tens),
            "hundred": (100, .hundred),
            "thousand": (1000, .scale), "million": (1_000_000, .scale), "billion": (1_000_000_000, .scale),
        ]
        return m
    }()

    private static let punctuation = CharacterSet(charactersIn: ".,!?;:")

    // Ordinal spoken form → the cardinal canonical it maps to ("twenty first" parses as twenty + one,
    // then takes the suffix derived from the final value).
    private static let ordinalToCardinal: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five",
        "sixth": "six", "seventh": "seven", "eighth": "eight", "ninth": "nine", "tenth": "ten",
        "eleventh": "eleven", "twelfth": "twelve", "thirteenth": "thirteen", "fourteenth": "fourteen",
        "fifteenth": "fifteen", "sixteenth": "sixteen", "seventeenth": "seventeen",
        "eighteenth": "eighteen", "nineteenth": "nineteen", "twentieth": "twenty",
        "thirtieth": "thirty", "fortieth": "forty", "fiftieth": "fifty", "sixtieth": "sixty",
        "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety",
        "hundredth": "hundred", "thousandth": "thousand", "millionth": "million", "billionth": "billion",
    ]

    public static func apply(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
            .enumerated()
            .flatMap { source, token in splitHyphenatedNumber(token, source: source) }
        var out: [String] = []
        var i = 0
        var precededByNumber = false
        while i < tokens.count {
            if let (consumed, rendered) = matchExpression(tokens, from: i, precededByNumber: precededByNumber) {
                out.append(rendered)
                i += consumed
                precededByNumber = true
            } else {
                let token = tokens[i]
                out.append(token.original)
                precededByNumber = isNumberWord(canonical(token.text))
                i = tokens[i...].firstIndex(where: { $0.source != token.source }) ?? tokens.endIndex
            }
        }
        return out.joined(separator: " ")
    }

    // Consumes a maximal number expression starting at `from`: an optional sign, a cardinal/ordinal
    // run, then optional decimal and percent decorators. Returns the token count consumed and the
    // rendered string — digits when the run validates and clears the conservatism gate, otherwise the
    // spoken words verbatim. Returns nil when `from` is not the start of a number expression at all.
    private static func matchExpression(_ tokens: [Token], from start: Int, precededByNumber: Bool) -> (Int, String)? {
        var idx = start
        var sign = ""
        let firstCanon = canonical(tokens[start].text)
        if firstCanon == "minus" || firstCanon == "negative" {
            guard !precededByNumber, !hasTrailingPunct(tokens[start].text), idx + 1 < tokens.count, isNumberWord(canonical(tokens[idx + 1].text)) else { return nil }
            sign = "-"
            idx += 1
        }

        var run: [String] = []
        var isOrdinal = false
        var stopped = false
        while idx < tokens.count && !stopped {
            let raw = tokens[idx]
            let c = canonical(raw.text)
            if words[c] != nil {
                run.append(c)
                idx += 1
                if hasTrailingPunct(raw.text) { stopped = true }
            } else if let cardinal = ordinalToCardinal[c] {
                run.append(cardinal)
                isOrdinal = true
                idx += 1
                stopped = true
            } else {
                break
            }
        }
        guard !run.isEmpty else { return nil }

        var fractional = ""
        if !isOrdinal && !stopped && idx < tokens.count && canonical(tokens[idx].text) == "point" && !hasTrailingPunct(tokens[idx].text) {
            var j = idx + 1
            var digits = ""
            var digitStopped = false
            while j < tokens.count && !digitStopped {
                let raw = tokens[j]
                guard let (value, kind) = words[canonical(raw.text)], kind == .ones else { break }
                digits += String(value)
                j += 1
                if hasTrailingPunct(raw.text) { digitStopped = true }
            }
            if !digits.isEmpty {
                fractional = digits
                idx = j
                if digitStopped { stopped = true }
            }
        }

        var percent = false
        if !isOrdinal && !stopped && idx < tokens.count && canonical(tokens[idx].text) == "percent" {
            percent = true
            idx += 1
        }

        let hasDecorator = !sign.isEmpty || !fractional.isEmpty || percent
        guard let value = parse(run), hasDecorator || run.count >= 2 || value >= 10 else {
            return (idx - start, verbatim(tokens[start..<idx]))
        }

        var core = sign + "\(value)"
        if !fractional.isEmpty { core += "." + fractional }
        if isOrdinal { core += ordinalSuffix(value) }
        if percent { core += "%" }
        return (idx - start, leadingPunct(tokens[start].text) + core + trailingPunct(tokens[idx - 1].text))
    }

    private static func isNumberWord(_ canon: String) -> Bool {
        words[canon] != nil || ordinalToCardinal[canon] != nil
    }

    // STT commonly emits hyphenated compounds ("sixty-five", "twenty-first"). Split them into their
    // number-word parts so the run parser sees them, but ONLY when every hyphen-separated part is a
    // number/ordinal word — otherwise "well-known" / "state-of-the-art" would be corrupted.
    private static func splitHyphenatedNumber(_ token: String, source: Int) -> [Token] {
        guard token.contains("-") else {
            return [Token(text: token, source: source, original: token, isFirstPart: true, isLastPart: true)]
        }
        let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ isNumberWord(canonical($0)) }) else {
            return [Token(text: token, source: source, original: token, isFirstPart: true, isLastPart: true)]
        }
        return parts.enumerated().map { index, part in
            Token(
                text: part,
                source: source,
                original: token,
                isFirstPart: index == 0,
                isLastPart: index == parts.index(before: parts.endIndex))
        }
    }

    private static func verbatim(_ tokens: ArraySlice<Token>) -> String {
        var rendered: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            let sourceEnd = tokens[index...].firstIndex(where: { $0.source != token.source }) ?? tokens.endIndex
            if token.isFirstPart, tokens[sourceEnd - 1].isLastPart {
                rendered.append(token.original)
                index = sourceEnd
            } else {
                rendered.append(token.text)
                index += 1
            }
        }
        return rendered.joined(separator: " ")
    }

    private static func hasTrailingPunct(_ token: String) -> Bool {
        token.unicodeScalars.last.map(punctuation.contains) == true
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func canonical(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: punctuation)
    }

    private static func leadingPunct(_ token: String) -> String {
        String(token.prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) })
    }

    private static func trailingPunct(_ token: String) -> String {
        String(token.reversed().prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) }.reversed())
    }

    private static func parse(_ run: [String]) -> Int? {
        var result = 0
        var segment = 0
        var hasUnit = false          // a 1-19 already placed in this hundreds-block
        var hasTensOrUnit = false    // any 1-99 already placed in this hundreds-block
        var hasHundred = false
        var lastScale = Int.max

        for word in run {
            guard let (value, kind) = words[word] else { return nil }
            switch kind {
            case .ones:
                if hasUnit { return nil }
                segment += value; hasUnit = true; hasTensOrUnit = true
            case .teen:
                if hasTensOrUnit { return nil }
                segment += value; hasUnit = true; hasTensOrUnit = true
            case .tens:
                if hasTensOrUnit { return nil }
                segment += value; hasTensOrUnit = true
            case .hundred:
                if hasHundred || segment > 9 { return nil }
                segment = (segment == 0 ? 1 : segment) * 100
                hasHundred = true; hasUnit = false; hasTensOrUnit = false
            case .scale:
                if value >= lastScale { return nil }
                result += (segment == 0 ? 1 : segment) * value
                lastScale = value
                segment = 0; hasUnit = false; hasTensOrUnit = false; hasHundred = false
            }
        }
        return result + segment
    }
}

public struct NumbersStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.numbers
    public init() {}
    public func apply(_ context: inout PipelineContext) {
        // Between-sentinel runs only, so a token's index digit (⟦SN:VERB:1⟧) is never normalized.
        context.text = SentinelText.mappingOutsideSentinels(context.text) { InverseTextNormalizer.apply($0) }
    }
}
