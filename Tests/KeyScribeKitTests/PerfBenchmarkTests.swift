import Foundation
import Testing
@testable import KeyScribeKit

// A deterministic scaling benchmark beats a live Instruments trace here: the token path is a
// sub-millisecond blip inside the multi-hundred-ms STT+LLM dictation, so a live trace can't reveal
// the O(tokens × length) scaling that is the actual concern.
//   RUN_PERF_BENCH=1 swift test --filter perfBenchmark
struct PerfBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_PERF_BENCH"] != nil))
    func perfBenchmark() {
        print("\n=== Perf benchmark — profiling-gated cleanups ===")
        tokenPath()
        regexCacheInvalid()
        dateFormatter()
        localTextStages()
        print("=== end ===\n")
    }

    private func localTextStages() {
        print("\n[#5] Local text stages per dictation (replacements, near match, verbatim)")
        print(pad("words", 8) + padL("rules", 7) + padL("terms", 7) + padL("replace", 11) + padL("fuzzy", 11)
            + padL("verbatim", 11) + padL("hints", 11))
        let cases: [(Int, Int, Int)] = [(150, 30, 50), (150, 500, 500), (800, 500, 500), (3_000, 500, 500)]
        for (words, ruleCount, termCount) in cases {
            let text = prose(words: words)
            let stage = ReplacementsStage(rules: benchmarkRules(ruleCount))
            let fuzzy = FuzzyStage(terms: benchmarkTerms(termCount))
            let config = ResolvedConfig(
                modes: [], dictionary: DictionarySet(words: benchmarkTerms(termCount)), replacements: ReplacementsSet(),
                connections: ConnectionSet(), fragments: [:])
            let reps = words <= 150 ? 50 : 5
            var replaceMs = 0.0, fuzzyMs = 0.0, verbatimMs = 0.0, hintsMs = 0.0
            for _ in 0..<reps {
                var context = PipelineContext(text: text)
                replaceMs += time { stage.apply(&context) }
                fuzzyMs += time { fuzzy.apply(&context) }
                verbatimMs += time { _ = VerbatimTokenizer.apply(text, into: Tokenizer()) }
                hintsMs += time { _ = config.dictionaryWordsPresent(in: text, for: nil) }
            }
            print(pad("\(words)", 8) + padL("\(ruleCount)", 7) + padL("\(termCount)", 7)
                + padL(us(replaceMs / Double(reps)), 11) + padL(us(fuzzyMs / Double(reps)), 11)
                + padL(us(verbatimMs / Double(reps)), 11) + padL(us(hintsMs / Double(reps)), 11))
        }
        print("  (a 60 s take is about 150 words; shared vocabularies push rule counts into the hundreds)")
    }

    private func prose(words: Int) -> String {
        let sentence = "So the deploy to Kubernetes failed again, and the Postgress replica on krytenpost lagged by ten seconds while flu dio waited."
        let vocabulary = sentence.split(separator: " ")
        return (0..<words).map { String(vocabulary[$0 % vocabulary.count]) }.joined(separator: " ")
    }

    private func benchmarkRules(_ count: Int) -> [ReplacementRule] {
        (0..<count).map { i in
            i % 10 == 0
                ? ReplacementRule(heard: #"\bticket (\d+)\#(i)\b"#, replace: "T-$1", isRegex: true)
                : ReplacementRule(heard: "phrase\(i) word", replace: "Phrase\(i)", isRegex: false)
        }
    }

    private func benchmarkTerms(_ count: Int) -> [String] {
        let syllables = ["kry", "ten", "post", "gres", "flu", "id", "au", "dio", "ku", "ber", "net", "zo", "mar", "lin", "dex", "tra"]
        return (0..<count).map { i in
            [i, i / 16, i / 256 + 3].map { syllables[$0 % syllables.count] }.joined().capitalized
        }
    }

    // Only edit-in-place over a large selection with many tokens could hit O(tokens × text-length)
    // cost; spoken dictation is short with few tokens.
    private func tokenPath() {
        print("\n[#2] Token path (RedactionTokenizer.apply + ValidationGate.check + Tokenizer.restore)")
        print(pad("chars", 9) + padL("tokens", 8) + padL("apply", 11) + padL("gate", 11)
            + padL("restore", 11) + padL("total", 11))
        let cases: [(Int, Int)] = [(200, 1), (2_000, 5), (10_000, 20), (50_000, 100), (50_000, 500)]
        for (chars, tokenCount) in cases {
            let text = synthText(chars: chars, emails: tokenCount)
            let reps = chars <= 2_000 ? 2_000 : (chars <= 10_000 ? 500 : 20)

            var applyMs = 0.0, gateMs = 0.0, restoreMs = 0.0
            var issued: [String] = []
            var tokenized = "", restored = ""
            for _ in 0..<reps {
                let tok = Tokenizer()
                applyMs += time { tokenized = RedactionTokenizer.apply(text, into: tok) }
                issued = tok.issuedTokens
                gateMs += time { _ = ValidationGate.check(output: tokenized, issuedTokens: issued) }
                restoreMs += time { restored = tok.restore(tokenized) }
            }
            #expect(restored == text)
            print(pad("\(chars)", 9) + padL("\(issued.count)", 8)
                + padL(us(applyMs / Double(reps)), 11) + padL(us(gateMs / Double(reps)), 11)
                + padL(us(restoreMs / Double(reps)), 11)
                + padL(us((applyMs + gateMs + restoreMs) / Double(reps)), 11))
        }
        print("  (realistic spoken dictation ≈ first row; edit-in-place a large selection ≈ rows 3-4)")
    }

    // Regression check: RegexCache memoizes BOTH valid and invalid patterns, so both figures below
    // should be cache-hit cheap.
    private func regexCacheInvalid() {
        print("\n[#3] RegexCache — valid vs invalid (both memoized; regression check)")
        let reps = 50_000
        let validMs = time { for _ in 0..<reps { _ = RegexCache.regex(#"\bfoo\b"#) } }
        let invalidMs = time { for _ in 0..<reps { _ = RegexCache.regex("(unterminated[") } }
        print("  valid (cache hit):   " + us(validMs / Double(reps)) + " /call")
        print("  invalid (cache hit): " + us(invalidMs / Double(reps)) + " /call")
        print("  a persistently-invalid rule is parsed once, not per dictation.")
    }

    // Regression check: HistoryStore.todayString uses a shared static DateFormatter, so its per-call
    // cost should match a hand-reused formatter rather than a fresh allocation.
    private func dateFormatter() {
        print("\n[#4] HistoryStore.todayString — shared formatter vs hand-reused (regression check)")
        let reps = 50_000
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedMs = time { for _ in 0..<reps { _ = HistoryStore.todayString(date: date) } }
        let reused = DateFormatter()
        reused.locale = Locale(identifier: "en_US_POSIX")
        reused.dateFormat = "yyyy-MM-dd"
        let reusedMs = time { for _ in 0..<reps { _ = reused.string(from: date) } }
        print("  shared formatter: " + us(sharedMs / Double(reps)) + " /call (current)")
        print("  reused formatter: " + us(reusedMs / Double(reps)) + " /call")
        print("  called once per dictation append.")
    }

    private func synthText(chars: Int, emails: Int) -> String {
        let filler = "The quick brown fox jumps over the lazy dog and writes some prose. "
        var s = ""
        while s.count < chars { s += filler }
        s = String(s.prefix(chars))
        guard emails > 0 else { return s }
        var chunks: [String] = []
        let step = max(1, s.count / emails)
        var idx = s.startIndex
        var n = 0
        while n < emails, idx < s.endIndex {
            let end = s.index(idx, offsetBy: step, limitedBy: s.endIndex) ?? s.endIndex
            chunks.append(String(s[idx..<end]) + " user\(n)@example.com ")
            idx = end
            n += 1
        }
        return chunks.joined()
    }

    private func time(_ body: () -> Void) -> Double {
        let t0 = Date()
        body()
        return Date().timeIntervalSince(t0) * 1000
    }

    private func us(_ ms: Double) -> String {
        ms >= 1 ? String(format: "%.2fms", ms) : String(format: "%.1fµs", ms * 1000)
    }

    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    private func padL(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }
}
