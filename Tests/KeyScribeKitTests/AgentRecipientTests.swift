import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRecipientTests {
    let names = ["keyscribe": "a", "keyscribe blue": "b", "backend": "c"]

    private func initial(_ target: Mode.Agent.Target, current: String? = nil) -> AgentRecipient.Frozen? {
        AgentRecipient.initial(target: target, current: current, names: names)
    }

    @Test func aCurrentTargetUsesTheCurrentRecipient() {
        #expect(initial(.current, current: "c") == .init(id: "c", source: .current))
    }

    @Test(arguments: ["Run the unit tests.", "Keyscrib run the tests", "Open keyscrib"])
    func anAddressThatFallsBackToTheRecipientUsesTheDefault(text: String) {
        #expect(AgentRecipient.usesDefault(AgentAddress.parse(text, names: Array(names.keys))))
    }

    @Test(arguments: ["Tell backend to run the tests.", "Session 2 run the tests.", "Tell frontend to run the tests.", "Open backend"])
    func anAddressThatNamesItsRecipientDoesNotUseTheDefault(text: String) {
        #expect(!AgentRecipient.usesDefault(AgentAddress.parse(text, names: Array(names.keys))))
    }

    @Test func aMessageToTheConversationInFrontMakesItCurrent() {
        let resolution = resolve("Run the unit tests.", frozen: .init(id: "b", source: .front))
        #expect(resolution == .deliver(id: "b", body: "Run the unit tests.", source: .front))
        #expect(resolution.makesCurrent == "b")
    }

    @Test func aMessageToTheCurrentOrFixedConversationLeavesCurrentAlone() {
        #expect(resolve("Run the unit tests.").makesCurrent == nil)
        #expect(resolve("Run the unit tests.", frozen: .init(id: "c", source: .fixed)).makesCurrent == nil)
    }

    @Test func aFixedTargetUsesItsName() {
        #expect(initial(.handle("Backend"), current: "a") == .init(id: "c", source: .fixed))
        #expect(initial(.handle("frontend")) == nil)
    }

    @Test func askAndNothingKnownLeaveNoRecipient() {
        #expect(initial(.ask, current: "c") == nil)
        #expect(initial(.current) == nil)
    }

    private func resolve(_ text: String, frozen: AgentRecipient.Frozen? = .init(id: "a", source: .current), rows: [String] = ["a", "b", "c"]) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), frozen: frozen, rows: rows, names: names)
    }

    @Test func anUnaddressedMessageGoesToTheFrozenRecipient() {
        #expect(resolve("Run the unit tests.") == .deliver(id: "a", body: "Run the unit tests.", source: .current))
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

    @Test func anAddressWithoutAMessageHoldsWithoutSending() {
        let resolution = resolve("Tell backend.")
        #expect(resolution == .ask(body: "", reason: .sayToSelect("backend")))
        #expect(resolution.makesCurrent == nil)
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

    @Test func aShortOpenThatNamesNoConversationIsHeldAndNamesWhatItSoundedLike() {
        let held = AgentRecipient.Resolution.ask(body: "", reason: .soundsLike("key scrub", name: "keyscribe"))
        #expect(resolve("Go to key scrub") == held)
        #expect(resolve("Go to key scrub", frozen: .init(id: "a", source: .current)) == held)
        #expect(resolve("Go to key scrub", frozen: .init(id: "c", source: .current)) == held)
        #expect(resolve("Open the readme.") == .ask(body: "", reason: .unknownName("readme")))
        #expect(resolve("Open the pull request") == .ask(body: "", reason: .unknownName("pull request")))
    }

    @Test func anOpenVerbFollowedByALongerInstructionOrAPronounIsAMessageForTheRecipient() {
        let long = "Open the settings page and fix the toggle"
        #expect(resolve(long) == .deliver(id: "a", body: long, source: .current))
        #expect(resolve("Open it.") == .deliver(id: "a", body: "Open it.", source: .current))
    }

    @Test func aHeldOpenIsClassifiedTheSameWhateverConversationsExist() {
        for names in [["backend": "c"], ["backend": "c", "coding agent build": "d"]] {
            func resolve(_ text: String) -> AgentRecipient.Resolution {
                AgentRecipient.resolve(
                    AgentAddress.parse(text, names: Array(names.keys)), frozen: .init(id: "c", source: .current), rows: ["c"], names: names)
            }
            #expect(resolve("Go to key scrub") == .ask(body: "", reason: .unknownName("key scrub")))
            let long = "Open the settings page and fix the toggle"
            #expect(resolve(long) == .deliver(id: "c", body: long, source: .current))
        }
    }

    @Test func equallyCloseSuggestionsAreOfferedTogetherAndACloserOneAlone() {
        let names = ["keyscribe": "a", "keyscrabe": "b", "backend": "c"]
        func resolve(_ text: String) -> AgentRecipient.Resolution {
            AgentRecipient.resolve(
                AgentAddress.parse(text, names: Array(names.keys)), frozen: .init(id: "a", source: .current), rows: ["a", "b", "c"], names: names)
        }
        #expect(resolve("Go to key scrub") == .ask(body: "", reason: .ambiguousName("key scrub", matches: ["keyscrabe", "keyscribe"])))
        #expect(resolve("Go to back and") == .ask(body: "", reason: .soundsLike("back and", name: "backend")))
    }

    @Test func aMatchedLongNameAfterAnOpenVerbStillOpens() {
        let names = ["coding agent build": "d", "backend": "c"]
        let resolution = AgentRecipient.resolve(
            AgentAddress.parse("Go to coding agent build", names: Array(names.keys)), frozen: nil, rows: ["c", "d"], names: names)
        #expect(resolution == .open(id: "d"))
    }

    @Test func sessionAfterAnOpenVerbIsAlwaysANameHoweverLong() {
        #expect(resolve("Open session key scrub") == .ask(body: "", reason: .soundsLike("key scrub", name: "keyscribe")))
        #expect(resolve("Go to session zebra") == .ask(body: "", reason: .unknownName("zebra")))
        #expect(resolve("Open session the big long name") == .ask(body: "", reason: .unknownName("the big long name")))
        #expect(resolve("Go to session backend review") == .ask(body: "", reason: .unknownName("backend review")))
    }

    @Test func openingANumberNoConversationHasAsksAndNeverPicksThatRow() {
        #expect(resolve("Open two.") == .ask(body: "", reason: .unknownName("two")))
        #expect(resolve("Tell two, run tests.") == .ask(body: "run tests.", reason: .unknownName("two")))
    }

    @Test func onlyAnExplicitAddressMovesTheCurrentRecipient() {
        #expect(resolve("Run the unit tests.").makesCurrent == nil)
        #expect(resolve("Tell backend, run the tests.").makesCurrent == "c")
    }

    @Test func anAddressWithoutABreakAfterTheIsHeldUnlessItIsAlreadyTheRecipient() {
        let said = "tell the backend run the tests"
        let address = AgentAddress.unbroken(.name("backend", body: "run the tests"), unaddressed: said)
        #expect(AgentRecipient.resolve(address, frozen: .init(id: "a", source: .current), rows: ["a", "b", "c"], names: names)
            == .ask(body: said, reason: .noBreak("backend")))
        #expect(AgentRecipient.resolve(address, frozen: .init(id: "c", source: .current), rows: ["a", "b", "c"], names: names)
            == .deliver(id: "c", body: said, source: .current))
        let row = AgentAddress.unbroken(.row(2, body: "run the tests"), unaddressed: said)
        #expect(AgentRecipient.resolve(row, frozen: .init(id: "a", source: .current), rows: ["a", "b", "c"], names: names)
            == .ask(body: said, reason: .noBreak("conversation 2")))
        #expect(AgentRecipient.resolve(row, frozen: nil, rows: ["a"], names: names) == .ask(body: said, reason: .noSuchRow(2)))
        #expect(AgentRecipient.usesDefault(address))
    }
}
