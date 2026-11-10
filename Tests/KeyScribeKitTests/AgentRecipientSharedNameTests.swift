import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRecipientSharedNameTests {
    let names = ["cos claude": "a", "cos pi": "b", "backend": "c"]
    let shared = ["cos": AgentRecipient.SharedName(names: ["cos claude", "cos pi"])]

    private func resolve(_ text: String, frozen: AgentRecipient.Frozen? = .init(id: "c", source: .current)) -> AgentRecipient.Resolution {
        let address = AgentAddress.parse(text, names: AgentRecipient.spokenNames(names, shared: shared))
        return AgentRecipient.resolve(address, frozen: frozen, rows: ["a", "b", "c"], names: names, shared: shared)
    }

    private var asked: AgentRecipient.AskReason { .sharedName("cos", matches: ["cos claude", "cos pi"], tellApartIn: nil) }

    @Test(arguments: ["Tell cos to run the tests", "cos, run the tests", "Tell cos, run the tests", "Ask cos whether the tests pass"])
    func theBareNameOfAPlaceHoldingSeveralConversationsAsksAndNeverFallsThrough(text: String) {
        guard case .ask(_, let reason) = resolve(text) else {
            Issue.record("expected an ask for \(text)")
            return
        }
        #expect(reason == asked)
    }

    @Test func openingTheBareNameAsks() {
        #expect(resolve("Open cos") == .ask(body: "", reason: asked))
    }

    @Test func theQualifiedNameStillReachesItsConversation() {
        #expect(resolve("cos claude, run the tests") == .deliver(id: "a", body: "run the tests", source: .spoken))
        #expect(resolve("Tell cos pi to run the tests") == .deliver(id: "b", body: "to run the tests", source: .spoken))
    }

    @Test func aMessageWithoutAnAddressStillGoesToTheRecipient() {
        #expect(resolve("Run the unit tests.") == .deliver(id: "c", body: "Run the unit tests.", source: .current))
    }

    @Test func aSharedNameThatTheQualifierCouldNotSeparateSaysHowToTellThemApart() {
        let shared = ["cos": AgentRecipient.SharedName(names: ["cos claude", "cos claude blue"], tellApartIn: "herdr")]
        let names = ["cos claude": "a", "cos claude blue": "b"]
        let address = AgentAddress.parse("Tell cos to run the tests", names: AgentRecipient.spokenNames(names, shared: shared))
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names, shared: shared)
            == .ask(body: "to run the tests", reason: .sharedName("cos", matches: ["cos claude", "cos claude blue"], tellApartIn: "herdr")))
    }

    @Test func anOrdinaryTieBetweenNamesStillTakesTheFirstAlphabetically() {
        let names = ["web blue": "a", "api blue": "b"]
        let address = AgentAddress.parse("Tell blue, fix it", names: AgentRecipient.spokenNames(names, shared: shared))
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names, shared: shared)
            == .deliver(id: "b", body: "fix it", source: .spoken))
    }
}

struct AgentRecipientLateNameTests {
    @Test func aNameLearnedDuringRecordingAddressesTheSameConversationAlongsideItsFrozenName() {
        let merged = AgentRecipient.addingLate(
            ["architect": "a", "keyscribe blue": "b"], sharing: [:], to: ["keyscribe": "a", "keyscribe blue": "b"], sharing: [:])
        #expect(merged.names == ["keyscribe": "a", "architect": "a", "keyscribe blue": "b"])
    }

    @Test func aLateNameNeverAddsAConversationOrTakesAFrozenName() {
        let merged = AgentRecipient.addingLate(
            ["keyscribe": "b", "newcomer": "c"], sharing: [:], to: ["keyscribe": "a", "keyscribe blue": "b"], sharing: [:])
        #expect(merged.names == ["keyscribe": "a", "keyscribe blue": "b"])
    }

    @Test func aLateSharedNameJoinsOnlyWhenEveryMemberIsAddressable() {
        let shared = AgentRecipient.SharedName(names: ["cos claude", "cos pi"])
        let kept = AgentRecipient.addingLate(
            ["cos claude": "a", "cos pi": "b"], sharing: ["cos": shared], to: ["home": "a", "home blue": "b"], sharing: [:])
        #expect(kept.shared == ["cos": shared])
        let dropped = AgentRecipient.addingLate(
            ["cos claude": "a", "cos pi": "c"], sharing: ["cos": shared], to: ["home": "a", "home blue": "b"], sharing: [:])
        #expect(dropped.shared.isEmpty)
    }

    @Test func aSharedNameLeftWithOneConversationReachesIt() {
        let names = ["cos claude": "a"]
        let shared = ["cos": AgentRecipient.SharedName(names: ["cos claude"])]
        let address = AgentAddress.parse("cos, run the tests", names: AgentRecipient.spokenNames(names, shared: shared))
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a"], names: names, shared: shared)
            == .deliver(id: "a", body: "run the tests", source: .spoken))
    }

    @Test func aStatusQuestionAboutASharedNameAsks() throws {
        let names = ["cos claude": "a", "cos pi": "b"]
        let shared = ["cos": AgentRecipient.SharedName(names: ["cos claude", "cos pi"])]
        let query = try #require(AgentStatusQuery.parse("what is cos waiting for", names: AgentRecipient.spokenNames(names, shared: shared)))
        guard case .waiting(let address?) = query else {
            Issue.record("expected a waiting question, got \(query)")
            return
        }
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names, shared: shared)
            == .ask(body: "", reason: .sharedName("cos", matches: ["cos claude", "cos pi"], tellApartIn: nil)))
    }
}

struct AgentRecipientOtherNameTests {
    let names = ["marvin": "a", "builder": "b", "api": "c"]
    let shared: [String: AgentRecipient.SharedName] = [
        "cos": .init(names: ["marvin"], kind: .also("herdr agent name")),
        "refactor auth": .init(names: ["builder"], kind: .afterVerb("herdr pane title")),
        "api reviewer": .init(names: ["builder"], kind: .afterVerb("herdr pane title")),
        "chief": .init(names: ["marvin"], kind: .held("herdr workspace label")),
        "pair": .init(names: ["builder", "marvin"], kind: .also("herdr agent name")),
    ]

    private func resolve(_ text: String) -> AgentRecipient.Resolution {
        let address = AgentAddress.parse(
            text, names: AgentRecipient.spokenNames(names, shared: shared), afterVerb: AgentRecipient.afterVerbNames(shared))
        return AgentRecipient.resolve(address, frozen: .init(id: "c", source: .current), rows: ["a", "b", "c"], names: names, shared: shared)
    }

    @Test(arguments: [
        ("Ask cos what's outstanding", "a", "what's outstanding"),
        ("cos, run the tests", "a", "run the tests"),
        ("Ask refactor auth to review it", "b", "to review it"),
        ("Please tell refactor auth, run the tests", "b", "run the tests"),
        ("Ask api reviewer to look at it", "b", "to look at it"),
    ])
    func anotherNameReachesItsConversation(text: String, id: String, body: String) {
        #expect(resolve(text) == .deliver(id: id, body: body, source: .spoken))
    }

    @Test func openingATitleOpensItsConversation() {
        #expect(resolve("Open refactor auth") == .open(id: "b"))
    }

    @Test(arguments: ["Refactor auth, then run the tests", "ask questions if anything is unclear", "ask again if it fails"])
    func aTitleSaidWithoutTellAskOrOpenIsJustTheMessage(text: String) {
        #expect(resolve(text) == .deliver(id: "c", body: text, source: .current))
    }

    @Test(arguments: [("tell chief, run the tests", "run the tests"), ("Ask chief what we should do next", "what we should do next")])
    func aLabelThatLostTheNameHoldsAndNamesTheConversation(text: String, body: String) {
        #expect(resolve(text) == .ask(body: body, reason: .shownOn("chief", name: "marvin", as: "herdr workspace label")))
    }

    @Test func anotherNameTwoConversationsShareAsks() {
        #expect(resolve("Ask pair to review it")
            == .ask(body: "to review it", reason: .sharedName("pair", matches: ["builder", "marvin"], tellApartIn: nil)))
    }

    @Test func titlesAndHeldLabelsAreNotSpokenBare() {
        #expect(AgentRecipient.spokenNames(names, shared: shared).sorted() == ["api", "builder", "cos", "marvin", "pair"])
        #expect(AgentRecipient.afterVerbNames(shared) == ["api reviewer", "chief", "refactor auth"])
    }

    @Test func aTitleShownDuringRecordingCountsOnlyForAConversationTheTakeFroze() {
        let late: [String: AgentRecipient.SharedName] = [
            "zed": .init(names: ["marvin"], kind: .afterVerb("herdr pane title")),
            "zork": .init(names: ["newcomer"], kind: .afterVerb("herdr pane title")),
        ]
        let merged = AgentRecipient.addingLate(["marvin": "a", "newcomer": "d"], sharing: late, to: names, sharing: [:])
        #expect(AgentRecipient.afterVerbNames(merged.shared) == ["zed"])
    }
}

struct AgentRecipientUncertainNameTests {
    let names = ["marvin": "a", "builder": "b"]
    let shared: [String: AgentRecipient.SharedName] = [
        "clean up panes and close stale sessions": .init(names: ["marvin"], kind: .afterVerb("agent\u{2019}s own name")),
        "review auth": .init(names: ["builder"], kind: .afterVerb("herdr pane title")),
        "review billing": .init(names: ["marvin"], kind: .afterVerb("herdr pane title")),
    ]

    private func resolve(_ text: String) -> AgentRecipient.Resolution {
        let address = AgentAddress.parse(
            text, names: AgentRecipient.spokenNames(names, shared: shared), afterVerb: AgentRecipient.afterVerbNames(shared))
        return AgentRecipient.resolve(address, frozen: .init(id: "b", source: .current), rows: ["a", "b"], names: names, shared: shared)
    }

    @Test func anOrdinaryInstructionThatStartsLikeAnUncertainNameIsTheMessage() {
        let text = "Clean up panes in this repository"
        #expect(resolve(text) == .deliver(id: "b", body: text, source: .current))
    }

    @Test func anUncertainNameSaidInFullAfterAVerbReachesItsConversation() {
        #expect(resolve("Ask clean up panes and close stale sessions what is left")
            == .deliver(id: "a", body: "what is left", source: .spoken))
    }

    @Test(arguments: [
        "Ask clean up panes what is left",
        "Ask review to check the changes",
        "ask questions if anything is unclear",
        "Ask the user whether to keep the schema.",
    ])
    func anAfterVerbNameMatchesOnlyInFullSoEverydayInstructionsStayMessages(text: String) {
        var shared = shared
        shared["questions about auth"] = .init(names: ["builder"], kind: .afterVerb("herdr pane title"))
        shared["user onboarding flow"] = .init(names: ["marvin"], kind: .afterVerb("herdr pane title"))
        let address = AgentAddress.parse(
            text, names: AgentRecipient.spokenNames(names, shared: shared), afterVerb: AgentRecipient.afterVerbNames(shared))
        #expect(AgentRecipient.resolve(address, frozen: .init(id: "b", source: .current), rows: ["a", "b"], names: names, shared: shared)
            == .deliver(id: "b", body: text, source: .current))
    }

    @Test func aStatusQuestionReachesAConversationByAnAfterVerbName() throws {
        let query = try #require(AgentStatusQuery.parse(
            "what is review auth waiting for", names: AgentRecipient.spokenNames(names, shared: shared),
            afterVerb: AgentRecipient.afterVerbNames(shared)))
        guard case .waiting(let address?) = query else {
            Issue.record("expected a waiting question, got \(query)")
            return
        }
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names, shared: shared) == .select(id: "b"))
    }
}

struct AgentRecipientAfterVerbSpanTests {
    @Test func anAfterVerbNameCountsOnlyWhereTheAddressIsNotLaterInTheMessage() {
        let names = ["api": "a", "builder": "b"]
        let shared: [String: AgentRecipient.SharedName] = ["refactor auth": .init(names: ["builder"], kind: .afterVerb("herdr pane title"))]
        let address = AgentAddress.parse(
            "Tell refactor to explain refactor auth", names: AgentRecipient.spokenNames(names, shared: shared),
            afterVerb: AgentRecipient.afterVerbNames(shared))
        let resolution = AgentRecipient.resolve(address, frozen: .init(id: "a", source: .current), rows: ["a", "b"], names: names, shared: shared)
        #expect(resolution != .deliver(id: "b", body: "to explain refactor auth", source: .spoken))
        guard case .ask = resolution else {
            Issue.record("expected a hold, got \(resolution)")
            return
        }
    }

    @Test func aMessageAndAStatusQuestionPickTheSameConversationForTheSameName() throws {
        let names = ["auth reviewer": "a", "builder": "b"]
        let shared: [String: AgentRecipient.SharedName] = ["reviewer": .init(names: ["builder"], kind: .afterVerb("herdr pane title"))]
        let spoken = AgentRecipient.spokenNames(names, shared: shared), afterVerb = AgentRecipient.afterVerbNames(shared)
        let message = AgentAddress.parse("Ask reviewer to check it", names: spoken, afterVerb: afterVerb)
        #expect(AgentRecipient.resolve(message, frozen: nil, rows: ["a", "b"], names: names, shared: shared)
            == .deliver(id: "b", body: "to check it", source: .spoken))
        let query = try #require(AgentStatusQuery.parse("Ask reviewer what it is waiting for", names: spoken, afterVerb: afterVerb))
        guard case .waiting(let address?) = query else {
            Issue.record("expected a waiting question, got \(query)")
            return
        }
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names, shared: shared) == .select(id: "b"))
    }
}
