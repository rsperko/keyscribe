import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct TerminalPlaceReaderTests {
    private let query = AgentPlaceQuery(id: "claude:a", agent: "claude", native: "a", pid: 30)
    private let host = TerminalHost(route: "Ghostty", app: "com.mitchellh.ghostty", pid: 10, ttys: ["/dev/ttys004"])
    private let answer = "W\tw1\t1\t1\nT\ttab-a\tPayments\t/dev/ttys004\nS\tterm-a\t/dev/ttys004\tArchitect\n"

    private func reader(walk: TerminalPlaceWalk?, read: TerminalRead) -> TerminalPlaceReader {
        TerminalPlaceReader(walk: { _, _, _ in walk }, script: { _, _, _ in read })
    }

    @Test func aTerminalTheUserNamedNamesThePlaceAfterAnyMultiplexerInsideIt() async {
        let tmux = PlaceLayer(
            labels: [.init(text: "backend", level: .tab, container: "tmux#window:@3", surface: "tmux")], containers: ["tmux#window:@3"])
        let walk = TerminalPlaceWalk(layers: [tmux], host: host, surface: "tmux")
        guard case .found(let place)? = await reader(walk: walk, read: .value(answer)).read([query])[query.id] else {
            Issue.record("expected a place")
            return
        }
        #expect(place.labels.map(\.text) == ["backend", "Architect", "Payments"])
        #expect(place.surface == "tmux")
    }

    @Test func aTerminalThatCannotBeReadWithoutAskingAddsNoNameAndAsksNothing() async {
        let walk = TerminalPlaceWalk(host: host, surface: "Ghostty")
        #expect(await reader(walk: walk, read: .notAllowed).read([query])[query.id] == .absent)
    }

    @Test func aFailedWalkKeepsTheNamesOfAConversationThatHadAPlaceAndNeverHoldsOneThatHadNone() async {
        var placed = query
        placed.placed = true
        let unresolved = TerminalPlaceWalk(layers: [PlaceLayer(unresolved: true)], surface: "tmux")
        for walk in [nil, unresolved] as [TerminalPlaceWalk?] {
            #expect(await reader(walk: walk, read: .failed).read([placed])[query.id] == .unknown)
            #expect(await reader(walk: walk, read: .failed).read([query])[query.id] == .absent)
        }
    }

    @Test func aTerminalAppThatFailsOrIsNotAllowedYetNeverMakesThePlaceUnknownAndAFailureReusesItsLastAnswer() async {
        var placed = query
        placed.placed = true
        let walk = TerminalPlaceWalk(host: host, surface: "Ghostty")
        final class Reads: @unchecked Sendable { var next: [TerminalRead] = [] }
        let reads = Reads()
        reads.next = [.value(answer), .failed, .notAllowed]
        let reader = TerminalPlaceReader(walk: { _, _, _ in walk }, script: { _, _, _ in reads.next.removeFirst() })
        guard case .found(let first)? = await reader.read([placed])[query.id] else {
            Issue.record("expected a place")
            return
        }
        #expect(first.labels.map(\.text) == ["Architect", "Payments"])
        #expect(await reader.read([placed])[query.id] == .found(first))
        #expect(await reader.read([placed])[query.id] == .absent)
    }

    @Test func herdrAndTheTerminalAroundItCombineAndAnyUnknownKeepsTheLastNamesUnchecked() {
        let inner = AgentPlace(surface: "herdr", labels: [.init(text: "marvin", level: .title, container: "h#pane")], containers: ["h#pane"])
        let outer = AgentPlace(
            surface: "Ghostty", labels: [.init(text: "Payments", level: .tab, container: "g#tab", surface: "Ghostty")], containers: ["g#tab"])
        #expect(CombinedPlaceReader.merge([.found(inner), .found(outer)])
            == .found(AgentPlace(surface: "herdr", labels: inner.labels + outer.labels, containers: ["h#pane", "g#tab"])))
        #expect(CombinedPlaceReader.merge([.found(inner), .unknown]) == .unknown)
        #expect(CombinedPlaceReader.merge([.absent, .absent]) == .absent)
    }
}
