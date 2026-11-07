import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct AgentProcessTableTests {
    final class World: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        var listings = 0
        var processes: [TerminalProcess]? = []
        var running: Set<Int> = []
    }

    private func table(_ world: World, rules: [AgentProcesses.Rule] = [.pi, .claude]) -> AgentProcessTable {
        AgentProcessTable(rules: rules, maxAge: 5, home: "/Users/a", now: { world.now }, isRunning: { world.running.contains($0) }) { _ in
            world.listings += 1
            return world.processes
        }
    }

    private func process(_ pid: Int, name: String, arguments: [String], readable: Bool = true) -> TerminalProcess {
        TerminalProcess(
            pid: pid, parent: 1, tty: "/dev/ttys001", arguments: arguments, environment: [:], executable: "/bin/\(name)", app: nil,
            directory: "/Users/a/src/atlas", startedAt: 100, argumentsReadable: readable)
    }

    @Test func bothAgentsAreFoundFromOneListingOfTheProcessTable() {
        let world = World()
        world.processes = [process(10, name: "pi", arguments: ["pi"]), process(20, name: "2.1.319", arguments: ["claude"])]
        let table = table(world)
        #expect(table.found(.pi).candidates.map(\.pid) == [10])
        #expect(table.found(.claude).candidates.map(\.pid) == [20])
        #expect(world.listings == 1)
    }

    @Test func theTableIsListedAgainOnlyOnceTheLastListingIsOld() {
        let world = World()
        let table = table(world)
        _ = table.found(.pi)
        world.now += 4
        _ = table.found(.pi)
        #expect(world.listings == 1)
        world.now += 1
        _ = table.found(.pi)
        #expect(world.listings == 2)
    }

    @Test func aTableThatLearnsItsAgentsFromItsCallersListsAgainOnlyForAnAgentItHasNotSeen() {
        let world = World()
        let table = table(world, rules: [])
        _ = table.found(.claude)
        _ = table.found(.pi)
        _ = table.found(.claude)
        #expect(world.listings == 2)
    }

    @Test func aFailedListingKeepsTheAgentsSeenEarlierThatStillRunAndSaysItIsStale() {
        let world = World()
        world.processes = [process(10, name: "pi", arguments: ["pi"]), process(11, name: "pi", arguments: ["pi"])]
        world.running = [10]
        let table = table(world)
        _ = table.found(.pi)
        world.processes = nil
        world.now += 5
        let found = table.found(.pi)
        #expect(found.stale)
        #expect(found.isPartial)
        #expect(found.candidates.map(\.pid) == [10])
    }

    @Test func anAgentWhoseProcessCouldNotBeReadAgainStaysWithTheSetupSeenEarlier() {
        let world = World()
        world.processes = [process(10, name: "pi", arguments: ["pi"])]
        world.running = [10]
        let table = table(world)
        _ = table.found(.pi)
        world.processes = [process(10, name: "pi", arguments: [], readable: false), process(12, name: "pi", arguments: ["pi"])]
        world.now += 5
        let found = table.found(.pi)
        #expect(found.candidates.map(\.pid) == [12, 10])
        #expect(found.isPartial)
        #expect(!found.stale)
    }
}
