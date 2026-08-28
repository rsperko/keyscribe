import Foundation
import Testing
@testable import KeyScribeKit

// Guards the committed eval corpus against channel rot (evals/rewrite/README.md "authoring gotcha"):
// a term-recall case whose screen term can never reach the prompt — FuzzyCorrector pairs 2-token
// windows only on an exact normalized split and fuzzes single tokens only — measures nothing. Cases
// documenting that limit on purpose opt out by carrying "unpairable" in their id.
struct RewriteEvalCorpusTests {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KeyScribeKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("evals/rewrite/cases.json")

    @Test func committedCorpusDecodes() throws {
        let manifest = try RewriteEvalManifest.load(from: Self.corpusURL)
        #expect(manifest.cases.count >= 20)
    }

    @Test func recallCasesAreDeliverableByTheScreenTermsChannel() throws {
        let manifest = try RewriteEvalManifest.load(from: Self.corpusURL)
        for c in manifest.cases where c.tags.contains("term-recall") && !c.id.contains("unpairable") {
            let built = try #require(RewriteEvalVariants.build(c, variant: "screen-terms"))
            let delivered = built.inputs.validTerms + built.inputs.fuzzyCandidates.map(\.canonical)
            let screenSet = Set(c.screenTerms)
            for expected in c.checks.mustContain where screenSet.contains(expected) {
                #expect(delivered.contains(expected),
                        "\(c.id): screen term \(expected) never reaches the prompt — see the corpus README gotcha")
            }
        }
    }

    @Test func everyCheckedRegexCompiles() throws {
        let manifest = try RewriteEvalManifest.load(from: Self.corpusURL)
        for c in manifest.cases {
            for pattern in c.checks.regexAbsent {
                #expect(RegexCache.regex(pattern) != nil, "\(c.id): bad regex \(pattern)")
            }
        }
    }

    // BenchmarkScoring.tokens maps every non-alphanumeric scalar to a space and splits — but CJK
    // ideographs and kana ARE alphanumeric, so a space-free Japanese sentence collapses to ONE token
    // and WER degenerates to 0-or-1. A CJK case carrying maxWer measures nothing; use mustContain /
    // regexAbsent there instead (evals/rewrite/README.md).
    @Test func cjkCasesDoNotRelyOnWordErrorRate() throws {
        let manifest = try RewriteEvalManifest.load(from: Self.corpusURL)
        for c in manifest.cases where Self.containsCJK(c.transcript) {
            #expect(c.checks.maxWer == nil,
                    "\(c.id): maxWer is meaningless for CJK — BenchmarkScoring.tokens sees one token")
        }
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // hiragana + katakana
                || (0x4E00...0x9FFF).contains(scalar.value)   // CJK unified ideographs
        }
    }
}
