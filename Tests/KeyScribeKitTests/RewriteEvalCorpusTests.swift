import Foundation
import Testing
@testable import KeyScribeKit

// Guards the committed eval corpus against channel rot (evals/rewrite/README.md "authoring gotcha"):
// a term-recall case whose screen term can never reach the prompt measures nothing. Two documented
// limits opt out via the id: "unpairable" (FuzzyCorrector pairs 2-token windows only on an exact
// normalized split and fuzzes single tokens only) and "unharvestable" (ScreenTermExtractor rejects
// prose-shaped words — a plain capitalized surname or brand never enters the screen channel; such
// terms belong to the user's Dictionary).
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
        for c in manifest.cases where c.tags.contains("term-recall")
            && !c.id.contains("unpairable") && !c.id.contains("unharvestable") {
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
}
