import Testing
@testable import KeyScribeKit

struct ModelFilterTests {
    private let models = [
        "google/gemini-1.5-pro",
        "google/gemini-1.5-flash",
        "openai/gpt-4o",
        "googlevertex:google:google-gemini-flash-lite-preview",
    ]

    @Test func emptyQueryReturnsFullListInOrder() {
        #expect(ModelFilter.filter(models, query: "") == models)
    }

    @Test func whitespaceOnlyQueryReturnsFullList() {
        #expect(ModelFilter.filter(models, query: "   ") == models)
    }

    @Test func matchesMidStringSubstring() {
        #expect(ModelFilter.filter(models, query: "gemini") == [
            "google/gemini-1.5-pro",
            "google/gemini-1.5-flash",
            "googlevertex:google:google-gemini-flash-lite-preview",
        ])
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(ModelFilter.filter(models, query: "GPT") == ["openai/gpt-4o"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(ModelFilter.filter(models, query: "claude").isEmpty)
    }

    @Test func queryIsTrimmedBeforeMatching() {
        #expect(ModelFilter.filter(models, query: "  gpt-4o  ") == ["openai/gpt-4o"])
    }
}
