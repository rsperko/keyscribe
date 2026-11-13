import Foundation
import KeyScribeKit
import Testing

struct AgentDeliveryTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000.120)
    private let utc = TimeZone(identifier: "UTC")!

    @Test func aConfirmedDeliveryRecordsWhenEachSideSawIt() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.absorb(AgentDeliveryReport(state: .seen, handedAt: start.addingTimeInterval(0.31), seenAt: start.addingTimeInterval(0.42)))
        delivery.confirmed = start.addingTimeInterval(0.45)
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc) == HistoryEntry.Fact(
            label: "Delivery",
            value: "Handed off at 22:13:20.120; Pi had it +0.31 s; it entered the conversation +0.42 s; confirmed +0.45 s"))
    }

    @Test func aDeliveryConfirmedAfterAReconnectAndChangedOnItsWaySaysSo() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.reconnects = 2
        delivery.absorb(AgentDeliveryReport(state: .seen, seenAt: start.addingTimeInterval(1), altered: true))
        delivery.confirmed = start.addingTimeInterval(3)
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc).value
            == "Handed off at 22:13:20.120; it entered the conversation +1.00 s, changed on its way in; confirmed +3.00 s; 2 reconnects while waiting")
    }

    @Test func aDoubtedDeliveryRecordsWhatTheCheckFoundAndWhyNothingMatched() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.absorb(AgentDeliveryReport(state: .handed, handedAt: start.addingTimeInterval(0.2), miss: "other"))
        delivery.check = .answered(.handed)
        delivery.doubted = start.addingTimeInterval(8.5)
        delivery.followedTurn = start.addingTimeInterval(9)
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc).value
            == "Handed off at 22:13:20.120; Pi had it +0.20 s; not confirmed by +8.50 s; "
            + "a check found Pi had it but it had not entered the conversation; another message entered the conversation; "
            + "a turn started +9.00 s, so its reply is followed")
    }

    @Test(arguments: [
        (AgentDelivery.Check.unanswered, "a check got no answer"),
        (.answered(.holding), "a check found Pi still holding it"),
        (.answered(.unknown), "a check found the connector has no record of it"),
        (.answered(.refused), "a check found Pi refused it"),
        (.answered(.seen), "a check found it in the conversation"),
    ])
    func eachCheckOutcomeIsNamed(_ check: AgentDelivery.Check, _ words: String) {
        var delivery = AgentDelivery(handedOff: start)
        delivery.check = check
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc).value == "Handed off at 22:13:20.120; \(words)")
    }

    @Test func aMissTheAppDoesNotKnowNeverPutsTheConnectorsWordsInHistory() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.absorb(AgentDeliveryReport(state: .handed, miss: "anything a connector says"))
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc).value
            == "Handed off at 22:13:20.120; it did not match, for a reason this version does not know")
    }

    @Test func aConfirmedDeliveryDropsTheEarlierMiss() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.absorb(AgentDeliveryReport(state: .handed, miss: "other"))
        delivery.absorb(AgentDeliveryReport(state: .seen, seenAt: start.addingTimeInterval(9)))
        delivery.confirmed = start.addingTimeInterval(9.1)
        #expect(AgentHistoryFacts.delivery(delivery, agent: "Pi", timeZone: utc).value
            == "Handed off at 22:13:20.120; it entered the conversation +9.00 s; confirmed +9.10 s")
    }

    @Test func aLaterReportNeverErasesWhatAnEarlierOneSaid() {
        var delivery = AgentDelivery(handedOff: start)
        delivery.absorb(AgentDeliveryReport(state: .handed, handedAt: start.addingTimeInterval(0.2), miss: "other"))
        delivery.absorb(AgentDeliveryReport(state: .seen, seenAt: start.addingTimeInterval(9)))
        #expect(delivery.handedToAgent == start.addingTimeInterval(0.2))
        #expect(delivery.miss == "other")
        #expect(delivery.entered == start.addingTimeInterval(9))
    }
}
