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

    private func resolve(_ text: String, frozen: AgentRecipient.Frozen? = .init(id: "a", source: .focused), rows: [String] = ["a", "b", "c"]) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), frozen: frozen, rows: rows, names: names)
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

    @Test(arguments: ["a", "b", "c", nil] as [String?])
    func equallyStrongMatchesChooseTheAlphabeticallyFirstNameRegardlessOfTheCurrentRecipient(current: String?) {
        let names = ["web blue": "a", "api blue": "b", "backend": "c"]
        let address = AgentAddress.parse("Tell blue, fix it", names: ["web blue", "api blue", "backend"])
        let resolution = AgentRecipient.resolve(
            address, frozen: current.map { .init(id: $0, source: .current) },
            rows: ["a", "b", "c"], names: names)
        #expect(resolution == .deliver(id: "b", body: "fix it", source: .spoken))
        #expect(resolution.makesCurrent == "b")
    }

    @Test func alphabeticalTieBreakingDoesNotSkipAnUnavailableFirstMatch() {
        let address = AgentAddress.ambiguous(spoken: "blue", names: ["web blue", "api blue"], body: "fix it")
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a"], names: ["web blue": "a"])
            == .ask(body: "fix it", reason: .ambiguousName("blue", matches: ["web blue", "api blue"])))
    }

    @Test func anExactNameBeatsAnAlphabeticallyEarlierLooseMatch() {
        let names = ["alpha blue": "a", "blue": "b"]
        let address = AgentAddress.parse("Tell blue, fix it", names: Array(names.keys))
        #expect(AgentRecipient.resolve(address, frozen: nil, rows: ["a", "b"], names: names)
            == .deliver(id: "b", body: "fix it", source: .spoken))
    }

    @Test func anUntoldNearMissOfTheFrozenRecipientSendsTheWholeTake() {
        let address = AgentAddress.parse("Update the dependencies", names: ["updates"])
        let resolution = AgentRecipient.resolve(address, frozen: .init(id: "u", source: .current), rows: ["u"], names: ["updates": "u"])
        #expect(resolution == .deliver(id: "u", body: "Update the dependencies", source: .current))
    }

    @Test func aToldNearMissOfTheFrozenRecipientSendsTheMessage() {
        let address = AgentAddress.parse("Tell update to bump the dependencies", names: ["updates"])
        let resolution = AgentRecipient.resolve(address, frozen: .init(id: "u", source: .current), rows: ["u"], names: ["updates": "u"])
        #expect(resolution == .deliver(id: "u", body: "to bump the dependencies", source: .spoken))
    }

    @Test func aNameThatWasSaidIsNotReplacedByTheCurrentRecipientItSoundsLike() {
        #expect(resolve("Tell keyscribe glue the adapters together", frozen: .init(id: "b", source: .current))
            == .deliver(id: "a", body: "glue the adapters together", source: .spoken))
    }

    @Test func aNearMissOfAnotherConversationAsksAndSaysWhichItSoundedLike() {
        let address = AgentAddress.parse("Update the dependencies", names: ["updates", "backend"])
        let resolution = AgentRecipient.resolve(
            address, frozen: .init(id: "c", source: .current), rows: ["u", "c"], names: ["updates": "u", "backend": "c"])
        #expect(resolution == .ask(body: "the dependencies", reason: .soundsLike("update", name: "updates")))
    }

    @Test func anAddressWithoutAMessageSelectsWithoutSending() {
        let resolution = resolve("Tell backend.")
        #expect(resolution == .select(id: "c"))
        #expect(resolution.makesCurrent == "c")
    }

    @Test func openingAConversationMakesItCurrentWithoutSending() {
        let resolution = resolve("Open backend.")
        #expect(resolution == .open(id: "c"))
        #expect(resolution.makesCurrent == "c")
        #expect(resolve("Switch to session two", rows: ["c", "b", "a"]) == .open(id: "b"))
    }

    @Test func anOpenThatCannotResolveAsksAndSendsNothing() {
        #expect(resolve("Open session five") == .ask(body: "", reason: .noSuchRow(5)))
        #expect(resolve("Open session to") == .ask(body: "", reason: .unknownName("session to")))
        #expect(resolve("Open backand") == .ask(body: "", reason: .soundsLike("backand", name: "backend")))
    }

    @Test func anOpenThatSoundsLikeTheFrozenRecipientOpensIt() {
        #expect(resolve("Open backand", frozen: .init(id: "c", source: .current)) == .open(id: "c"))
    }

    @Test func anOpenVerbFollowedByAnInstructionIsAMessageForTheRecipient() {
        #expect(resolve("Open the readme.") == .deliver(id: "a", body: "Open the readme.", source: .focused))
    }

    @Test func openingANumberNoConversationHasAsksAndNeverPicksThatRow() {
        #expect(resolve("Open two.") == .ask(body: "", reason: .unknownName("two")))
        #expect(resolve("Tell two, run tests.") == .ask(body: "run tests.", reason: .unknownName("two")))
    }

    @Test func onlyAnExplicitAddressMovesTheCurrentRecipient() {
        #expect(resolve("Run the unit tests.").makesCurrent == nil)
        #expect(resolve("Tell backend, run the tests.").makesCurrent == "c")
    }
}
