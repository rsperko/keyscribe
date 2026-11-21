import Foundation
import Testing
@testable import KeyScribeKit

struct AgentAddressingTests {
    let names = ["keyscribe": "a", "keyscribe blue": "b", "backend": "c"]

    private func resolve(
        _ text: String, focused: String? = "a", rows: [String] = ["a", "b", "c"]
    ) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), focused: focused, rows: rows, names: names)
    }

    enum NumberedCell: Equatable, CustomStringConvertible {
        case to(String, body: String)
        case held

        var description: String {
            switch self {
            case .to(let name, let body): "to \(name): \(body)"
            case .held: "held"
            }
        }
    }

    @Test func aNumberAfterANameIsReadByOneRuleInEveryCellOfTheGrid() {
        let families: [(name: String, names: [String], siblings: [Int])] = [
            ("ultimate", ["ultimate", "ultimate 6", "ultimate 61", "ultimate 250", "backend"], [6, 61, 250]),
            ("pi", ["pi", "backend"], []),
        ]
        let numbers: [(said: String, value: Int)] = [
            ("61", 61), ("68", 68), ("3", 3),
            ("six", 6), ("two", 2),
            ("two fifty", 250), ("sixty one", 61), ("sixty eight", 68), ("six eight", -1),
        ]
        let follows: [(said: String, ordinary: Bool, body: String)] = [
            (", reply ready", false, "reply ready"),
            ("", false, ""),
            (" tests are failing", true, "tests are failing"),
        ]
        var wrong: [String] = []
        for family in families {
            for number in numbers {
                for follow in follows {
                    for verb in ["tell ", ""] {
                        let text = "\(verb)\(family.name) \(number.said)\(follow.said)"
                        let expected: NumberedCell
                        if family.siblings.contains(number.value) {
                            expected = .to(AgentHandles.normalize("\(family.name) \(number.value)"), body: follow.body)
                        } else if !family.siblings.isEmpty, !follow.ordinary {
                            expected = .held
                        } else {
                            expected = .to(family.name, body: "\(number.said)\(follow.said)".trimmingCharacters(in: .whitespaces))
                        }
                        let actual: NumberedCell
                        switch AgentAddress.parse(text, names: family.names, read: InverseTextNormalizer.apply) {
                        case .name(let name, let body): actual = .to(name, body: body)
                        case .unresolved: actual = .held
                        case let other: actual = .to("unexpected \(other)", body: "")
                        }
                        if actual != expected { wrong.append("\(text) → \(actual), expected \(expected)") }
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) cells:\n\(wrong.joined(separator: "\n"))")
    }

    @Test(arguments: ["tell ultimate 68, reply ready", "tell ultimate sixty eight, reply ready", "tell ultimate six eight, reply ready"])
    func anUnknownNumberNeverDeliversToTheShorterName(text: String) {
        let names = ["ultimate": "standing", "ultimate 250": "branch"]
        let address = AgentAddress.parse(text, names: Array(names.keys), read: InverseTextNormalizer.apply)
        guard case .ask = AgentRecipient.resolve(address, focused: "standing", rows: Array(names.values), names: names) else {
            Issue.record("an unknown numbered address must hold: \(address)")
            return
        }
    }

    @Test(arguments: ["tell ultimate 250, reply ready", "tell ultimate two hundred fifty, reply ready", "tell ultimate two fifty, reply ready"])
    func aNumberedNameAcceptsBothFullAndGroupedSpeech(text: String) {
        #expect(AgentAddress.parse(text, names: ["ultimate", "ultimate 250"], read: InverseTextNormalizer.apply)
                == .name("ultimate 250", body: "reply ready"))
    }

    @Test(arguments: [
        "select backend", "Select backend.", "choose backend", "Choose the backend", "please select backend",
        "select backend please", "Select conversation three", "choose session 3", "Select conversation 3.",
    ])
    func selectOrChooseIsTextForTheConversationInFrontAndNeverPicksTheNamedOne(text: String) {
        #expect(resolve(text) == .deliver(id: "a", body: text, source: .front))
    }

    @Test(arguments: ["select frontend", "select backend rows where active is true", "choose backend over frontend for this"])
    func selectFollowedByAnythingIsAMessage(text: String) {
        #expect(resolve(text) == .deliver(id: "a", body: text, source: .front))
    }

    @Test(arguments: [
        ("backend", "backend"), ("Backend.", "backend"), ("please backend", "backend"), ("tell backend", "backend"),
        ("session two", "conversation 2"), ("Conversation 2", "conversation 2"),
    ])
    func aConversationAloneHoldsAndSendsNothing(text: String, said: String) {
        #expect(resolve(text) == .ask(body: "", reason: .nameOnly(said)))
    }

    @Test(arguments: [("backend please", "backend"), ("Backend, please.", "backend"), ("tell backend please", "backend"),
                      ("conversation two please", "conversation 2")])
    func aConversationWithOnlyPleaseHoldsAndSendsNothing(text: String, said: String) {
        #expect(resolve(text) == .ask(body: "", reason: .nameOnly(said)))
    }

    @Test(arguments: [
        "ask frontend what it needs from me", "Ask frontend whether it is done.", "please ask frontend what you need",
        "ask frontend if it is done", "ask frontend why it is stuck", "Ask frontend how it is going.",
        "ask frontend when they will finish", "ask frontend where it put the logs",
        "ask frontend what changed", "ask frontend how the deploy went", "Ask frontend why the build failed.",
    ])
    func askingAnUnknownConversationAQuestionHolds(text: String) {
        guard case .ask(_, .unknownName("frontend")) = resolve(text) else {
            Issue.record("expected a hold for an unknown name, got \(resolve(text))"); return
        }
    }

    @Test(arguments: [
        "ask clarifying questions first", "ask questions if anything is unclear", "ask me before you push",
        "ask questions if you get stuck", "ask frontend to run the tests", "ask again if it fails",
        "ask first if they need the logs", "ask the user whether to keep the schema", "ask questions how to proceed",
        "ask the frontend what it needs from me", "Ask yourself whether the cache is needed.",
    ])
    func askingWithoutAConversationIsStillAMessage(text: String) {
        #expect(resolve(text) == .deliver(id: "a", body: text, source: .front))
    }

    @Test(arguments: ["open first", "switch to later"])
    func navigatingToAnAdverbThatNamesNothingHolds(text: String) {
        guard case .ask(_, .unknownName) = resolve(text) else {
            Issue.record("expected a hold for an unknown name, got \(resolve(text))"); return
        }
    }

    @Test func aConversationFollowedByAMessageStillSends() {
        #expect(resolve("backend, run the tests") == .deliver(id: "c", body: "run the tests", source: .spoken))
    }

    @Test func askingWhatItNeedsSendsTheQuestion() {
        #expect(AgentStatusQuery.parse("ask backend what it needs from me", names: Array(names.keys)) == nil)
        #expect(resolve("ask backend what it needs from me") == .deliver(id: "c", body: "what it needs from me", source: .spoken))
    }

    @Test(arguments: ["Conversation 2 run the tests.", "tell conversation two run the tests", "Session 2 run the tests."])
    func conversationAndSessionAddressARowAlike(text: String) {
        #expect(resolve(text) == .deliver(id: "b", body: "run the tests.", source: .spoken)
            || resolve(text) == .deliver(id: "b", body: "run the tests", source: .spoken))
    }

    @Test(arguments: ["open conversation two", "Open session 2"])
    func openingARowByEitherNounOpensIt(text: String) {
        #expect(resolve(text) == .open(id: "b"))
    }

    @Test(arguments: ["open backend please", "Please open backend."])
    func politeOpenStillOpens(text: String) {
        #expect(resolve(text) == .open(id: "c"))
    }

    @Test func conversationFollowedByARowNumberIsReservedLikeSession() {
        #expect(AgentHandles.isReserved("conversation two"))
        #expect(AgentHandles.isReserved("conversation"))
        #expect(!AgentHandles.isReserved("conversation notes"))
    }
}

struct AgentAddressingWithoutAVerbTests {
    let names = ["reply with pong": "a", "foo jk boots manager": "b", "in front": "c"]

    private func resolve(_ text: String) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), focused: "c", rows: ["a", "b", "c"], names: names)
    }

    @Test(arguments: ["Reply with the word pong.", "Reply with something short.", "jk boots, run the tests", "boots manager run the tests"])
    func aTakeThatStartsWithPartOfANameButNoVerbGoesWholeToTheConversationInFront(text: String) {
        #expect(resolve(text) == .deliver(id: "c", body: text, source: .front))
    }

    @Test func aTakeThatStartsWithAWholeNameStillAddressesItWithoutAVerb() {
        #expect(resolve("Reply with pong, say it again") == .deliver(id: "a", body: "say it again", source: .spoken))
    }

    @Test(arguments: [("tell reply with the word pong", "a", "the word pong"), ("tell jk boots run the tests", "b", "run the tests")])
    func partOfANameStillAddressesItAfterTell(text: String, id: String, body: String) {
        #expect(resolve(text) == .deliver(id: id, body: body, source: .spoken))
    }
}
