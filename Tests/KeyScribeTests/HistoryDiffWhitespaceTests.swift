import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct HistoryDiffWhitespaceTests {
    @Test func changedWhitespaceUsesVisibleGlyphsButSelectionReturnsOriginalText() {
        let spans = [
            TextComparison.Span(id: 0, text: "alpha", kind: .unchanged),
            TextComparison.Span(id: 1, text: "\n\t beta", kind: .formatting),
        ]

        let rendered = DiffTextPresentation.render(spans: spans)

        #expect(rendered.attributed.string == "alpha↵\n⇥·beta")
        #expect(rendered.originalText(for: NSRange(location: 5, length: 4)) == "\n\t ")
    }

    @Test func unchangedWhitespaceStaysQuiet() {
        let spans = [
            TextComparison.Span(id: 0, text: "alpha\nbeta", kind: .unchanged),
        ]

        let rendered = DiffTextPresentation.render(spans: spans)

        #expect(rendered.attributed.string == "alpha\nbeta")
        #expect(rendered.originalText(for: NSRange(location: 5, length: 1)) == "\n")
    }

    // A bare "\n" from an "insert new line" command used to render as an invisible blank line.
    @Test func addedNewlineBecomesVisibleButSelectionYieldsRawNewline() {
        let spans = [
            TextComparison.Span(id: 0, text: "hello", kind: .unchanged),
            TextComparison.Span(id: 1, text: "\n", kind: .added),
            TextComparison.Span(id: 2, text: "world", kind: .unchanged),
        ]

        let rendered = DiffTextPresentation.render(spans: spans)

        #expect(rendered.attributed.string == "hello↵\nworld")
        #expect(rendered.originalText(for: NSRange(location: 5, length: 2)) == "\n")
    }

    @Test func carriageReturnAndNbspReveal() {
        let spans = [
            TextComparison.Span(id: 0, text: "\r\u{00A0}", kind: .changed),
        ]

        let rendered = DiffTextPresentation.render(spans: spans)

        #expect(rendered.attributed.string == "\u{240D}\u{237D}")
        #expect(rendered.originalText(for: NSRange(location: 0, length: 2)) == "\r\u{00A0}")
    }

    @Test func crlfRevealKeepsSelectionAsRawCrlf() {
        let spans = [
            TextComparison.Span(id: 0, text: "\r\n", kind: .changed),
        ]

        let rendered = DiffTextPresentation.render(spans: spans)

        #expect(rendered.attributed.string == "\u{240D}↵\n")
        #expect(rendered.originalText(for: NSRange(location: 0, length: 3)) == "\r\n")
    }

    @Test func emptySpansRenderPlaceholderAndSelectNothing() {
        let rendered = DiffTextPresentation.render(spans: [])

        #expect(rendered.attributed.string == "(empty)")
        #expect(rendered.originalText(for: NSRange(location: 0, length: 7)) == "")
    }
}
