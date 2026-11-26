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

    @Test func aCallerReusingTheListingGetsItHoweverOldAndOthersListAgainByAge() {
        let world = World()
        let table = table(world)
        _ = table.found(.pi)
        world.now += 600
        _ = table.found(.pi, reusing: true)
        #expect(world.listings == 1)
        _ = table.found(.pi)
        #expect(world.listings == 2)
        world.now += 600
        _ = table.found(.claude, reusing: true)
        #expect(world.listings == 2)
    }

    @Test func anAgentIsClassifiedOncePerListingHoweverOftenItIsAsked() {
        final class Checks: @unchecked Sendable { var count = 0 }
        let world = World()
        let checks = Checks()
        world.processes = [process(10, name: "pi", arguments: ["pi"])]
        world.running = [10]
        let table = AgentProcessTable(rules: [.pi], maxAge: 5, home: "/Users/a", now: { world.now }, isRunning: {
            checks.count += 1
            return world.running.contains($0)
        }) { _ in
            world.listings += 1
            return world.processes
        }
        let first = table.found(.pi)
        #expect(first.candidates.map(\.pid) == [10])
        let afterOne = checks.count
        world.now += 4
        #expect(table.found(.pi) == first)
        #expect(table.found(.pi) == first)
        #expect(checks.count == afterOne)
        world.now += 1
        _ = table.found(.pi)
        #expect(checks.count > afterOne)
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

    @Test func sightingsKeepProgramPathsAndExistingFilesButNeverOtherArguments() {
        let agent = TerminalProcess(
            pid: 10, parent: 1, tty: "/dev/ttys001", arguments: ["claude", "-p", "fix /etc/hosts for me", "--user-data-dir=/Users/a/x"],
            environment: [:], executable: "/Users/a/.local/share/claude/versions/2.1.326", app: nil, directory: "/Users/a", startedAt: 1)
        let helper = TerminalProcess(
            pid: 11, parent: 1, tty: nil, arguments: ["node", "/Users/a/tools/claude-helper.js", "/secret note"], environment: [:],
            executable: "/usr/local/bin/node", app: nil, directory: "/Users/a", startedAt: 1)
        let found = AgentProcesses.classify([agent, helper], rule: .claude, home: "/Users/a")
        let sightings = AgentProcessTable.sightings(
            [agent, helper], rule: .claude, found: found,
            resolve: { $0 == "/Users/a/tools/claude-helper.js" ? AgentProcesses.Resolved(path: $0, executable: false) : nil })
        #expect(sightings.map(\.paths) == [
            ["/Users/a/.local/share/claude/versions/2.1.326"], ["/usr/local/bin/node", "/Users/a/tools/claude-helper.js"],
        ])
        #expect(sightings.map(\.matched) == [true, false])
    }

    @Test func onTheRealDiskOnlyARuntimeRunningTheAgentsFileIsTheAgent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ks-match-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["pi", "claude", "bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let tool = root.appendingPathComponent("bin/pi")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let folder = root.path
        func run(_ pid: Int, _ arguments: [String], executable: String) -> TerminalProcess {
            TerminalProcess(
                pid: pid, parent: 1, tty: "/dev/ttys001", arguments: arguments, environment: [:], executable: executable, app: nil,
                directory: folder, startedAt: 1)
        }
        let processes = [
            run(1, ["vim", "pi"], executable: "/usr/bin/vim"),
            run(2, ["node", "pi"], executable: "/usr/local/bin/node"),
            run(3, ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "claude"], executable: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            run(4, ["less", tool.path], executable: "/usr/bin/less"),
            run(5, ["vim", tool.path], executable: "/usr/bin/vim"),
            run(6, ["node", tool.path], executable: "/usr/local/bin/node"),
        ]
        let resolve: (String) -> AgentProcesses.Resolved? = { AgentProcessTable.resolve($0, home: "/Users/nobody") }
        #expect(AgentProcesses.classify(processes, rule: .pi, home: "/Users/nobody", resolve: resolve).candidates.map(\.pid) == [6])
        #expect(AgentProcesses.classify(processes, rule: .claude, home: "/Users/nobody", resolve: resolve).candidates.isEmpty)
        #expect(AgentProcessTable.resolve(root.appendingPathComponent("pi").path, home: "/Users/nobody") == nil)
    }
}
