import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ToolEnvironmentTests {
    final class Shell: @unchecked Sendable {
        private let lock = NSLock()
        var now = Date(timeIntervalSince1970: 10_000)
        var replies: [(ToolRunEnd, String)] = []
        private(set) var calls: [[String]] = []
        private(set) var keptErrors: [Bool] = []

        func execute(_ argv: [String], _ timeout: TimeInterval, _ environment: [String: String], _ limit: Int, _ includeErrors: Bool) -> ToolCLI.Ran {
            lock.withLock {
                calls.append(argv)
                keptErrors.append(includeErrors)
                let (end, body) = replies.isEmpty ? (.exited(0), "") : replies.removeFirst()
                return ToolCLI.Ran(end: end, output: Data(body.utf8))
            }
        }
    }

    private static func answer(_ entries: [String], noise: String = "") -> String {
        noise + ShellEnvironment.begin("n") + entries.map { $0 + "\u{0}" }.joined() + ShellEnvironment.end("n") + noise
    }

    private func make(
        _ shell: Shell, path: String = "/usr/bin:/bin", login: String = "/bin/zsh", existing: Set<String> = []
    ) -> ToolEnvironment {
        ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": path], shell: login, execute: shell.execute, now: { shell.now }, makeNonce: { "n" },
            modified: { _ in nil }, wait: { _ in try? await Task.sleep(for: .seconds(3600)) }, isExecutable: { existing.contains($0) })
    }

    private func on(_ tools: ToolEnvironment, keys: Set<String> = ["CLAUDE_CONFIG_DIR"]) {
        tools.turnedOn(true, keys: keys)
    }

    @Test func nothingRunsWhileNoAgentIntegrationIsOn() async {
        let shell = Shell()
        let tools = make(shell)
        #expect(await tools.refresh(.settings) == false)
        #expect(shell.calls.isEmpty)
    }

    @Test func aMissRightAfterStartingWaitsSoLaunchNeverRunsTheShell() async {
        let shell = Shell()
        let tools = make(shell)
        on(tools)
        await tools.refresh(.miss)
        #expect(shell.calls.isEmpty)
        shell.now += ToolEnvironment.quietAfterStart
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin:/usr/bin"]))]
        #expect(await tools.refresh(.miss))
        #expect(shell.calls.count == 1)
    }

    @Test func theLoginShellsAnswerIsReadThroughNoise() async {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin:/usr/bin", "SECRET=x"], noise: "motd\n"))]
        let tools = make(shell)
        on(tools)
        #expect(await tools.refresh(.settings))
        #expect(tools.shellPath == ["/Users/a/.local/bin", "/usr/bin"])
        #expect(tools.state.environment?.values["SECRET"] == nil)
        #expect(shell.calls.first?.prefix(2) == ["/bin/zsh", "-ilc"])
    }

    @Test func aFailedInteractiveShellFallsBackToALoginShell() async {
        let shell = Shell()
        shell.replies = [(.timedOut(5), "half"), (.exited(0), Self.answer(["PATH=/opt/homebrew/bin"]))]
        let tools = make(shell)
        on(tools)
        await tools.refresh(.settings)
        #expect(shell.calls.map { $0[1] } == ["-ilc", "-lc"])
        #expect(tools.shellPath == ["/opt/homebrew/bin"])
    }

    @Test func aFailedRefreshKeepsTheLastGoodAnswerAndSaysWhy() async {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin"]))]
        let tools = make(shell)
        on(tools)
        await tools.refresh(.settings)
        shell.now += ToolEnvironment.settingsEvery
        shell.replies = [(.timedOut(5), ""), (.exited(1), "no markers here")]
        #expect(await tools.refresh(.settings) == false)
        #expect(tools.shellPath == ["/Users/a/.local/bin"])
        guard case .read(_, _, let failure?) = tools.state else {
            Issue.record("expected the kept answer with a failure")
            return
        }
        #expect(failure.contains("did not finish within 5 seconds"))
        #expect(failure.contains("printed no environment"))
    }

    @Test func aShellThatNeverAnswersIsAFailureNotAnEmptyPath() async {
        let shell = Shell()
        shell.replies = [(.timedOut(5), ""), (.signaled(9), "")]
        let tools = make(shell)
        on(tools)
        await tools.refresh(.settings)
        #expect(tools.shellPath == nil)
        guard case .failed(let why) = tools.state else {
            Issue.record("expected a failure")
            return
        }
        #expect(why.contains("signal 9"))
    }

    @Test func refreshesAreThrottled() async {
        let shell = Shell()
        let tools = make(shell)
        on(tools)
        await tools.refresh(.settings)
        await tools.refresh(.settings)
        #expect(shell.calls.count == 2)
        shell.now += ToolEnvironment.quietAfterStart
        await tools.refresh(.miss)
        #expect(shell.calls.count == 2)
        shell.now += ToolEnvironment.settingsEvery
        await tools.refresh(.settings)
        #expect(shell.calls.count == 4)
    }

    @Test func onlyThePathAndTheIntegrationsOwnKeysAreKeptFromTheFirstRead() async {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/usr/bin", "BB_DATA_DIR=/Users/a/.bb-work", "CLAUDE_CONFIG_DIR=/x", "TOKEN=t"]))]
        let tools = make(shell)
        tools.turnedOn(true, keys: ["BB_DATA_DIR"])
        await tools.refresh(.settings)
        #expect(tools.state.environment?.values == ["PATH": "/usr/bin", "BB_DATA_DIR": "/Users/a/.bb-work"])
        #expect(tools.folder("BB_DATA_DIR") == "/Users/a/.bb-work")
        #expect(shell.keptErrors == [false])
    }

    @Test func oneDeferredReadFollowsTheQuietPeriodAndTellsObservers() async throws {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin"]))]
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let seen = Seen()
        let tools = ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": "/usr/bin"], shell: "/bin/zsh", execute: shell.execute, now: { shell.now },
            makeNonce: { "n" }, modified: { _ in nil }, wait: { seconds in shell.now += seconds })
        let changed = AsyncStream<Void> { continuation in
            tools.observe {
                seen.lock.withLock { seen.count += 1 }
                continuation.yield()
            }
        }
        on(tools)
        for await _ in changed { break }
        #expect(tools.shellPath == ["/Users/a/.local/bin"])
        #expect(seen.lock.withLock { seen.count } == 1)
        #expect(shell.calls.count == 1)
    }

    @Test func theDeferredReadWaitsUntilNoTakeIsInProgress() async throws {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin"]))]
        final class Takes: @unchecked Sendable {
            let lock = NSLock()
            var busyFor = 3
            var asked = 0
            var probedWhileBusy = false
        }
        let takes = Takes()
        let tools = ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": "/usr/bin"], shell: "/bin/zsh",
            execute: { argv, timeout, environment, limit, errors in
                takes.lock.withLock { if takes.busyFor > 0 { takes.probedWhileBusy = true } }
                return shell.execute(argv, timeout, environment, limit, errors)
            },
            now: { shell.now }, makeNonce: { "n" }, modified: { _ in nil }, wait: { seconds in shell.now += seconds })
        tools.waitWhile {
            takes.lock.withLock {
                takes.asked += 1
                defer { takes.busyFor -= 1 }
                return takes.busyFor > 0
            }
        }
        let changed = AsyncStream<Void> { continuation in tools.observe { continuation.yield() } }
        on(tools)
        for await _ in changed { break }
        #expect(takes.lock.withLock { takes.asked } == 4)
        #expect(!takes.lock.withLock { takes.probedWhileBusy })
        #expect(tools.shellPath == ["/Users/a/.local/bin"])
    }

    @Test func turningOffCancelsTheDeferredRead() async throws {
        let shell = Shell()
        final class Gate: @unchecked Sendable { var release: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        let tools = ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": "/usr/bin"], shell: "/bin/zsh", execute: shell.execute, now: { shell.now },
            makeNonce: { "n" }, modified: { _ in nil }, wait: { seconds in
                await withCheckedContinuation { gate.release = $0 }
                shell.now += seconds
            })
        on(tools)
        while gate.release == nil { await Task.yield() }
        tools.turnedOn(false)
        gate.release?.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shell.calls.isEmpty)
    }

    @Test func aPlainShellIsRunOnlyAsALoginShell() async {
        let shell = Shell()
        let tools = make(shell, login: "/bin/sh")
        on(tools)
        await tools.refresh(.settings)
        #expect(shell.calls.map { $0[1] } == ["-lc"])
    }

    @Test func theShellsCopyOfAToolWinsOverTheOneTheAppsPathFindsFirst() async {
        let shell = Shell()
        shell.replies = [(.exited(0), Self.answer(["PATH=/Users/a/.local/bin:/opt/homebrew/bin"]))]
        let tools = make(shell, path: "/opt/homebrew/bin:/usr/bin", existing: ["/opt/homebrew/bin/claude", "/Users/a/.local/bin/claude"])
        #expect(tools.search(program: "claude", agent: "claude", setup: nil, chosen: nil, extra: []).tool?.path == "/opt/homebrew/bin/claude")
        on(tools)
        await tools.refresh(.settings)
        #expect(tools.search(program: "claude", agent: "claude", setup: nil, chosen: nil, extra: []).tool?.path == "/Users/a/.local/bin/claude")
    }

    @Test func aRunningConversationsCommandOfThatFolderComesFirst() {
        let tools = make(Shell(), existing: ["/nix/store/x/bin/claude", "/Users/a/.local/bin/claude"])
        tools.record(agent: "claude", candidates: [
            AgentCandidate(agent: "claude", pid: 1, startedAt: 5, cwd: "/", setup: "/Users/a/.claude-work", tool: "/nix/store/x/bin/claude"),
            AgentCandidate(agent: "claude", pid: 2, startedAt: 9, cwd: "/", setup: "/Users/a/.claude", tool: "/Users/a/.local/bin/claude"),
        ], sightings: [])
        #expect(tools.search(program: "claude", agent: "claude", setup: "/Users/a/.claude-work", chosen: nil, extra: []).tool
            == ToolSearch.Place(path: "/nix/store/x/bin/claude", source: .session))
        #expect(tools.search(program: "claude", agent: "claude", setup: "/Users/a/.claude", chosen: nil, extra: []).tool?.path
            == "/Users/a/.local/bin/claude")
    }

    @Test func theVersionCheckRunsWithTheToolsOwnFolderOnItsPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("helper-runtime")
        let tool = folder.appendingPathComponent("pi")
        try Data("#!/bin/sh\necho 1.5.0\n".utf8).write(to: helper)
        try Data("#!/bin/sh\nexec helper-runtime\n".utf8).write(to: tool)
        for file in [helper, tool] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let tools = ToolEnvironment(home: "/Users/a", appEnvironment: ["PATH": "/usr/bin:/bin"], shell: "/bin/zsh")
        #expect(await tools.check(tool: tool.path, agent: "pi") == .working("1.5.0"))
    }

    @Test func aWorkingVersionIsAskedOnceUntilTheToolChanges() async {
        let shell = Shell()
        final class Stamp: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1) }
        let stamp = Stamp()
        let tools = ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": "/usr/bin"], shell: "/bin/zsh", execute: shell.execute, now: { shell.now }, makeNonce: { "n" },
            modified: { _ in stamp.date })
        shell.replies = [(.exited(0), "1.5.0"), (.exited(0), "1.6.0")]
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .working("1.5.0"))
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .working("1.5.0"))
        stamp.date = Date(timeIntervalSince1970: 2)
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .working("1.6.0"))
        #expect(shell.calls.count == 2)
    }

    @Test func aFailingVersionIsRememberedUntilSettingsAsksAgain() async {
        let shell = Shell()
        let tools = make(shell)
        shell.replies = [(.timedOut(10), ""), (.exited(0), "1.5.0")]
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .timedOut(10))
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .timedOut(10))
        #expect(shell.calls.count == 1)
        tools.forgetFailedChecks()
        #expect(await tools.check(tool: "/x/pi", agent: "pi") == .working("1.5.0"))
        #expect(shell.keptErrors == [true, true])
    }

    @Test func whatAFailingToolPrintsOnItsErrorStreamIsKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("pi")
        try Data("#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let tools = ToolEnvironment(home: "/Users/a", appEnvironment: ["PATH": "/usr/bin:/bin"], shell: "/bin/zsh")
        #expect(await tools.check(tool: tool.path, agent: "pi") == .exited(127, "env: node: No such file or directory"))
    }

    @Test func aTimedOutRunTakesItsWholeProcessGroupDown() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("child.pid")
        let ran = ToolCLI.executeGrouped(
            ["/bin/sh", "-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo started; wait"], timeout: 1, environment: ["PATH": "/usr/bin:/bin"],
            includeErrors: false, limit: 1024)
        #expect(ran.end == .timedOut(1))
        #expect(ran.text.contains("started"))
        let child = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(child, 0) != 0
            if !gone { usleep(20_000) }
        }
        #expect(gone)
    }

    @Test func aGroupedRunReportsExitsSignalsAndCapsOutput() {
        let exited = ToolCLI.executeGrouped(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], timeout: 5, environment: [:], includeErrors: true, limit: 1024)
        #expect(exited.end == .exited(3))
        #expect(exited.text.contains("out") && exited.text.contains("err"))
        let quiet = ToolCLI.executeGrouped(["/bin/sh", "-c", "echo err >&2"], timeout: 5, environment: [:], includeErrors: false, limit: 1024)
        #expect(quiet.text.isEmpty)
        let killed = ToolCLI.executeGrouped(["/bin/sh", "-c", "kill -9 $$"], timeout: 5, environment: [:], includeErrors: false, limit: 1024)
        #expect(killed.end == .signaled(9))
        let capped = ToolCLI.executeGrouped(["/bin/sh", "-c", "yes | head -c 100000"], timeout: 5, environment: ["PATH": "/usr/bin:/bin"], includeErrors: false, limit: 1000)
        #expect(capped.output.count == 1000)
        #expect(ToolCLI.executeGrouped(["/no/such/tool"], timeout: 5, environment: [:], includeErrors: false, limit: 10).end == .couldNotStart("No such file or directory"))
    }

    @Test func sightingsOfRealSessionsComeBeforeLookAlikes() {
        let tools = make(Shell())
        let lookAlikes = (0..<ToolEnvironment.sightingLimit).map { DiscoveryReport.Sighting(pid: $0, name: "Claude Helper", paths: [], matched: false, setup: nil) }
        tools.record(agent: "claude", candidates: [], sightings: lookAlikes + [DiscoveryReport.Sighting(pid: 999, name: "claude", paths: [], matched: true, setup: "/s")])
        #expect(tools.sightings(agent: "claude").first?.pid == 999)
        #expect(tools.sightings(agent: "claude").count == ToolEnvironment.sightingLimit)
    }
}

@MainActor
struct SettingsShellReadTests {
    final class Hanging: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        func execute(_ argv: [String], _ timeout: TimeInterval, _ environment: [String: String], _ limit: Int, _ includeErrors: Bool) -> ToolCLI.Ran {
            release.wait()
            return ToolCLI.Ran(end: .timedOut(5), output: Data())
        }
    }

    @Test func openingSettingsNeverWaitsForTheLoginShell() async throws {
        let shell = Hanging()
        let tools = ToolEnvironment(
            home: "/Users/a", appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh", execute: shell.execute,
            wait: { _ in try? await Task.sleep(for: .seconds(3600)) }, isExecutable: { $0 == "/test-bin/claude" })
        tools.turnedOn(true, keys: [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-settings-shell-\(UUID().uuidString)")
        let connector = ClaudeConnector(
            run: { _, _ in (0, "[]") }, version: { _ in .working("2.1.326") }, tools: tools, agentsDir: dir,
            pluginName: "keyscribe-dev", surfaces: .builtIn, home: dir.appendingPathComponent("home"))
        let model = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: dir, connectors: [connector], tools: tools)
        await model.refresh()
        #expect(model.connectors[0].setups[0].state == .status(.notInstalled))
        #expect(tools.state == .notRun)
        shell.release.signal()
        shell.release.signal()
    }
}
