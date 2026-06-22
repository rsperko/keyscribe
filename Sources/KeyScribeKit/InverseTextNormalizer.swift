import Foundation

// Deterministic spoken-number → digits normalization (e.g. "twenty five" → "25"). Opt-in per mode
// (commands.numbers) and conservative by design: a run that does not form a single unambiguous
// cardinal is left exactly as spoken. That bail is what preserves year idioms like "twenty twenty
// six" or "nineteen ninety five" (two tens/teens with no scale word between them) instead of
// mangling them into a wrong cardinal. Wrong number output is worse than none, so the parser
// refuses anything it cannot reconstruct exactly.
public enum InverseTextNormalizer {
    private enum Kind { case ones, teen, tens, hundred, scale }

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

    public static func apply(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var run: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if let value = parse(run.map { canonical($0) }), run.count >= 2 || value >= 10 {
                out.append(leadingPunct(run.first!) + "\(value)" + trailingPunct(run.last!))
            } else {
                out.append(contentsOf: run)
            }
            run.removeAll()
        }

        for token in tokens {
            if !token.isEmpty, words[canonical(token)] != nil {
                run.append(token)
                if token.unicodeScalars.last.map(punctuation.contains) == true { flushRun() }
            } else {
                flushRun()
                out.append(token)
            }
        }
        flushRun()
        return out.joined(separator: " ")
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
    public func run(_ context: inout PipelineContext) {
        context.text = InverseTextNormalizer.apply(context.text)
    }
}
