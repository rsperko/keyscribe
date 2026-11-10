import Testing
@testable import KeyScribeKit

struct AgentNameFormsTests {
    let names = ["reviews manager queue", "backend"]

    @Test(arguments: [
        "Ask review manager what is next to review",
        "Ask reviews manager what is next to review",
        "Ask the review manager what is next to review",
        "Ask review manager queue what is next to review",
    ])
    func aSingularOrPluralWordStillReachesTheName(_ said: String) {
        #expect(AgentAddress.parse(said, names: names) == .name("reviews manager queue", body: "what is next to review"))
    }

    @Test func aNameIsTheSameNameInTheSingularOrThePlural() {
        #expect(AgentHandles.matchKey("reviews_manager_queue") == AgentHandles.matchKey("review manager queue"))
        #expect(AgentHandles.matchKey("open queries") == AgentHandles.matchKey("open query"))
        #expect(AgentHandles.matchKey("tax boxes") == AgentHandles.matchKey("tax box"))
        #expect(AgentHandles.matchKey("pull branches") == AgentHandles.matchKey("pull branch"))
    }

    @Test func wordsThatOnlyLookPluralKeepTheirS() {
        for word in ["status", "glass", "analysis", "bus", "v2s"] {
            #expect(AgentHandles.singular(word) == word)
        }
    }

    @Test func withoutAnAddressVerbASingularNameIsAskedAboutNotSent() {
        let said = "Review manager queue is next"
        guard case .nearMiss(_, "reviews manager queue", _, said) = AgentAddress.parse(said, names: names) else {
            Issue.record("expected a near miss that asks")
            return
        }
    }

    @Test func aStatusQuestionReachesTheNameInTheSingularToo() throws {
        let query = try #require(AgentStatusQuery.parse("what is review manager waiting for", names: names))
        #expect(query == .waiting(.name("reviews manager queue", body: "")))
    }
}
