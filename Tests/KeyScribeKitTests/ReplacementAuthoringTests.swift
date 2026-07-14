import Testing
@testable import KeyScribeKit

struct ReplacementAuthoringTests {
    @Test func previewPassesShortSingleLineThrough() {
        #expect(ReplacementAuthoring.preview(for: "Hello").text == "Hello")
    }

    @Test func previewEscapesNewline() {
        #expect(ReplacementAuthoring.preview(for: "Hello\nworld").text == #"Hello\nworld"#)
        #expect(ReplacementAuthoring.preview(for: "\n").text == #"\n"#)
    }

    @Test func previewEscapesTabAndCarriageReturn() {
        #expect(ReplacementAuthoring.preview(for: "a\tb").text == #"a\tb"#)
        #expect(ReplacementAuthoring.preview(for: "a\rb").text == #"a\rb"#)
    }

    @Test func previewEscapesCRLFAsBothControls() {
        #expect(ReplacementAuthoring.preview(for: "a\r\nb").text == #"a\r\nb"#)
    }

    @Test func previewEmptyReadsNothing() {
        let preview = ReplacementAuthoring.preview(for: "")
        #expect(preview.text == "Nothing")
        #expect(preview.isTruncated == false)
        #expect(preview.fullCount == 0)
    }

    @Test func previewNeverExceedsLimitAndAnnouncesTruncation() {
        let body = String(repeating: "a", count: 500)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.text.hasSuffix("…"))
        #expect(String(preview.text.dropLast()) == String(repeating: "a", count: ReplacementAuthoring.previewLimit - 1))
        #expect(preview.isTruncated)
        #expect(preview.fullCount == 500)
    }

    @Test func previewCapAppliesToEscapedLength() {
        let body = String(repeating: "\n", count: 100)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.isTruncated)
        #expect(preview.fullCount == 100)
    }

    @Test func previewExactlyAtLimitIsNotTruncated() {
        let body = String(repeating: "a", count: ReplacementAuthoring.previewLimit)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.isTruncated == false)
    }

    @Test func limitConstantMatchesDesign() {
        #expect(ReplacementAuthoring.maxCharacters == 65_536)
        #expect(ReplacementAuthoring.previewLimit == 160)
    }

    @Test func exactlyAtLimitIsWithinLimit() {
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "a", count: 65_536)))
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "a", count: 65_537)) == false)
    }

    @Test func limitCountsUserPerceivedCharacters() {
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "🇺🇸", count: 65_536)))
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "🇺🇸", count: 65_537)) == false)
    }

    @Test func regexReturnMarkerValidWhenTerminalOrAbsent() {
        #expect(ReplacementAuthoring.regexReturnMarkerValid("/resume<CR>"))
        #expect(ReplacementAuthoring.regexReturnMarkerValid("just text"))
        #expect(ReplacementAuthoring.regexReturnMarkerValid(#"a\<CR>b"#))
    }

    @Test func regexReturnMarkerInvalidWhenNonTerminal() {
        #expect(ReplacementAuthoring.regexReturnMarkerValid("mid<CR>text") == false)
    }

    @Test func lineEndingsNormalizeToLF() {
        #expect(ReplacementAuthoring.normalizingLineEndings("a\r\nb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\rb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\nb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }
}
