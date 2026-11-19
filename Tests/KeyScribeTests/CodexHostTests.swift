import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
@Suite(.serialized)
struct CodexHostTests {
    nonisolated static let one = "019a8b2c-1111-7abc-8def-0123456789ab"
    nonisolated static let two = "019a8b2c-2222-7abc-8def-0123456789ab"

    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var loaded: [String] = [one]
        var noticeBeforeRead: (notice: String, thread: String)?
        var threads: [String: String] = [one: thread(one, status: #"{"type":"idle"}"#, name: "fix the build")]
        var lastTurn = "completed"
        var clientAt = 0
        var renameFails = false
        var sentClient: String?
        var emptyReads = 0
        var steerRejects = false
        var agentSaid: String?
        var steeredAgainst: String?
        var inputs: [[String: Any]] = []

        static func thread(_ id: String, status: String, name: String? = nil, extra: String = "") -> String {
            let named = name.map { #","name":"\#($0)""# } ?? ""
            return #"{"id":"\#(id)","cwd":"/Users/me/app","status":\#(status),"createdAt":1700000000\#(named)\#(extra)}"#
        }

        func set(_ id: String, status: String) {
            lock.withLock { threads[id] = Self.thread(id, status: status) }
        }

        func reply(_ method: String, _ params: [String: Any]) -> FakeCodexDaemon.Reply {
            lock.withLock {
                switch method {
                case "thread/loaded/list":
                    let ids = loaded.map { "\"\($0)\"" }.joined(separator: ",")
                    return .result(#"{"data":[\#(ids)],"nextCursor":null}"#)
                case "thread/read":
                    guard let id = params["threadId"] as? String, let thread = threads[id] else { return .error(code: -32600, message: "no thread") }
                    if let (notice, stale) = noticeBeforeRead {
                        noticeBeforeRead = nil
                        return .resultAfter(notification: notice, result: #"{"thread":\#(stale)}"#)
                    }
                    return .result(#"{"thread":\#(thread)}"#)
                case "turn/steer":
                    steeredAgainst = params["expectedTurnId"] as? String
                    if steerRejects { return .error(code: -32600, message: "no active turn") }
                    sentClient = params["clientUserMessageId"] as? String
                    inputs = params["input"] as? [[String: Any]] ?? []
                    return .result(#"{"turnId":"turn-ours"}"#)
                case "turn/start":
                    sentClient = params["clientUserMessageId"] as? String
                    inputs = params["input"] as? [[String: Any]] ?? []
                    return .result(#"{"turn":{"id":"turn-ours","status":"inProgress","items":[]}}"#)
                case "thread/turns/list":
                    if emptyReads > 0 {
                        emptyReads -= 1
                        return .result(#"{"data":[{"id":"turn-ours","status":"inProgress","items":[]}],"nextCursor":null}"#)
                    }
                    let ids = (Array(repeating: "null", count: clientAt) + [sentClient.map { "\"\($0)\"" } ?? "null"])
                        .map { #"{"type":"userMessage","clientId":\#($0)}"# }.joined(separator: ",")
                        + (agentSaid.map { #",{"type":"agentMessage","text":"\#($0)"}"# } ?? "")
                    return .result(#"{"data":[{"id":"turn-ours","status":"\#(lastTurn)","items":[\#(ids)]}],"nextCursor":null}"#)
                case "thread/name/set":
                    return renameFails ? .error(code: -32600, message: "no") : .result("{}")
                default:
                    return .silent
                }
            }
        }
    }

    final class Changes: @unchecked Sendable {
        var all: [AgentHostChange] = []
    }

    private func rig(
        _ script: Script = Script(), front: (app: AgentHostApp, title: String)? = nil, panes: CodexHost.Panes? = nil, changes: Changes = Changes(),
        confirmFor: TimeInterval = 0.2, connect: CodexHost.Connect? = nil
    ) throws -> (CodexHost, FakeCodexDaemon, Script) {
        let daemon = try FakeCodexDaemon()
        daemon.answer { script.reply($0, $1) }
        try daemon.start()
        let home = daemon.home.path
        let host = CodexHost(
            enrolled: { [home] }, installed: { true }, connect: connect ?? CodexHost.connect, panes: panes, frontmost: { front },
            confirmEvery: 0.01, confirmFor: confirmFor)
        host.watch { changes.all.append($0) }
        return (host, daemon, script)
    }

    private static let working = #"{"type":"active","activeFlags":[]}"#
    private static let approving = #"{"type":"active","activeFlags":["waitingOnApproval"]}"#

    private func push(_ daemon: FakeCodexDaemon, _ status: String) {
        daemon.push(#"{"method":"thread/status/changed","params":{"threadId":"\#(Self.one)","status":\#(status)}}"#)
    }

    private func location(_ daemon: FakeCodexDaemon, _ id: String = one) -> AgentHostLocation {
        AgentHostLocation(host: "codex", instance: daemon.home.path, native: id)
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aScanListsTheDaemonsUserThreadsFiledUnderTheirCodexHome() async throws {
        let script = Script()
        script.loaded = [Self.one, Self.two, "auto-title"]
        script.threads[Self.two] = Script.thread(Self.two, status: #"{"type":"active","activeFlags":["waitingOnApproval"]}"#)
        script.threads["auto-title"] = Script.thread("auto-title", status: #"{"type":"idle"}"#, extra: #","ephemeral":true,"threadSource":"thread_title""#)
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        guard case .found(let sessions, let titles, _, _, let problem) = await host.scan() else {
            Issue.record("unreadable")
            return
        }
        #expect(problem == nil)
        #expect(sessions.map(\.id) == [Self.one, Self.two])
        #expect(sessions.map(\.state) == [.idle, .waitingApproval])
        #expect(sessions.map(\.host) == [location(daemon), location(daemon, Self.two)])
        #expect(titles[location(daemon).conversationKey] == "fix the build")
        #expect(sessions.allSatisfy { $0.explicitName == nil })
    }

    @Test func aDaemonThatIsNotRunningIsUnreadableNeverEmpty() async throws {
        let (host, daemon, _) = try rig()
        daemon.stop()
        guard case .unreadable(let why) = await host.scan() else {
            Issue.record("listed")
            return
        }
        #expect(why.contains("Codex"))
    }

    @Test func withNoCodexHomeEnrolledOrNoCodexInstalledTheHostIsOff() {
        #expect(!CodexHost(enrolled: { [] }, installed: { true }).isEnabled)
        #expect(!CodexHost(enrolled: { ["/tmp/x"] }, installed: { false }).isEnabled)
        #expect(CodexHost(enrolled: { ["/tmp/x"] }, installed: { true }).isEnabled)
    }

    @Test func anIdleThreadIsSentOneTurnCarryingOnlyTheTextAndItsOwnMessageId() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .accepted)
        let starts = daemon.received.filter { $0.method == "turn/start" }
        #expect(starts.count == 1)
        let params = starts.first?.params ?? [:]
        #expect(params["threadId"] as? String == Self.one)
        #expect(params["collaborationMode"] == nil)
        #expect(params.keys.sorted() == ["clientUserMessageId", "input", "threadId"])
        let input = params["input"] as? [[String: Any]]
        #expect(input?.first?["type"] as? String == "text")
        #expect(input?.first?["text"] as? String == "run the tests")
        #expect((script.sentClient ?? "").isEmpty == false)
    }

    @Test func aMessageTheTurnRecordsAMomentAfterItStartsIsStillSent() async throws {
        let script = Script()
        script.emptyReads = 3
        let (host, daemon, _) = try rig(script, confirmFor: 5)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .accepted)
    }

    @Test func aMessageTheTurnNeverRecordsIsUncertainAfterABoundedWait() async throws {
        let script = Script()
        script.emptyReads = 1000
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        let started = Date()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .uncertain)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(daemon.methods().filter { $0 == "thread/turns/list" }.count <= 21)
        #expect(daemon.methods().filter { $0 == "turn/start" }.count == 1)
    }

    @Test func textThatJoinedATurnTheUserJustStartedStillCountsAsSent() async throws {
        let script = Script()
        script.clientAt = 1
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .accepted)
    }

    @Test func aWorkingThreadIsSteeredIntoTheTurnThatIsRunning() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.lastTurn = "inProgress"
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("also check the docs", images: [], request: "r1", to: location(daemon)) == .accepted)
        #expect(script.steeredAgainst == "turn-ours")
        #expect(daemon.methods().filter { $0 == "turn/steer" }.count == 1)
        #expect(!daemon.methods().contains("turn/start"))
        let steer = daemon.received.first { $0.method == "turn/steer" }?.params ?? [:]
        #expect(steer["collaborationMode"] == nil)
    }

    @Test func aTurnThatEndedJustBeforeTheSteerGetsANewTurnInstead() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.lastTurn = "inProgress"
        script.steerRejects = true
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        script.set(Self.one, status: #"{"type":"idle"}"#)
        #expect(await host.deliver("also check the docs", images: [], request: "r1", to: location(daemon)) == .accepted)
        #expect(daemon.methods().filter { $0 == "turn/start" }.count == 1)
    }

    @Test func aRejectedSteerIntoATurnStillRunningIsHeldToTryAgainAndNotTakenForOurOwnPrompt() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.lastTurn = "inProgress"
        script.steerRejects = true
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("also check the docs", images: [], request: "r1", to: location(daemon)) == .queued)
        #expect(!daemon.methods().contains("turn/start"))
        let key = location(daemon).conversationKey
        host.observe(.turnStarted(session: key, turn: "u1", prompt: AgentPromptDigest.of("also check the docs")))
        #expect(changes.all.contains(.event(.typed(session: key))))
    }

    @Test func twoCallersReachingTheAppServerAtOnceShareOneConnection() async throws {
        final class Count: @unchecked Sendable { var connects = 0 }
        let count = Count()
        let (host, daemon, _) = try rig(connect: { home, notified, closed in
            count.connects += 1
            try? await Task.sleep(for: .milliseconds(200))
            return await CodexHost.connect(home: home, onNotification: notified, onClose: closed)
        })
        defer { daemon.stop() }
        async let scanned = host.scan()
        async let renamed = host.rename(location(daemon), to: "release prep")
        let (scan, rename) = await (scanned, renamed)
        guard case .found = scan else { Issue.record("scan failed: \(scan)"); return }
        #expect(rename)
        #expect(count.connects == 1)
    }

    @Test func aStatusChangeIsAppliedWithoutListingEveryThreadAgainButANewThreadIsListed() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        push(daemon, Self.working)
        try? await Task.sleep(for: .milliseconds(100))
        guard case .found(let sessions, _, _, _, _) = await host.scan() else { Issue.record("no listing"); return }
        #expect(sessions.first?.state == .working)
        #expect(daemon.methods().filter { $0 == "thread/loaded/list" }.count == 1)
        script.lock.withLock {
            script.loaded.append(Self.two)
            script.threads[Self.two] = Script.thread(Self.two, status: #"{"type":"idle"}"#)
        }
        daemon.push(#"{"method":"thread/started","params":{"thread":\#(Script.thread(Self.two, status: #"{"type":"idle"}"#))}}"#)
        try? await Task.sleep(for: .milliseconds(100))
        _ = await host.scan()
        #expect(daemon.methods().filter { $0 == "thread/loaded/list" }.count == 2)
    }

    @Test func aStatusChangeThatArrivesWhileTheListIsReadIsNotOverwrittenByThatList() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.noticeBeforeRead = (
            #"{"method":"thread/status/changed","params":{"threadId":"\#(Self.one)","status":\#(Self.working)}}"#,
            Script.thread(Self.one, status: #"{"type":"idle"}"#))
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        guard case .found(let sessions, _, _, _, _) = await host.scan() else { Issue.record("no listing"); return }
        #expect(sessions.first?.state == .working)
    }

    @Test func aConversationCodexClosedWhileASteerWasRefusedIsRefusedNotHeld() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.lastTurn = "inProgress"
        script.steerRejects = true
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        script.set(Self.one, status: #"{"type":"notLoaded"}"#)
        guard case .refused = await host.deliver("also check the docs", images: [], request: "r1", to: location(daemon)) else {
            Issue.record("a closed conversation was not refused")
            return
        }
    }

    @Test func aStatusChangeForAThreadNotYetListedListsAgain() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        script.lock.withLock {
            script.loaded.append(Self.two)
            script.threads[Self.two] = Script.thread(Self.two, status: Self.working)
        }
        daemon.push(#"{"method":"thread/status/changed","params":{"threadId":"\#(Self.two)","status":\#(Self.working)}}"#)
        try? await Task.sleep(for: .milliseconds(100))
        guard case .found(let sessions, _, _, _, _) = await host.scan() else { Issue.record("no listing"); return }
        #expect(sessions.count == 2)
    }

    @Test func pastedImagesTravelWithTheTextAsLocalImages() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(host.takesImages)
        #expect(await host.deliver("what is this", images: ["/tmp/a.png", "/tmp/b.png"], request: "r1", to: location(daemon)) == .accepted)
        #expect(script.inputs.map { $0["type"] as? String } == ["text", "localImage", "localImage"])
        #expect(script.inputs.compactMap { $0["path"] as? String } == ["/tmp/a.png", "/tmp/b.png"])
        #expect(script.inputs.first?["text"] as? String == "what is this")
    }

    @Test func aThreadWaitingOnTheUserSendsNothingAndLeavesTheMessageToTheHubsQueue() async throws {
        let script = Script()
        script.set(Self.one, status: Self.approving)
        let (host, daemon, _) = try rig(script)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(host.queuesInHub)
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .queued)
        #expect(!daemon.methods().contains("turn/steer"))
        #expect(!daemon.methods().contains("turn/start"))
    }

    @Test func aTurnTheUserStoppedIsReportedAsStoppedEvenWithoutTheHooks() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        script.lastTurn = "interrupted"
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        push(daemon, #"{"type":"idle"}"#)
        let stopped = AgentHostChange.event(.turnComplete(session: location(daemon).conversationKey, reason: "aborted", answer: "", turn: "turn-ours"))
        await eventually { changes.all.contains(stopped) }
        #expect(changes.all.contains(stopped))
    }

    @Test func aTurnThatEndedNormallyIsNotReportedAsStopped() async throws {
        let script = Script()
        script.set(Self.one, status: Self.working)
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        push(daemon, #"{"type":"idle"}"#)
        await eventually { daemon.methods().contains("thread/turns/list") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!changes.all.contains { if case .event(.turnComplete) = $0 { true } else { false } })
    }

    @Test func aPromptTheUserTypedIsReportedAsTypedAndOurOwnIsNot() async throws {
        let changes = Changes()
        let (host, daemon, _) = try rig(changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .accepted)
        let key = location(daemon).conversationKey
        host.observe(.turnStarted(session: key, turn: "u1", prompt: AgentPromptDigest.of("run the tests")))
        #expect(!changes.all.contains(.event(.typed(session: key))))
        host.observe(.turnStarted(session: key, turn: "u2", prompt: AgentPromptDigest.of("something typed")))
        #expect(changes.all.contains(.event(.typed(session: key))))
    }

    @Test func aDeliveryIsConfirmedLaterByItsOwnMessageId() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        #expect(await host.confirm(request: "r9", at: location(daemon)) == false)
        script.lock.withLock { script.sentClient = CodexHost.messageId("r9") }
        #expect(await host.confirm(request: "r9", at: location(daemon)) == true)
        #expect(await host.confirm(request: "r9", at: AgentHostLocation(host: "codex", instance: "/elsewhere", native: Self.one)) == nil)
    }

    @Test func aStatusChangeTellsTheHubAtOnceAndAnAnsweredApprovalClearsTheWait() async throws {
        let script = Script()
        script.set(Self.one, status: Self.approving)
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        push(daemon, Self.working)
        await eventually { changes.all.contains(.listing) }
        #expect(changes.all.contains(.listing))
        #expect(changes.all.contains(.event(.waiting(session: location(daemon).conversationKey, prompt: nil))))
    }

    @Test func anUnwatchedHostTellsTheHubNothingMore() async throws {
        let script = Script()
        script.set(Self.one, status: Self.approving)
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        host.unwatch()
        push(daemon, Self.working)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.all.isEmpty)
    }

    @Test func aPromptIsDescribedWithTheAgentsLastWordsWhileItIsStillOpen() async throws {
        let script = Script()
        script.set(Self.one, status: Self.approving)
        script.agentSaid = "I need to delete the build folder."
        let changes = Changes()
        let (host, daemon, _) = try rig(script, changes: changes)
        defer { daemon.stop() }
        _ = await host.scan()
        let asked = AgentPrompt(kind: "confirm", tool: "shell", detail: "rm -rf build")
        host.observe(.waiting(session: location(daemon).conversationKey, prompt: asked))
        var explained = asked
        explained.said = "I need to delete the build folder."
        await eventually { changes.all.contains(.event(.waiting(session: location(daemon).conversationKey, prompt: explained))) }
        #expect(changes.all.contains(.event(.waiting(session: location(daemon).conversationKey, prompt: explained))))
        let before = changes.all.count
        host.observe(.waiting(session: location(daemon).conversationKey, prompt: explained))
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.all.count == before)
    }

    @Test func eachThreadIsShownByTheOneTerminalProcessWhoseTitleCarriesItsId() async throws {
        let script = Script()
        script.loaded = [Self.one, Self.two]
        script.threads[Self.two] = Script.thread(Self.two, status: #"{"type":"idle"}"#)
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        let (host, daemon, _) = try rig(script, panes: { _ in
            reads.count += 1
            return HostPanes(panes: [
                HostPane(pid: 101, title: "⠋ app | 019a8b2c-1111-7abc-8def-01234..."), HostPane(pid: 102, title: "zsh"),
                HostPane(pid: 103, title: "app | 019a8b2c-2222-7abc-8def-01234..."), HostPane(pid: 104, title: "019a8b2c-2222-7abc-8def-01234..."),
            ])
        })
        defer { daemon.stop() }
        guard case .found(let sessions, _, _, _, _) = await host.scan() else {
            Issue.record("unreadable")
            return
        }
        #expect(sessions.first { $0.id == Self.one }?.pid == 101)
        #expect(sessions.first { $0.id == Self.two }?.pid == nil)
        _ = await host.scan()
        #expect(reads.count == 1)
    }

    @Test func aPaneWhoseTitleCouldNotBeReadKeepsItsLastKnownProcessAndIsReadAgainNextTime() async throws {
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        let (host, daemon, _) = try rig(panes: { _ in
            reads.count += 1
            return reads.count == 1
                ? HostPanes(panes: [HostPane(pid: 101, title: "⠋ app | 019a8b2c-1111-7abc-8def-01234...")])
                : HostPanes(panes: [], unread: [101])
        })
        defer { daemon.stop() }
        _ = await host.scan()
        try? await Task.sleep(for: .seconds(CodexHost.paneLifetime + 0.1))
        guard case .found(let sessions, _, _, _, _) = await host.scan() else { Issue.record("unreadable"); return }
        #expect(sessions.first?.pid == 101)
        _ = await host.scan()
        #expect(reads.count == 3)
    }

    @Test func aPromptTheUserJustTypedIsWaitedOutBeforeTheMessageIsSent() async throws {
        let (host, daemon, _) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        host.observe(.turnStarted(session: location(daemon).conversationKey, turn: "theirs", prompt: AgentPromptDigest.of("typed")))
        let began = Date()
        #expect(await host.deliver("run the tests", images: [], request: "r1", to: location(daemon)) == .accepted)
        #expect(Date().timeIntervalSince(began) >= CodexDelivery.foreignPromptSettle * 0.75)
        #expect(daemon.methods().filter { $0 == "turn/start" }.count == 1)
    }

    @Test func aThreadTheDaemonNoLongerHoldsIsRefused() async throws {
        let (host, daemon, _) = try rig()
        defer { daemon.stop() }
        _ = await host.scan()
        guard case .refused = await host.deliver("x", images: [], request: "r1", to: location(daemon, Self.two)) else {
            Issue.record("not refused")
            return
        }
        guard case .refused = await host.deliver("x", images: [], request: "r1", to: AgentHostLocation(host: "codex", instance: "/elsewhere", native: Self.one)) else {
            Issue.record("not refused")
            return
        }
        #expect(!daemon.methods().contains("turn/start"))
    }

    @Test func renamingSetsTheThreadNameAndReportsAFailure() async throws {
        let (host, daemon, script) = try rig()
        defer { daemon.stop() }
        #expect(await host.rename(location(daemon), to: "release prep"))
        let set = daemon.received.first { $0.method == "thread/name/set" }
        #expect(set?.params["threadId"] as? String == Self.one)
        #expect(set?.params["name"] as? String == "release prep")
        script.renameFails = true
        #expect(!(await host.rename(location(daemon), to: "again")))
    }

    @Test func theFrontWindowShowsTheThreadWhoseIdItsTitleCarries() async throws {
        let front = AgentHostApp(bundle: "com.example.terminal", pid: 42, name: "Terminal", window: "w1")
        let (host, daemon, _) = try rig(front: (front, "⠋ app | 019a8b2c-2222-7abc-8def-01234..."))
        defer { daemon.stop() }
        let shown = await host.front(among: [location(daemon), location(daemon, Self.two)], reported: nil, in: nil)
        #expect(shown == .shown(location(daemon, Self.two), in: front))
        #expect(await host.front(among: [location(daemon)], reported: nil, in: nil) == .unknown)
    }

    @Test func aWindowShowingAThreadsSessionFileIsNeverThatThread() async throws {
        let editor = AgentHostApp(bundle: "com.example.editor", pid: 43, name: "Editor", window: "w2")
        let (host, daemon, _) = try rig(front: (editor, "rollout-2026-11-18T12-00-00-019a8b2c-2222-7abc-8def-0123456789ab.jsonl"))
        defer { daemon.stop() }
        #expect(await host.front(among: [location(daemon), location(daemon, Self.two)], reported: nil, in: nil) == .unknown)
    }

    @Test func aCodexLinkedFromTheChatGPTAppIsPassedOverForTheCommandLineOne() {
        let links = ["/Users/me/bin/codex": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex"]
        #expect(!CodexInstall.accepts("/Users/me/bin/codex", resolve: { links[$0] ?? $0 }))
        #expect(!CodexInstall.accepts("/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex", resolve: { $0 }))
        #expect(CodexInstall.accepts("/opt/homebrew/bin/codex", resolve: { _ in "/opt/homebrew/Caskroom/codex/0.170.0/codex-aarch64-apple-darwin" }))
    }

    @Test func turnsAreReportedForThreadsInAnEnrolledHomeOnly() throws {
        let (host, daemon, _) = try rig()
        defer { daemon.stop() }
        #expect(host.reportsTurns(at: location(daemon)))
        #expect(!host.reportsTurns(at: AgentHostLocation(host: "codex", instance: "/elsewhere", native: Self.one)))
    }
}
