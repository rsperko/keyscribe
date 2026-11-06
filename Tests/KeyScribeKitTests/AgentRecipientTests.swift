import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRecipientTests {
    let names = ["keyscribe": "a", "keyscribe blue": "b", "backend": "c"]

    private func initial(_ target: Mode.Agent.Target, focused: String? = nil, current: String? = nil) -> AgentRecipient.Frozen? {
        AgentRecipient.initial(target: target, focused: focused, current: current, names: names)
    }

    @Test func theFocusedAgentWinsOverTheCurrentRecipient() {
        #expect(initial(.focused, focused: "b", current: "c") == .init(id: "b", source: .focused))
    }

    @Test func withoutAFocusedAgentTheCurrentRecipientApplies() {
        #expect(initial(.focused, current: "c") == .init(id: "c", source: .current))
    }

    @Test func aCurrentTargetIgnoresFocus() {
        #expect(initial(.current, focused: "b", current: "c") == .init(id: "c", source: .current))
    }

    @Test func aFixedTargetUsesItsNameWhateverIsFocused() {
        #expect(initial(.handle("Backend"), focused: "b", current: "a") == .init(id: "c", source: .fixed))
        #expect(initial(.handle("frontend"), focused: "b") == nil)
    }

    @Test func askAndNothingKnownLeaveNoRecipient() {
        #expect(initial(.ask, focused: "b", current: "c") == nil)
        #expect(initial(.focused) == nil)
    }

    private func resolve(_ text: String, frozen: AgentRecipient.Frozen? = .init(id: "a", source: .focused), rows: [String] = ["a", "b", "c"], reply: String? = nil) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), frozen: frozen, rows: rows, names: names, replyTo: reply)
    }

    @Test func anUnaddressedMessageGoesToTheFrozenRecipient() {
        #expect(resolve("Run the unit tests.") == .deliver(id: "a", body: "Run the unit tests.", source: .focused))
    }

    @Test func anUnaddressedMessageWithNoRecipientAsks() {
        #expect(resolve("Run the unit tests.", frozen: nil) == .ask(body: "Run the unit tests.", reason: .noRecipient))
    }

    @Test func aSpokenNameOverridesTheFrozenRecipientAndBecomesCurrent() {
        let resolution = resolve("Tell backend to run the tests.")
        #expect(resolution == .deliver(id: "c", body: "to run the tests.", source: .spoken))
        #expect(resolution.makesCurrent == "c")
    }

    @Test func aRowNumberResolvesAgainstTheFrozenList() {
        #expect(resolve("Tell session two, check the migration.", rows: ["c", "b", "a"]) == .deliver(id: "b", body: "check the migration.", source: .spoken))
    }

    @Test func aRowOutsideTheListAsksAndKeepsTheMessage() {
        #expect(resolve("Tell session five to run the build.") == .ask(body: "to run the build.", reason: .noSuchRow(5)))
    }

    @Test func anUnresolvedAddressNeverFallsBackToTheFrozenRecipient() {
        #expect(resolve("Tell frontend to run the tests.") == .ask(body: "to run the tests.", reason: .unknownName("frontend")))
        #expect(resolve("Tell session to run the tests") == .ask(body: "run the tests", reason: .unknownName("session to")))
    }

    @Test func anAddressWithoutAMessageSelectsWithoutSending() {
        let resolution = resolve("Tell backend.")
        #expect(resolution == .select(id: "c"))
        #expect(resolution.makesCurrent == "c")
    }

    @Test func replyGoesToTheNoticesConversationOnlyWhileThereIsOne() {
        #expect(resolve("Reply, use approach B.", reply: "b") == .deliver(id: "b", body: "use approach B.", source: .reply))
        #expect(resolve("Reply, use approach B.") == .ask(body: "use approach B.", reason: .noReply))
    }

    @Test func onlyAnExplicitAddressMovesTheCurrentRecipient() {
        #expect(resolve("Run the unit tests.").makesCurrent == nil)
        #expect(resolve("Reply, use approach B.", reply: "b").makesCurrent == "b")
    }
}
