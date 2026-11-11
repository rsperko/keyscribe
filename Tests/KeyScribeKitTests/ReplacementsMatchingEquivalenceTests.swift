import Foundation
import Testing
@testable import KeyScribeKit

struct ReplacementsMatchingEquivalenceTests {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let words = [
        "the", "cat", "category", "dog", "do", "doing", "pipe", "pipeline", "ticket", "12", "345", "a", "aa",
        "teh", "/resume", "c++", "café", "cafe\u{301}", "👍🏽", "🇺🇸", "naïve", "e.g.", "12:30", "Kryten", "pain",
        "pains", "\n", "\t", ",", ".", "?", "-", "_x_", "über", "ok", "OK", "go", "back",
    ]

    private static let rules: [ReplacementRule] = [
        ReplacementRule(heard: "cat", replace: "Cat", isRegex: false),
        ReplacementRule(heard: "the cat", replace: "THE CAT", isRegex: false),
        ReplacementRule(heard: "category", replace: "kind", isRegex: false),
        ReplacementRule(heard: "pipe", replace: "|", isRegex: false),
        ReplacementRule(heard: "/resume", replace: "RESUME", isRegex: false),
        ReplacementRule(heard: "c++", replace: "C plus plus", isRegex: false),
        ReplacementRule(heard: "teh", replace: "the", isRegex: false),
        ReplacementRule(heard: "the", replace: "teh", isRegex: false),
        ReplacementRule(heard: "go back", replace: "/back", isRegex: false, wholeDictation: true),
        ReplacementRule(heard: "pain", replace: "pane", isRegex: false),
        ReplacementRule(heard: "café", replace: "coffee", isRegex: false),
        ReplacementRule(heard: "ok", replace: "OK", isRegex: false),
        ReplacementRule(heard: #"ticket (\d+)"#, replace: "T-$1", isRegex: true),
        ReplacementRule(heard: #"\bdo\w*"#, replace: "DO", isRegex: true),
        ReplacementRule(heard: "a+", replace: "A", isRegex: true),
        ReplacementRule(heard: "x*", replace: "X", isRegex: true),
        ReplacementRule(heard: #"(?<=the )cat"#, replace: "kitty", isRegex: true),
        ReplacementRule(heard: "cat|category", replace: "C", isRegex: true),
        ReplacementRule(heard: #"(\w+) dog"#, replace: "dog of $1", isRegex: true),
        ReplacementRule(heard: #"\p{Mn}"#, replace: "~", isRegex: true),
        ReplacementRule(heard: "\u{1F3FD}", replace: "skin", isRegex: true),
        ReplacementRule(heard: #"\s+"#, replace: " ", isRegex: true),
        ReplacementRule(heard: "o(?=g)", replace: "0", isRegex: true),
        ReplacementRule(heard: #"[aeiou]{2}"#, replace: "VV", isRegex: true),
        ReplacementRule(heard: "e", replace: "E", isRegex: true),
        ReplacementRule(heard: #"\d+"#, replace: "#", isRegex: true),
        ReplacementRule(heard: #"^the"#, replace: "START", isRegex: true),
        ReplacementRule(heard: #"\.$"#, replace: "!", isRegex: true),
        ReplacementRule(heard: "pain", replace: "agony", isRegex: false),
        ReplacementRule(heard: "line", replace: "LINE", isRegex: true),
        ReplacementRule(heard: #"\Gcat"#, replace: "G-CAT", isRegex: true),
    ]

    private static func referenceTransform(_ text: String, rules: [ReplacementRule]) -> (String, [ReplacementEffect]) {
        struct Prepared { let source: ReplacementRule; let regex: NSRegularExpression; let template: String; let submit: Mode.Submit? }
        let prepared: [Prepared] = rules.compactMap { rule in
            guard case .ready(let regex, let template, let submit) = ReplacementsStage.prepare(rule), !rule.wholeDictation
            else { return nil }
            return Prepared(source: rule, regex: regex, template: template, submit: submit)
        }
        var effects: [ReplacementEffect] = []
        let out = SentinelText.mappingOutsideSentinels(text) { run in
            var result = ""
            var cursor = run.startIndex
            while cursor < run.endIndex {
                let searchRange = NSRange(cursor..<run.endIndex, in: run)
                var winner: (Prepared, NSTextCheckingResult, Range<String.Index>)?
                for rule in prepared {
                    guard let match = rule.regex.firstMatch(
                        in: run, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds], range: searchRange),
                          match.range.length > 0, let range = Range(match.range, in: run)
                    else { continue }
                    if winner == nil || match.range.length > winner!.1.range.length { winner = (rule, match, range) }
                }
                if let (rule, match, range) = winner {
                    let output = rule.regex.replacementString(for: match, in: run, offset: 0, template: rule.template)
                    let changed = output != run[range]
                    let insideWord = changed && ReplacementsStage.landsInsideWord(range, in: run)
                    let effect = ReplacementEffect(
                        rule: rule.source, changedWords: changed && !insideWord, insideWord: insideWord,
                        returnOmitted: rule.submit != nil, ownsWholeDictation: false)
                    if let i = effects.firstIndex(where: { $0.rule == effect.rule }) {
                        effects[i].changedWords = effects[i].changedWords || effect.changedWords
                        effects[i].insideWord = effects[i].insideWord || effect.insideWord
                    } else {
                        effects.append(effect)
                    }
                    result += output
                    cursor = range.upperBound
                } else {
                    let next = run.index(after: cursor)
                    result.append(contentsOf: run[cursor..<next])
                    cursor = next
                }
            }
            return SentinelText.neutralizeOpen(result)
        }
        return (out, effects)
    }

    @Test func theStageMatchesTheOneRuleAtATimeScanOnRandomRulesAndText() {
        var generator = SeededGenerator(state: 20_261_111)
        for _ in 0..<3_000 {
            let rules = (0..<Int.random(in: 1...10, using: &generator)).map { _ in Self.rules.randomElement(using: &generator)! }
            let separators = [" ", " ", " ", "", ", "]
            var text = ""
            for _ in 0..<Int.random(in: 1...30, using: &generator) {
                text += Self.words.randomElement(using: &generator)! + separators.randomElement(using: &generator)!
            }
            if Bool.random(using: &generator) { text += "⟦SN:VERB:1⟧ the cat" }
            var context = PipelineContext(text: text)
            ReplacementsStage(rules: rules).apply(&context)
            let (expected, effects) = Self.referenceTransform(text, rules: rules)
            #expect(context.text == expected, "rules \(rules.map(\.heard)) on \(text.debugDescription)")
            if context.bareReplacement == nil {
                #expect(context.replacementEffects == effects, "rules \(rules.map(\.heard)) on \(text.debugDescription)")
            }
        }
    }
}
