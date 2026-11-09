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
