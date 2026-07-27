import Testing
@testable import KeyScribeKit

private func extract(_ text: String, excluding: [String] = [], limit: Int = 32) -> [String] {
    ScreenTermExtractor.terms(in: text, excluding: excluding, limit: limit)
}

struct ScreenTermExtractorTests {
    @Test func extractsCamelAndPascalCaseIdentifiers() {
        #expect(extract("call useState inside the CaptureWriter loop") == ["useState", "CaptureWriter"])
    }

    @Test func extractsSnakeCaseIdentifiers() {
        #expect(extract("the finish_draining hook runs last") == ["finish_draining"])
    }

    @Test func extractsScreamingSnakeIdentifiers() {
        #expect(extract("set MAX_RETRY_COUNT before starting") == ["MAX_RETRY_COUNT"])
    }

    @Test func extractsLetterDigitMixes() {
        #expect(extract("the utf8 decoder reads v3Config") == ["utf8", "v3Config"])
    }

    // Prose words — lowercase, Capitalized, or ALLCAPS without digits/underscores/case transitions —
    // are ordinary language, not identifiers visible on screen worth snapping to.
    @Test func ignoresProseIncludingCapitalizedAndAllCapsWords() {
        #expect(extract("The Quick Brown Fox NOTE these TODO items").isEmpty)
    }

    @Test func splitsDottedNamesIntoComponents() {
        #expect(extract("read config.retryCount and session.maxDepth") == ["retryCount", "maxDepth"])
    }

    @Test func dropsIdentifiersBelowTheNormalizedFloor() {
        #expect(extract("bind x1 and a_b then go").isEmpty)
    }

    @Test func dedupesByNormalizedFormKeepingFirstAppearance() {
        #expect(extract("CaptureWriter feeds captureWriter again") == ["CaptureWriter"])
    }

    @Test func excludesTermsAlreadyInTheDictionaryByNormalizedForm() {
        #expect(extract("call useState now", excluding: ["UseState"]).isEmpty)
    }

    @Test func capsAtTheLimitInFirstAppearanceOrder() {
        let text = (0..<40).map { "identFier\($0)" }.joined(separator: " ")
        let result = extract(text)
        #expect(result.count == 32)
        #expect(result.first == "identFier0")
        #expect(result.last == "identFier31")
    }

    @Test func emptyTextYieldsNoTerms() {
        #expect(extract("").isEmpty)
        #expect(extract("   \n\t  ").isEmpty)
    }

    @Test func stripsSurroundingPunctuationBeforeClassifying() {
        #expect(extract("(useState), \"CaptureWriter\";") == ["useState", "CaptureWriter"])
    }

    // Screen text is code: identifiers arrive glued into expressions, not whitespace-separated.
    @Test func splitsCodeExpressionsOnNonIdentifierCharacters() {
        #expect(extract("let value = useState(initialCount)") == ["useState", "initialCount"])
        #expect(extract("retryCount+maxDepth;") == ["retryCount", "maxDepth"])
    }
}
