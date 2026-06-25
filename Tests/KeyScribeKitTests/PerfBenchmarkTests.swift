import Foundation
import Testing
@testable import KeyScribeKit

// Opt-in micro-benchmark for the four profiling-gated perf concerns from the 2026-06-20 GPT review
// (see docs/session-status.md "profiling-gated perf cleanups"). It isolates each hot-path function
// and measures it at realistic vs stress sizes so the simplicity-vs-speed call is data-driven rather
// than guessed. A deterministic scaling benchmark beats a live Instruments trace here: the token
// path is a sub-millisecond blip inside the multi-hundred-ms STT+LLM dictation, so a live trace
// can't reveal the O(tokens × length) scaling that is the actual concern.
//   RUN_PERF_BENCH=1 swift test --filter perfBenchmark
struct PerfBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_PERF_BENCH"] != nil))
    func perfBenchmark() {
        print("\n=== Perf benchmark — profiling-gated cleanups ===")
        tokenPath()
        regexCacheInvalid()
        dateFormatter()
        print("=== end ===\n")
    }

    // #2 — token processing: O(tokens × text-length)? Only edit-in-place over a large selection with
    // many tokens could bite; spoken dictation is short with few tokens. Measure apply/gate/restore
    // across the realistic → stress range.
    private func tokenPath() {
        print("\n[#2] Token path (RedactionTokenizer.apply + ValidationGate.check + Tokenizer.restore)")
        print(pad("chars", 9) + padL("tokens", 8) + padL("apply", 11) + padL("gate", 11)
            + padL("restore", 11) + padL("total", 11))
        // (text length, redaction-matchable span count). Last row is an unrealistic stress case.
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

    // #3 — Regression check (already fixed): RegexCache memoizes BOTH valid and invalid patterns, so a
    // persistently-invalid rule is parsed once, not per call. Both figures below should be cache-hit cheap.
    private func regexCacheInvalid() {
        print("\n[#3] RegexCache — valid vs invalid (both memoized; regression check)")
        let reps = 50_000
        let validMs = time { for _ in 0..<reps { _ = RegexCache.regex(#"\bfoo\b"#) } }
        let invalidMs = time { for _ in 0..<reps { _ = RegexCache.regex("(unterminated[") } }
        print("  valid (cache hit):   " + us(validMs / Double(reps)) + " /call")
        print("  invalid (cache hit): " + us(invalidMs / Double(reps)) + " /call")
        print("  a persistently-invalid rule is parsed once, not per dictation.")
    }

    // #4 — Regression check (already fixed): HistoryStore.todayString uses a shared static DateFormatter,
    // so the per-call cost should match a hand-reused formatter rather than a fresh allocation.
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

    // MARK: - helpers

    private func synthText(chars: Int, emails: Int) -> String {
        let filler = "The quick brown fox jumps over the lazy dog and writes some prose. "
        var s = ""
        while s.count < chars { s += filler }
        s = String(s.prefix(chars))
        guard emails > 0 else { return s }
        // Spread distinct emails evenly so apply() allocates `emails` distinct tokens.
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
