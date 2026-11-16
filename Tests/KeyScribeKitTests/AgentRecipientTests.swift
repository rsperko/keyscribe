import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRecipientTests {
    let names = ["keyscribe": "a", "keyscribe blue": "b", "backend": "c"]

    @Test(arguments: ["Run the unit tests.", "Keyscrib run the tests", "Open keyscrib"])
    func anAddressWithoutANameUsesTheConversationInFront(text: String) {
        #expect(AgentRecipient.usesFocus(AgentAddress.parse(text, names: Array(names.keys))))
    }

    @Test(arguments: ["Tell backend to run the tests.", "Session 2 run the tests.", "Tell frontend to run the tests.", "Open backend"])
    func anAddressThatNamesAConversationIgnoresTheOneInFront(text: String) {
        #expect(!AgentRecipient.usesFocus(AgentAddress.parse(text, names: Array(names.keys))))
    }

    @Test func anUnnamedMessageGoesToTheConversationInFront() {
        let resolution = resolve("Run the unit tests.", focused: "b")
        #expect(resolution == .deliver(id: "b", body: "Run the unit tests.", source: .front))
    }

    private func resolve(_ text: String, focused: String? = "a", rows: [String] = ["a", "b", "c"]) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), focused: focused, rows: rows, names: names)
    }

    @Test func anUnaddressedMessageGoesToTheFocusedConversation() {
        #expect(resolve("Run the unit tests.") == .deliver(id: "a", body: "Run the unit tests.", source: .front))
    }

    @Test func anUnaddressedMessageWithNothingFocusedSendsNothing() {
        #expect(resolve("Run the unit tests.", focused: nil) == .ask(body: "Run the unit tests.", reason: .nothingFocused))
    }

    @Test func aSpokenNameOverridesTheFocusedConversation() {
        let resolution = resolve("Tell backend to run the tests.")
        #expect(resolution == .deliver(id: "c", body: "to run the tests.", source: .spoken))
    }

    @Test func aRowNumberResolvesAgainstTheListFrozenAtTheStart() {
        #expect(resolve("Tell session two, check the migration.", rows: ["c", "b", "a"]) == .deliver(id: "b", body: "check the migration.", source: .spoken))
    }

    @Test func aRowOutsideTheListAsksAndKeepsTheMessage() {
        #expect(resolve("Tell session five to run the build.") == .ask(body: "to run the build.", reason: .noSuchRow(5)))
    }

    @Test func anUnresolvedAddressNeverFallsBackToTheFocusedConversation() {
        #expect(resolve("Tell frontend to run the tests.") == .ask(body: "to run the tests.", reason: .unknownName("frontend")))
        #expect(resolve("Tell session to run the tests") == .ask(body: "run the tests", reason: .unknownName("session to")))
    }

    @Test(arguments: ["a", "b", "c", nil] as [String?])
    func equallyStrongMatchesChooseTheAlphabeticallyFirstNameRegardlessOfFocus(current: String?) {
        let names = ["web blue": "a", "api blue": "b", "backend": "c"]
        let address = AgentAddress.parse("Tell blue, fix it", names: ["web blue", "api blue", "backend"])
        let resolution = AgentRecipient.resolve(
            address, focused: current,
            rows: ["a", "b", "c"], names: names)
        #expect(resolution == .deliver(id: "b", body: "fix it", source: .spoken))
    }

    @Test func alphabeticalTieBreakingDoesNotSkipAnUnavailableFirstMatch() {
        let address = AgentAddress.ambiguous(spoken: "blue", names: ["web blue", "api blue"], body: "fix it")
        #expect(AgentRecipient.resolve(address, focused: nil, rows: ["a"], names: ["web blue": "a"])
            == .ask(body: "fix it", reason: .ambiguousName("blue", matches: ["web blue", "api blue"])))
    }

    @Test func anExactNameBeatsAnAlphabeticallyEarlierLooseMatch() {
        let names = ["alpha blue": "a", "blue": "b"]
        let address = AgentAddress.parse("Tell blue, fix it", names: Array(names.keys))
        #expect(AgentRecipient.resolve(address, focused: nil, rows: ["a", "b"], names: names)
            == .deliver(id: "b", body: "fix it", source: .spoken))
    }

    @Test func anUntoldNearMissOfTheFocusedConversationSendsTheWholeTake() {
        let address = AgentAddress.parse("Update the dependencies", names: ["updates"])
        let resolution = AgentRecipient.resolve(address, focused: "u", rows: ["u"], names: ["updates": "u"])
        #expect(resolution == .deliver(id: "u", body: "Update the dependencies", source: .front))
    }

    @Test func aToldNearMissOfTheFocusedConversationSendsTheMessage() {
        let address = AgentAddress.parse("Tell update to bump the dependencies", names: ["updates"])
        let resolution = AgentRecipient.resolve(address, focused: "u", rows: ["u"], names: ["updates": "u"])
        #expect(resolution == .deliver(id: "u", body: "to bump the dependencies", source: .spoken))
    }

    @Test func aNameThatWasSaidIsNotReplacedByTheFocusedConversationItSoundsLike() {
        #expect(resolve("Tell keyscribe glue the adapters together", focused: "b")
            == .deliver(id: "a", body: "glue the adapters together", source: .spoken))
    }

    @Test func aNearMissOfAnotherConversationAsksAndSaysWhichItSoundedLike() {
        let address = AgentAddress.parse("Update the dependencies", names: ["updates", "backend"])
        let resolution = AgentRecipient.resolve(
            address, focused: "c", rows: ["u", "c"], names: ["updates": "u", "backend": "c"])
        #expect(resolution == .ask(body: "the dependencies", reason: .soundsLike("update", name: "updates")))
    }

    @Test func anAddressWithoutAMessageHoldsWithoutSending() {
        let resolution = resolve("Tell backend.")
        #expect(resolution == .ask(body: "", reason: .nameOnly("backend")))
    }

    @Test func openingAConversationSendsNothing() {
        let resolution = resolve("Open backend.")
        #expect(resolution == .open(id: "c"))
        #expect(resolve("Switch to session two", rows: ["c", "b", "a"]) == .open(id: "b"))
    }

    @Test func anOpenThatCannotResolveAsksAndSendsNothing() {
        #expect(resolve("Open session five") == .ask(body: "", reason: .noSuchRow(5)))
        #expect(resolve("Open session to") == .ask(body: "", reason: .unknownName("session to")))
        #expect(resolve("Open backand") == .ask(body: "", reason: .soundsLike("backand", name: "backend")))
    }

    @Test func anOpenThatSoundsLikeTheFocusedConversationOpensIt() {
        #expect(resolve("Open backand", focused: "c") == .open(id: "c"))
    }

    @Test func aShortOpenThatNamesNoConversationIsHeldAndNamesWhatItSoundedLike() {
        let held = AgentRecipient.Resolution.ask(body: "", reason: .soundsLike("key scrub", name: "keyscribe"))
        #expect(resolve("Go to key scrub") == held)
        #expect(resolve("Go to key scrub", focused: "a") == held)
        #expect(resolve("Go to key scrub", focused: "c") == held)
        #expect(resolve("Open the readme.") == .ask(body: "", reason: .unknownName("readme")))
        #expect(resolve("Open the pull request") == .ask(body: "", reason: .unknownName("pull request")))
    }

    @Test func anOpenVerbFollowedByALongerInstructionOrAPronounIsAMessageForTheFocusedConversation() {
        let long = "Open the settings page and fix the toggle"
        #expect(resolve(long) == .deliver(id: "a", body: long, source: .front))
        #expect(resolve("Open it.") == .deliver(id: "a", body: "Open it.", source: .front))
    }

    @Test func aHeldOpenIsClassifiedTheSameWhateverConversationsExist() {
        for names in [["backend": "c"], ["backend": "c", "agent build": "d"]] {
            func resolve(_ text: String) -> AgentRecipient.Resolution {
                AgentRecipient.resolve(
                    AgentAddress.parse(text, names: Array(names.keys)), focused: "c", rows: ["c"], names: names)
            }
            #expect(resolve("Go to key scrub") == .ask(body: "", reason: .unknownName("key scrub")))
            let long = "Open the settings page and fix the toggle"
            #expect(resolve(long) == .deliver(id: "c", body: long, source: .front))
        }
    }

    @Test func equallyCloseSuggestionsAreOfferedTogetherAndACloserOneAlone() {
        let names = ["keyscribe": "a", "keyscrabe": "b", "backend": "c"]
        func resolve(_ text: String) -> AgentRecipient.Resolution {
            AgentRecipient.resolve(
                AgentAddress.parse(text, names: Array(names.keys)), focused: "a", rows: ["a", "b", "c"], names: names)
        }
        #expect(resolve("Go to key scrub") == .ask(body: "", reason: .ambiguousName("key scrub", matches: ["keyscrabe", "keyscribe"])))
        #expect(resolve("Go to back and") == .ask(body: "", reason: .soundsLike("back and", name: "backend")))
    }

    @Test func aMatchedLongNameAfterAnOpenVerbStillOpens() {
        let names = ["agent build": "d", "backend": "c"]
        let resolution = AgentRecipient.resolve(
            AgentAddress.parse("Go to agent build", names: Array(names.keys)), focused: nil, rows: ["c", "d"], names: names)
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

    @Test func anAddressWithoutABreakAfterTheIsHeldUnlessItIsTheFocusedConversation() {
        let said = "tell the backend run the tests"
        let address = AgentAddress.unbroken(.name("backend", body: "run the tests"), unaddressed: said)
        #expect(AgentRecipient.resolve(address, focused: "a", rows: ["a", "b", "c"], names: names)
            == .ask(body: said, reason: .noBreak("backend")))
        #expect(AgentRecipient.resolve(address, focused: "c", rows: ["a", "b", "c"], names: names)
            == .deliver(id: "c", body: said, source: .front))
        let row = AgentAddress.unbroken(.row(2, body: "run the tests"), unaddressed: said)
        #expect(AgentRecipient.resolve(row, focused: "a", rows: ["a", "b", "c"], names: names)
            == .ask(body: said, reason: .noBreak("conversation 2")))
        #expect(AgentRecipient.resolve(row, focused: nil, rows: ["a"], names: names) == .ask(body: said, reason: .noSuchRow(2)))
        #expect(AgentRecipient.usesFocus(address))
    }

    @Test(arguments: ["Select backend", "Choose backend", "Select conversation two", "select backend please"])
    func selectIsNoLongerACommandSoItIsTextForTheFocusedConversation(_ said: String) {
        #expect(resolve(said) == .deliver(id: "a", body: said, source: .front))
        #expect(resolve(said, focused: nil) == .ask(body: said, reason: .nothingFocused))
    }

    @Test func aNameAloneOrWithPleaseHoldsWithoutSending() {
        #expect(resolve("backend") == .ask(body: "", reason: .nameOnly("backend")))
        #expect(resolve("Tell backend please") == .ask(body: "", reason: .nameOnly("backend")))
    }

    @Test func anExplicitAddressWorksWithNothingFocused() {
        #expect(resolve("Tell backend to run the tests.", focused: nil) == .deliver(id: "c", body: "to run the tests.", source: .spoken))
        #expect(resolve("Tell session two, check the migration.", focused: nil, rows: ["c", "b", "a"])
            == .deliver(id: "b", body: "check the migration.", source: .spoken))
    }

    @Test func anUnknownExplicitAddressWithNothingFocusedStillAsksAboutTheName() {
        #expect(resolve("Tell frontend to run the tests.", focused: nil) == .ask(body: "to run the tests.", reason: .unknownName("frontend")))
        #expect(resolve("Tell session five to run the build.", focused: nil) == .ask(body: "to run the build.", reason: .noSuchRow(5)))
    }
}
