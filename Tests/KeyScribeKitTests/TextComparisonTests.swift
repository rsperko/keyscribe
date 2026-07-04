import Testing
@testable import KeyScribeKit

struct TextComparisonTests {
    @Test func exactMatchIsUnchanged() {
        let comparison = TextComparison.compare("send the report", "send the report")

        #expect(comparison.hasMeaningfulDifference == false)
        #expect(comparison.left.map(\.kind) == [.unchanged])
        #expect(comparison.right.map(\.kind) == [.unchanged])
        #expect(comparison.left.map(\.text).joined() == "send the report")
        #expect(comparison.right.map(\.text).joined() == "send the report")
        #expect(comparison.summary == .identical)
    }

    @Test func caseAndPunctuationOnlyIsFormatting() {
        let comparison = TextComparison.compare("hello world", "Hello, world.")

        #expect(comparison.hasMeaningfulDifference == false)
        #expect(comparison.left.contains { $0.kind == .formatting })
        #expect(comparison.right.contains { $0.kind == .formatting })
        #expect(comparison.summary == .formattingOnly)
    }

    @Test func substitutedWordIsChangedOnBothSides() {
        let comparison = TextComparison.compare("send it to pat", "send it to Matt")

        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.left.map(\.kind).contains(.changed))
        #expect(comparison.right.map(\.kind).contains(.changed))
        #expect(comparison.left.filter { $0.kind == .changed }.map(\.text).joined() == "pat")
        #expect(comparison.right.filter { $0.kind == .changed }.map(\.text).joined() == "Matt")
        #expect(comparison.summary == .substitution(from: "pat", to: "Matt"))
    }

    @Test func missingWordIsRemovedFromLeft() {
        let comparison = TextComparison.compare("send the weekly report", "send the report")

        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.left.filter { $0.kind == .removed }.map(\.text).joined() == "weekly")
        #expect(comparison.right.contains { $0.kind == .removed } == false)
        #expect(comparison.summary == .counts(removed: 1, added: 0, changed: 0))
    }

    @Test func addedWordIsAddedOnRight() {
        let comparison = TextComparison.compare("send the report", "send the weekly report")

        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.right.filter { $0.kind == .added }.map(\.text).joined() == "weekly")
        #expect(comparison.left.contains { $0.kind == .added } == false)
        #expect(comparison.summary == .counts(removed: 0, added: 1, changed: 0))
    }

    @Test func repeatedWordsStayAligned() {
        let comparison = TextComparison.compare("that that works", "that works")

        #expect(comparison.left.filter { $0.kind == .removed }.map(\.text).joined() == "that")
        #expect(comparison.left.map(\.text).joined() == "that that works")
        #expect(comparison.right.map(\.text).joined() == "that works")
    }

    @Test func multilineTextKeepsReadableOutput() {
        let comparison = TextComparison.compare("first line\nsecond line", "first line\nthird line")

        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.left.map(\.text).joined() == "first line\nsecond line")
        #expect(comparison.right.map(\.text).joined() == "first line\nthird line")
        #expect(comparison.left.contains { $0.kind == .changed && $0.text == "second" })
        #expect(comparison.right.contains { $0.kind == .changed && $0.text == "third" })
    }

    @Test func bothEmptyHasNoSpansAndNoDifference() {
        let comparison = TextComparison.compare("", "")
        #expect(comparison.left.isEmpty)
        #expect(comparison.right.isEmpty)
        #expect(comparison.hasMeaningfulDifference == false)
    }

    @Test func emptyLeftMakesEverythingAddedOnRight() {
        let comparison = TextComparison.compare("", "hello there")
        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.left.isEmpty)
        #expect(comparison.right.contains { $0.kind == .added })
        #expect(comparison.right.allSatisfy { $0.kind == .added || $0.kind == .formatting })
    }

    @Test func emptyRightMakesEverythingRemovedFromLeft() {
        let comparison = TextComparison.compare("hello there", "")
        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.right.isEmpty)
        #expect(comparison.left.contains { $0.kind == .removed })
        #expect(comparison.left.allSatisfy { $0.kind == .removed || $0.kind == .formatting })
    }

    @Test func trailingWhitespaceOnlyIsNotMeaningful() {
        let comparison = TextComparison.compare("send the report", "send the report\n")
        #expect(comparison.left.map(\.text).joined() == "send the report")
        #expect(comparison.right.map(\.text).joined() == "send the report\n")
        #expect(comparison.hasMeaningfulDifference == false)
    }

    @Test func veryLongInputFallsBackToPlainSpansButStillReportsDifference() {
        let left = (0..<2200).map { "word\($0)" }.joined(separator: " ")
        let right = left + " extra"
        let comparison = TextComparison.compare(left, right)
        // Above the diff cap: one plain span per side, no per-word LCS, but the difference is still flagged.
        #expect(comparison.left.map(\.kind) == [.unchanged])
        #expect(comparison.right.map(\.kind) == [.unchanged])
        #expect(comparison.left.map(\.text).joined() == left)
        #expect(comparison.right.map(\.text).joined() == right)
        #expect(comparison.hasMeaningfulDifference)
        #expect(comparison.summary == .tooLongToCompare)
    }

    @Test func veryLongIdenticalInputReportsNoDifference() {
        let text = (0..<2200).map { "word\($0)" }.joined(separator: " ")
        let comparison = TextComparison.compare(text, text)
        #expect(comparison.left.map(\.kind) == [.unchanged])
        #expect(comparison.hasMeaningfulDifference == false)
        #expect(comparison.summary == .identical)
    }

    @Test func summaryCountsMultipleChangedWords() {
        #expect(TextComparison.compare("the big dog", "the small cat").summary
            == .counts(removed: 0, added: 0, changed: 2))
    }
}
