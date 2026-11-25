import Foundation
import KeyScribeKit
import Testing

struct SpokenEvalTests {
    static let failing = SpokenEvalCase(
        id: "ci", asked: "note that the old setup had testing instructions", reply: "…",
        mentions: [#"\bCI\b|lint"#, #"fail"#], avoids: [#"testing instructions"#])

    @Test func aSummaryThatSaysTheFailureAndNoRequestOrNumberPasses() {
        #expect(SpokenEval.failures(of: "One test passed, but required CI fails on the linters.", for: Self.failing).isEmpty)
    }

    @Test(arguments: [
        ("One test passed and another could not run locally.", ["missed"]),
        ("CI passes on lint.", ["missed"]),
        ("CI fails on lint. You noted the old setup had testing instructions.", ["said"]),
        ("CI fails on lint in pull request 1234567.", ["number"]),
        ("CI fails on lint in #12.", ["number"]),
        ("", ["empty"]),
    ])
    func eachWayASummaryFallsShortIsNamed(summary: String, failures: [String]) {
        #expect(SpokenEval.failures(of: summary, for: Self.failing) == failures)
    }

    @Test func aSummaryOfTheOppositeOutcomeFailsTheShippedCases() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../evals/spoken/cases.json")
        let cases = Dictionary(uniqueKeysWithValues: try SpokenEval.cases(from: Data(contentsOf: url)).map { ($0.id, $0) })
        let opposite = [
            "ci-failure-in-a-late-bullet-after-an-instruction": "CI passes and the refactor is done.",
            "a-failed-migration-among-many-successes": "The migration completed successfully on staging.",
            "a-failed-job-in-a-status-report-full-of-pull-request-numbers": "All the analysis jobs finished.",
            "work-that-could-not-be-verified": "The resize crash is fixed and the tests pass.",
            "a-decision-the-agent-waits-on-in-the-middle": "All fourteen endpoints now use the new client.",
            "a-request-repeated-back-instead-of-the-result": "The flag works and the docs mention it.",
            "nothing-failed": "The logging update failed its tests.",
        ]
        let alsoOpposite = [
            ("ci-failure-in-a-late-bullet-after-an-instruction", "Required CI passes."),
            ("work-that-could-not-be-verified", "The fix is verified."),
        ]
        #expect(Set(opposite.keys) == Set(cases.keys))
        for (id, summary) in Array(opposite) + alsoOpposite {
            #expect(!SpokenEval.failures(of: summary, for: try #require(cases[id])).isEmpty, "\(id): \(summary)")
        }
    }

    @Test func aPatternThatIsNotARegularExpressionIsRefusedWhenTheCasesAreRead() {
        let json = #"{"cases":[{"id":"a","reply":"r","mentions":["(unclosed"]}]}"#
        #expect(throws: SpokenEval.BadPattern.self) { try SpokenEval.cases(from: Data(json.utf8)) }
    }

    @Test func casesAreReadFromTheirFile() throws {
        let json = #"{"cases":[{"id":"a","reply":"r","mentions":["x"]},{"id":"b","asked":"q","reply":"r","mentions":["y"],"avoids":["q"]}]}"#
        let cases = try SpokenEval.cases(from: Data(json.utf8))
        #expect(cases == [
            SpokenEvalCase(id: "a", asked: nil, reply: "r", mentions: ["x"], avoids: []),
            SpokenEvalCase(id: "b", asked: "q", reply: "r", mentions: ["y"], avoids: ["q"]),
        ])
    }
}
