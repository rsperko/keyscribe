import Foundation
import Testing
@testable import KeyScribeKit

struct AgentNativeAddressTests {
    enum Cell: Equatable, CustomStringConvertible {
        case to(String, body: String)
        case opened(String)
        case held

        var description: String {
            switch self {
            case .to(let id, let body): "to \(id): \(body)"
            case .opened(let id): "open \(id)"
            case .held: "held"
            }
        }
    }

    static let ultimateKind = AgentKind(id: "ultimate", displayName: "Ultimate", connectorName: "Ultimate extension")
    static let ultimate = UltimateAddress.reader(for: ultimateKind)

    static let tracker = AgentNativeAddress(agent: "tracker") { words in
        guard let key = words.first, ["flex", "mfmo"].contains(key) else { return nil }
        guard let number = SpokenNumber.read(words.dropFirst(), forms: [.whole, .grouped, .digits]) else { return nil }
        let native = number.value.flatMap { $0 < 10_000 ? "\(key.uppercased())-\($0)" : nil }
        return .init(native: native, words: 1 + number.words)
    }

    static func member(
        _ agent: String, _ native: String, _ id: String, handle: String? = nil, otherNames: [String] = [], workspace: String? = nil
    ) -> AgentNativeRoster.Member {
        .init(agent: agent, native: native, id: id, handle: handle ?? names.filter { $0.value == id }.keys.min() ?? id,
              otherNames: otherNames, workspace: workspace)
    }

    static let names = [
        "ultimate": "u53", "ultimate six": "u6", "ultimate 61": "u61", "ultimate 250": "u250", "release notes": "u75",
        "login bug": "t240", "mfmo seven": "t7", "backend": "c1",
    ]
    static let members = [
        member("ultimate", "53", "u53"), member("ultimate", "6", "u6"), member("ultimate", "61", "u61"),
        member("ultimate", "250", "u250"), member("ultimate", "75", "u75"),
        member("tracker", "FLEX-240", "t240"), member("tracker", "MFMO-7", "t7"),
    ]
    static let roster = AgentNativeRoster(addresses: [ultimate, tracker], members: members)

    func outcome(
        _ text: String, names: [String: String] = Self.names, roster: AgentNativeRoster = Self.roster,
        read: ((String) -> String)? = nil, namesKnown: Bool = true
    ) -> Cell {
        let address = AgentAddress.parse(text, names: Array(names.keys), namesKnown: namesKnown, read: read, natives: roster)
        switch AgentRecipient.resolve(address, focused: "front", rows: Array(Set(names.values)).sorted(), names: names) {
        case .deliver(let id, let body, _): return .to(id, body: body)
        case .open(let id): return .opened(id)
        case .ask: return .held
        }
    }

    @Test func anUltimateNumberIsReadByOneRuleInEveryCellOfTheGrid() {
        let numbers: [(said: String, id: String?)] = [
            ("61", "u61"), ("sixty one", "u61"), ("six", "u6"), ("6", "u6"), ("two fifty", "u250"), ("two hundred fifty", "u250"),
            ("250", "u250"), ("75", "u75"), ("seventy five", "u75"), ("conversation 61", "u61"), ("session sixty one", "u61"),
            ("68", nil), ("two", nil), ("sixty eight", nil), ("conversation 3", nil),
            ("six eight", nil), ("68 2", nil), ("61 two", nil),
        ]
        let follows: [(said: String, body: String)] = [
            (", reply ready", "reply ready"),
            (" reply ready", "reply ready"),
            (": Reply ready, see https://ex.io/a?b=C.", "Reply ready, see https://ex.io/a?b=C."),
            (" tests are failing", "tests are failing"),
        ]
        var wrong: [String] = []
        for verb in ["tell ", "Tell ", "please tell ", "ask ", ""] {
            for number in numbers {
                for follow in follows {
                    let text = "\(verb)ultimate \(number.said)\(follow.said)"
                    let expected = number.id.map { Cell.to($0, body: follow.body) } ?? .held
                    for roster in [Self.roster, AgentNativeRoster(addresses: Self.roster.addresses.reversed(), members: Self.members.reversed())] {
                        for read in [nil, InverseTextNormalizer.apply] as [((String) -> String)?] {
                            let actual = outcome(text, roster: roster, read: read)
                            if actual != expected { wrong.append("\(text) → \(actual), expected \(expected)") }
                        }
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) cells:\n\(Array(Set(wrong)).sorted().joined(separator: "\n"))")
    }

    @Test(arguments: [
        ("tell ultimate there are 99 failing tests", "u53", "there are 99 failing tests"),
        ("tell ultimate, 99 tests are failing", "u53", "99 tests are failing"),
        ("Tell Ultimate: 2 things are broken", "u53", "2 things are broken"),
        ("tell ultimate to fix the 2 failing tests", "u53", "to fix the 2 failing tests"),
        ("tell login bug 240 is still broken", "t240", "240 is still broken"),
        ("tell backend 61 tests are failing", "c1", "61 tests are failing"),
        ("tell release notes 2 more sections", "u75", "2 more sections"),
    ])
    func aNumberAfterAnUnambiguousRecipientIsTheMessage(text: String, id: String, body: String) {
        #expect(outcome(text) == .to(id, body: body))
    }

    @Test(arguments: [
        "tell flex two forty reply ready", "tell flex two hundred forty reply ready", "tell flex two four zero reply ready",
        "tell flex 240 reply ready", "Tell FLEX-240: reply ready", "tell flex240 reply ready", "flex two forty, reply ready",
        "ask flex two forty reply ready",
    ])
    func aTicketIdIsReachedByEveryWayItIsSaidAndAfterItWasRenamed(text: String) {
        #expect(outcome(text) == .to("t240", body: "reply ready"))
    }

    @Test(arguments: [
        "tell flex 999 reply ready", "tell flex nine nine nine reply ready", "tell mfmo 240, reply ready",
        "tell flex nine nine nine nine nine reply ready", "flex 7 reply ready",
    ])
    func aTicketIdNamingNoListedTicketHoldsAndSendsNothing(text: String) {
        #expect(outcome(text) == .held)
    }

    @Test func theTicketIdsStayOpaqueToSharedCode() {
        let message = "tell flex 240 \u{2014} caf\u{00E9} \u{2713} `npm test` at https://ex.io/A?b=1"
        #expect(outcome(message) == .to("t240", body: "\u{2014} caf\u{00E9} \u{2713} `npm test` at https://ex.io/A?b=1"))
        #expect(outcome("tell mfmo seven reply ready") == .to("t7", body: "reply ready"))
        #expect(outcome("tell mfmo 7 reply ready") == .to("t7", body: "reply ready"))
    }

    @Test(arguments: [
        ("open ultimate two fifty", Cell.opened("u250")), ("Open flex two forty.", .opened("t240")),
        ("open ultimate 68", .held), ("switch to ultimate conversation 61", .opened("u61")),
    ])
    func openReadsTheSameAddressSendingDoes(text: String, expected: Cell) {
        #expect(outcome(text) == expected)
    }

    @Test(arguments: [
        ("check on ultimate two fifty", "u250"), ("check on flex two forty", "t240"), ("Check on ultimate 61.", "u61"),
        ("check on ultimate 68", nil), ("check on flex 999", nil),
    ])
    func aStatusCheckReadsTheSameAddressSendingDoes(text: String, id: String?) throws {
        let query = try #require(AgentStatusQuery.parse(text, names: Array(Self.names.keys), natives: Self.roster))
        guard case .check(let address?) = query else { Issue.record("expected one conversation, got \(query)"); return }
        let resolved = AgentRecipient.conversation(address, focused: "front", rows: [], names: Self.names)
        if let id {
            #expect(resolved == .deliver(id: id, body: "", source: .spoken))
        } else if case .ask(_, .unknownName) = resolved {
        } else {
            Issue.record("an unknown address must hold, got \(resolved)")
        }
    }

    @Test func aNameTheUserChoseThatEqualsANativeAddressWinsAndALongerNameWins() {
        var names = Self.names
        names["ultimate 68"] = "c1"
        names["ultimate 61 rollout"] = "u250"
        #expect(outcome("tell ultimate 68 reply ready", names: names) == .to("c1", body: "reply ready"))
        #expect(outcome("tell ultimate sixty eight reply ready", names: names, read: InverseTextNormalizer.apply) == .to("c1", body: "reply ready"))
        #expect(outcome("tell ultimate 61 rollout is done", names: names) == .to("u250", body: "is done"))
        #expect(outcome("tell ultimate 61 reply ready", names: names) == .to("u61", body: "reply ready"))
    }

    @Test func aNameThatStartsWithTheIntegrationsWordStaysAName() {
        var names = Self.names
        names["ultimate notes"] = "u75"
        #expect(outcome("tell ultimate notes 2 bugs left", names: names) == .to("u75", body: "2 bugs left"))
    }

    @Test func twoProjectsWithTheSameNumberAskUnlessTheProjectIsSaid() {
        let names = ["app ultimate": "a53", "web ultimate": "w53", "release notes": "a61", "web ultimate 61": "w61"]
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "53", "a53", workspace: "app"), Self.member("ultimate", "53", "w53", workspace: "web"),
            Self.member("ultimate", "61", "a61", workspace: "app"), Self.member("ultimate", "61", "w61", workspace: "web"),
        ])
        #expect(outcome("tell ultimate 61 run the tests", names: names, roster: roster) == .held)
        #expect(outcome("tell app ultimate 61 run the tests", names: names, roster: roster) == .to("a61", body: "run the tests"))
        #expect(outcome("tell app ultimate sixty one run the tests", names: names, roster: roster) == .to("a61", body: "run the tests"))
        #expect(outcome("tell web ultimate 61 run the tests", names: names, roster: roster) == .to("w61", body: "run the tests"))
        #expect(outcome("tell app ultimate run the tests", names: names, roster: roster) == .to("a53", body: "run the tests"))
        #expect(outcome("tell app ultimate 68 run the tests", names: names, roster: roster) == .held)
        #expect(outcome("tell app ultimate there are 2 bugs", names: names, roster: roster) == .to("a53", body: "there are 2 bugs"))
    }

    @Test func aFrozenRowNumberAndANativeNumberAreDifferentAddresses() {
        let rows = ["u53", "u6", "u61"]
        let address = AgentAddress.parse("tell conversation 3 run the tests", names: Array(Self.names.keys), natives: Self.roster)
        #expect(AgentRecipient.resolve(address, focused: nil, rows: rows, names: Self.names) == .deliver(id: "u61", body: "run the tests", source: .spoken))
        #expect(outcome("tell ultimate conversation 3 run the tests") == .held)
    }

    @Test func aRosterThatCouldNotBeReadNeverSendsAnAddressedTake() {
        let unread = AgentNativeRoster(addresses: Self.roster.addresses, members: [])
        #expect(outcome("tell ultimate 68 reply ready", names: [:], roster: unread, namesKnown: false) == .held)
        #expect(outcome("tell ultimate 61 reply ready", names: [:], roster: unread, namesKnown: false) == .held)
    }

    @Test func anIntegrationThatIsNotTurnedOnClaimsNoWords() {
        let elsewhere = AgentNativeRoster(addresses: [Self.tracker], members: [Self.member("tracker", "FLEX-240", "t240")])
        #expect(outcome("Ultimate 68 is the branch with the bug", names: ["backend": "c1"], roster: elsewhere)
                == .to("front", body: "Ultimate 68 is the branch with the bug"))
        #expect(outcome("flex 999 is the ticket", names: ["backend": "c1"], roster: elsewhere) == .held)
    }

    @Test(arguments: ["ask ultimate 68 reply ready", "ultimate 68 reply ready", "tell ultimate 68 reply ready", "ask ultimate 61 reply ready"])
    func anIntegrationTurnedOnWithNoListedConversationStillHoldsItsAddresses(text: String) {
        let empty = AgentNativeRoster(addresses: [Self.ultimate], members: [Self.member("other", "1", "c1", handle: "backend")])
        #expect(outcome(text, names: ["backend": "c1"], roster: empty) == .held)
    }

    @Test(arguments: [
        ("tell ultimate 61 and one more thing, check the logs", "u61", "and one more thing, check the logs"),
        ("tell flex 240 and two other bugs", "t240", "and two other bugs"),
        ("tell ultimate two hundred and fifty reply ready", "u250", "reply ready"),
    ])
    func anAndAfterTheNumberStartsTheMessage(text: String, id: String, body: String) {
        #expect(outcome(text) == .to(id, body: body))
    }

    @Test(arguments: ["tell ultimate 61:reply ready", "tell ultimate 61's tests failed", "tell flex 240x reply ready"])
    func anAddressEndingInsideAWordHoldsRatherThanReachingAShorterName(text: String) {
        #expect(outcome(text) == .held)
    }

    @Test func anAmbiguousAddressOffersEachConversationsCurrentName() {
        let names = ["release notes": "a61", "alpha": "a61", "ultimate 61": "w61"]
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "a61", handle: "release notes", workspace: "app"),
            Self.member("ultimate", "61", "w61", handle: "ultimate 61", workspace: "web"),
        ])
        let address = AgentAddress.parse("tell ultimate sixty one run the tests", names: Array(names.keys), natives: roster)
        #expect(AgentRecipient.resolve(address, focused: nil, rows: [], names: names)
                == .ask(body: "run the tests", reason: .ambiguousName("ultimate sixty one", matches: ["release notes", "ultimate 61"])))
        let facts = AgentHistoryFacts.facts(address: address, resolution: AgentRecipient.resolve(address, focused: nil, rows: [], names: names),
                                            focused: nil, conversations: [])
        #expect(facts.contains(.init(label: "Candidates", value: "release notes, ultimate 61")))
    }

    @Test func aHandleEqualToAnAddressSharedAcrossProjectsAsks() {
        let names = ["release notes": "a61", "ultimate 61": "w61"]
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "a61", handle: "release notes", workspace: "app"),
            Self.member("ultimate", "61", "w61", handle: "ultimate 61", workspace: "web"),
        ])
        #expect(outcome("tell ultimate 61 run the tests", names: names, roster: roster) == .held)
        #expect(outcome("tell ultimate sixty one run the tests", names: names, roster: roster, read: InverseTextNormalizer.apply) == .held)
        #expect(outcome("tell ultimate two fifty run the tests", names: names, roster: roster) == .held)
        #expect(outcome("tell web ultimate 61 run the tests", names: names, roster: roster) == .to("w61", body: "run the tests"))
        #expect(outcome("tell release notes run the tests", names: names, roster: roster) == .to("a61", body: "run the tests"))
    }

    @Test func aWorkspaceWithADigitOrAnArticleNarrowsTheAddress() {
        let names = ["release notes": "a61", "plans": "w61"]
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "a61", handle: "release notes", workspace: "app2"),
            Self.member("ultimate", "61", "w61", handle: "plans", workspace: "the lab"),
        ])
        for said in ["app2", "app 2", "app two", "App2"] {
            #expect(outcome("tell \(said) ultimate 61 run the tests", names: names, roster: roster) == .to("a61", body: "run the tests"), "\(said)")
        }
        #expect(outcome("tell the lab ultimate 61 run the tests", names: names, roster: roster) == .to("w61", body: "run the tests"))
    }

    @Test func anAddressIsAlsoReadThroughTheUsersReplacements() {
        let read: (String) -> String = {
            $0.replacingOccurrences(of: "m f m o", with: "mfmo", options: .caseInsensitive)
                .replacingOccurrences(of: "ultimat ", with: "ultimate ", options: .caseInsensitive)
        }
        #expect(outcome("tell m f m o seven reply ready", read: read) == .to("t7", body: "reply ready"))
        #expect(outcome("tell ultimat 61 reply ready", read: read) == .to("u61", body: "reply ready"))
        for text in ["tell m f m o 12 reply ready", "m f m o 12 reply ready", "ask m f m o 12 reply ready", "tell ultimat 68 reply ready",
                     "ultimat 68 reply ready"] {
            let address = AgentAddress.parse(text, names: Array(Self.names.keys), read: read, natives: Self.roster)
            guard case .native(let spoken, let handles, let body) = address else { Issue.record("\(text) → \(address)"); continue }
            #expect(handles.isEmpty, "\(text)")
            #expect(body == "reply ready", "\(text)")
            #expect(["m f m o 12", "ultimat 68"].contains(spoken), "\(text)")
        }
    }

    @Test func anOrdinaryTakeRunsTheUsersReplacementsAtMostOnceMoreForAddresses() {
        final class Count: @unchecked Sendable { var reads = 0 }
        func reads(_ roster: AgentNativeRoster) -> Int {
            let count = Count()
            _ = AgentAddress.parse("tell backend run the whole test suite again please", names: Array(Self.names.keys),
                                   read: { count.reads += 1; return $0 }, natives: roster)
            return count.reads
        }
        #expect(reads(Self.roster) - reads(AgentNativeRoster()) <= 1)
    }

    @Test(arguments: ["tell ultimate 61 run the tests", "open ultimate 61"])
    func aTitleShownOnlyAfterAVerbThatEqualsAnotherConversationsAddressAsks(text: String) {
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "u61", handle: "ultimate 61"),
            Self.member("ultimate", "62", "u62", handle: "planning", otherNames: ["ultimate 61"]),
        ])
        let address = AgentAddress.parse(text, names: ["backend", "planning"], afterVerb: ["ultimate 61"], natives: roster)
        let handles: [String: String]? = switch address {
        case .native(_, let handles, _), .open(.native(_, let handles, _)): handles
        default: nil
        }
        #expect(handles == ["u61": "ultimate 61", "u62": "planning"], "\(address)")
    }

    @Test(arguments: ["check on ultimate 61", "tell ultimate 61 run the tests"])
    func aStatusCheckAsksWhereSendingAsksForATitleEqualToAnotherConversationsAddress(text: String) {
        let names = ["release notes": "u61", "planning": "u62"]
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "u61", handle: "release notes"),
            Self.member("ultimate", "62", "u62", handle: "planning", otherNames: ["ultimate 61"]),
        ])
        let address: AgentAddress? = if case .check(let checked)? = AgentStatusQuery.parse(
            text, names: Array(names.keys), afterVerb: ["ultimate 61"], natives: roster) { checked } else {
            AgentAddress.parse(text, names: Array(names.keys), afterVerb: ["ultimate 61"], natives: roster)
        }
        let resolved = address.map { AgentRecipient.conversation($0, focused: nil, rows: [], names: names) }
        #expect(resolved == .ask(body: "", reason: .ambiguousName("ultimate 61", matches: ["planning", "release notes"]))
                || resolved == .ask(body: "run the tests", reason: .ambiguousName("ultimate 61", matches: ["planning", "release notes"])),
                "\(String(describing: address))")
    }

    @Test(arguments: [
        ("tell bond zero zero seven reply ready", "b007"), ("tell bond 007 reply ready", "b007"), ("Tell Bond 007: reply ready", "b007"),
        ("tell bond seven reply ready", "b7"), ("tell bond 7 reply ready", "b7"), ("tell bond0 0 7 reply ready", "b007"),
    ])
    func anAdapterCanTellLeadingZerosApart(text: String, id: String) {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let bond = AgentNativeAddress(agent: "bond") { words in
            guard words.first == "bond" else { return nil }
            var digits = ""
            for word in words.dropFirst() {
                if let unit = units.firstIndex(of: word) { digits += String(unit) }
                else if word.allSatisfy(\.isNumber) { digits += word }
                else { break }
            }
            return digits.isEmpty ? nil : .init(native: digits, words: 1 + words.dropFirst().prefix { units.contains($0) || $0.allSatisfy(\.isNumber) }.count)
        }
        let roster = AgentNativeRoster(addresses: [bond], members: [
            Self.member("bond", "007", "b007", handle: "field office"), Self.member("bond", "7", "b7", handle: "home office"),
        ])
        #expect(outcome(text, names: ["field office": "b007", "home office": "b7"], roster: roster) == .to(id, body: "reply ready"))
    }

    @Test func aReadingAndANameMatchAreSettledByOneRuleInEveryCell() {
        let roster = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "a61", handle: "release notes"), Self.member("ultimate", "61", "w61", handle: "web ultimate 61"),
            Self.member("other", "1", "c1", handle: "ultimate 61"),
        ])
        let found: [(label: String, handles: [String: String])] = [
            ("none", [:]), ("one", ["a61": "release notes"]), ("many", ["a61": "release notes", "w61": "web ultimate 61"]),
        ]
        let names: [(label: String, length: Int, exact: String?)?] = [nil, ("partial", 2, nil), ("exact", 2, "ultimate 61")]
        var wrong: [String] = []
        for reading in found {
            for tokens in [3, 2, 1] {
                for name in names {
                    let named = name?.length ?? 0
                    let expected: [String: String]? = if tokens > named { reading.handles }
                        else if tokens < named { nil }
                        else if name?.exact == nil { reading.handles }
                        else if reading.handles.isEmpty { nil }
                        else { reading.handles.merging(["c1": "ultimate 61"]) { kept, _ in kept } }
                    let actual = roster.settle((tokens, reading.handles), against: name.map { ($0.length, $0.exact) })
                    if actual != expected {
                        wrong.append("\(reading.label) handles, \(tokens) words, \(name?.label ?? "no") name → \(String(describing: actual))")
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }

    @Test func aRosterFrozenAtThePressTakesOnlyLateWorkspacesOfItsOwnConversations() {
        let frozen = AgentNativeRoster(addresses: [Self.ultimate], members: [Self.member("ultimate", "61", "u61")])
        let late = AgentNativeRoster(addresses: [Self.ultimate], members: [
            Self.member("ultimate", "61", "u61", otherNames: ["deploy tab"], workspace: "app"),
            Self.member("ultimate", "68", "u68", handle: "new", workspace: "app"),
        ])
        let merged = frozen.addingLate(late)
        #expect(merged.members == [Self.member("ultimate", "61", "u61", otherNames: ["deploy tab"], workspace: "app")])
    }

    @Test func competingIntegrationsReadingTheSameWordsAskWhicheverRegisteredFirst() {
        let mirror = AgentNativeAddress(agent: "mirror") { words in
            guard words.first == "ultimate", let number = SpokenNumber.read(words.dropFirst(), forms: [.whole]) else { return nil }
            return .init(native: number.value.map { "ULT-\($0)" }, words: 1 + number.words)
        }
        let members = Self.members.map { $0.id == "u61" ? Self.member("ultimate", "61", "u61", handle: "release", otherNames: ["ultimate 61"]) : $0 }
            + [Self.member("mirror", "ULT-61", "m61", handle: "mirror notes")]
        let names = ["backend": "c1", "ultimate": "u53", "release": "u61", "ultimate 61": "u61", "mirror notes": "m61"]
        for addresses in [[Self.ultimate, mirror], [mirror, Self.ultimate]] {
            let roster = AgentNativeRoster(addresses: addresses, members: members)
            #expect(outcome("tell ultimate 61 reply ready", names: names, roster: roster) == .held)
            #expect(outcome("tell ultimate two fifty reply ready", names: names, roster: roster) == .to("u250", body: "reply ready"))
        }
    }
}
