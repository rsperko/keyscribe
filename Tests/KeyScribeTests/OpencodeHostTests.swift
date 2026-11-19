import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
@Suite(.serialized)
struct OpencodeHostTests {
    nonisolated static let service = OpencodeService(url: URL(string: "http://127.0.0.1:49374")!, password: "pw", pid: 4242, version: "2.3.2")
    nonisolated static let instance = "/Users/me/.local/state/opencode"

    final class FakeStream: OpencodeStream, @unchecked Sendable {
        let onEvent: @Sendable (Data) -> Void
        let onClose: @Sendable () -> Void
        var cancelled = false

        init(onEvent: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
            self.onEvent = onEvent
            self.onClose = onClose
        }

        func cancel() { cancelled = true }

        func emit(_ type: String, id: String = "evt_x", location: Bool = true, _ data: String) {
            let place = location ? #","location":{"directory":"/w"}"# : ""
            onEvent(Data(#"{"id":"\#(id)","type":"\#(type)"\#(place),"data":\#(data)}"#.utf8))
        }
    }

    final class FakeOpencode: OpencodeTransport, @unchecked Sendable {
        let lock = NSLock()
        var sessions = [session("ses_shown", "Fix the login bug"), session("ses_old", "Old idea"), session("ses_busy", "Busy work")]
        var active: [String] = ["ses_busy"]
        var permissions = "[]"
        var forms = "[]"
        var messages: [String: String] = [:]
        var inbox: [String: [String]] = [:]
        var promptStatus = 200
        var promptReply: String?
        var down = false
        var calls: [(method: String, path: String, body: [String: Any]?)] = []
        var streams: [FakeStream] = []

        static func session(_ id: String, _ title: String, extra: String = "") -> String {
            #"{"id":"\#(id)","projectID":"p","title":"\#(title)","time":{"created":1795104277032,"updated":1}\#(extra),"location":{"directory":"/work/app"}}"#
        }

        func call(_ method: String, _ path: String, body: Data?, to service: OpencodeService, timeout: TimeInterval) async -> OpencodeReply? {
            lock.withLock {
                calls.append((method, path, body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }))
                if down { return nil }
                let route = path.split(separator: "?").first.map(String.init) ?? path
                func ok(_ json: String) -> OpencodeReply { OpencodeReply(status: 200, body: Data(json.utf8)) }
                switch (method, route) {
                case ("GET", "/api/session"): return ok(#"{"data":[\#(sessions.joined(separator: ","))],"cursor":{}}"#)
                case ("GET", "/api/session/active"):
                    return ok(#"{"data":{\#(active.map { #""\#($0)":{"type":"running"}"# }.joined(separator: ","))}}"#)
                case ("GET", "/api/permission/request"): return ok(#"{"data":\#(permissions)}"#)
                case ("GET", "/api/form"): return ok(#"{"data":\#(forms)}"#)
                default: break
                }
                let parts = route.split(separator: "/").map(String.init)
                if method == "POST", parts.count == 4, parts[3] == "prompt" {
                    let id = (calls.last?.body?["id"] as? String) ?? ""
                    return OpencodeReply(status: promptStatus, body: Data((promptReply ?? #"{"data":{"id":"\#(id)","type":"user"}}"#).utf8))
                }
                if method == "PATCH", parts.count == 3 { return ok(#"{"data":{}}"#) }
                if method == "GET", parts.count == 5, parts[3] == "message" {
                    guard let found = messages[parts[4]] else { return OpencodeReply(status: 404, body: Data(#"{"_tag":"MessageNotFoundError"}"#.utf8)) }
                    return ok(#"{"data":\#(found)}"#)
                }
                if method == "GET", parts.count == 4, parts[3] == "message" { return ok(messages["list:" + parts[2]] ?? #"{"data":[]}"#) }
                if method == "GET", parts.count == 4, parts[3] == "inbox" {
                    return ok(#"{"data":[\#((inbox[parts[2]] ?? []).map { #"{"id":"\#($0)"}"# }.joined(separator: ","))]}"#)
                }
                return OpencodeReply(status: 404, body: Data(#"{"_tag":"NotFound"}"#.utf8))
            }
        }

        func stream(
            from service: OpencodeService, onEvent: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void
        ) -> any OpencodeStream {
            let stream = FakeStream(onEvent: onEvent, onClose: onClose)
            lock.withLock { streams.append(stream) }
            return stream
        }

        var lastPrompt: [String: Any]? { lock.withLock { calls.last { $0.path.hasSuffix("/prompt") }?.body } }
    }

    final class Changes {
        var all: [AgentHostChange] = []
        var events: [AgentEvent] { all.compactMap { if case .event(let event) = $0 { event } else { nil } } }
    }

    func host(
        _ fake: FakeOpencode, running: Bool = true, panes: [Int: String] = [4001: "OC | Fix the login bug"], showsTitle: Bool = true,
        front: (app: AgentHostApp, title: String)? = nil
    ) -> OpencodeHost {
        OpencodeHost(
            instance: Self.instance, service: { running ? Self.service : nil }, transport: fake, installed: { true },
            panes: { panes.map { OpencodePane(pid: $0.key, title: $0.value) } }, showsWindowTitle: { showsTitle }, frontmost: { front })
    }

    func location(_ id: String) -> AgentHostLocation { AgentHostLocation(host: "opencode", instance: Self.instance, native: id) }

    func sessions(_ scan: AgentHostScan) -> [AgentSession] {
        guard case .found(let sessions, _, _, _, _) = scan else { return [] }
        return sessions
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func withoutARunningServiceTheListIsUnreadable() async {
        let opencode = host(FakeOpencode(), running: false)
        guard case .unreadable(let why) = await opencode.scan() else { Issue.record("expected unreadable"); return }
        #expect(why == OpencodeHost.notRunning)
    }

    @Test func aServiceThatDoesNotAnswerIsUnreadableNotEmpty() async {
        let fake = FakeOpencode()
        fake.down = true
        guard case .unreadable = await host(fake).scan() else { Issue.record("expected unreadable"); return }
    }

    @Test func listsTheSessionsATerminalShowsOrThatWorkOrAskButNotOldIdleOnes() async {
        let fake = FakeOpencode()
        fake.forms = #"[{"id":"frm_1","sessionID":"ses_asks","title":"Pick","fields":[],"state":{"status":"pending"}}]"#
        fake.sessions.append(FakeOpencode.session("ses_asks", "Asking"))
        let listed = sessions(await host(fake).scan())
        #expect(Set(listed.map(\.id)) == ["ses_shown", "ses_busy", "ses_asks"])
        #expect(listed.first { $0.id == "ses_shown" }?.pid == 4001)
        #expect(listed.first { $0.id == "ses_shown" }?.state == .idle)
        #expect(listed.first { $0.id == "ses_busy" }?.state == .working)
        #expect(listed.first { $0.id == "ses_asks" }?.state == .waitingQuestion)
        #expect(listed.allSatisfy { $0.host?.instance == Self.instance && $0.cwd == "/work/app" })
    }

    @Test func subagentAndArchivedSessionsAreNeverListed() async {
        let fake = FakeOpencode()
        fake.sessions = [FakeOpencode.session("ses_child", "Child", extra: #","parentID":"ses_busy""#), FakeOpencode.session("ses_busy", "Busy")]
        fake.active = ["ses_child", "ses_busy"]
        #expect(sessions(await host(fake, panes: [:]).scan()).map(\.id) == ["ses_busy"])
    }

    @Test func aStaleWindowTitleNamesNothingWhileTheTUITitleIsOff() async {
        let listed = sessions(await host(FakeOpencode(), showsTitle: false).scan())
        #expect(listed.map(\.id) == ["ses_busy"])
        #expect(listed.allSatisfy { $0.pid == nil })
    }

    @Test func titlesOpencodeGeneratedReachAConversationOnlyAfterAVerb() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        opencode.watch { _ in }
        _ = await opencode.scan()
        await settle()
        fake.streams.last?.emit("session.renamed", location: false, #"{"sessionID":"ses_busy","title":"Busy work"}"#)
        await settle()
        guard case .found(_, let titles, let shownInstead, _, _) = await opencode.scan() else { Issue.record("no list"); return }
        #expect(titles == [location("ses_busy").conversationKey: "Busy work"])
        #expect(shownInstead == [location("ses_shown").conversationKey: "Fix the login bug"])
    }

    @Test func aDictationGoesAsASteerWithOurMessageIdAndImages() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        _ = await opencode.scan()
        let answer = await opencode.deliver("add tests", images: ["/tmp/shot.png"], request: "R1", to: location("ses_busy"))
        #expect(answer == .accepted)
        let body = fake.lastPrompt
        #expect(body?["id"] as? String == "msg_keyscribe_R1")
        #expect(body?["text"] as? String == "add tests")
        #expect(body?["delivery"] as? String == "steer")
        #expect((body?["files"] as? [[String: Any]])?.first?["uri"] as? String == "file:///tmp/shot.png")
        #expect(fake.calls.contains { $0.method == "POST" && $0.path == "/api/session/ses_busy/prompt" })
    }

    @Test func aDictationForASessionWaitingOnTheUserIsQueuedBehindThatPrompt() async {
        let fake = FakeOpencode()
        fake.permissions = #"[{"id":"per_1","sessionID":"ses_busy","action":"shell","resources":["rm -rf build"]}]"#
        let opencode = host(fake)
        _ = await opencode.scan()
        #expect(await opencode.deliver("go", images: [], request: "R2", to: location("ses_busy")) == .queued)
    }

    @Test func aMissingSessionIsRefusedAndAnUnansweredSendIsUncertain() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        fake.promptStatus = 404
        fake.promptReply = #"{"_tag":"SessionNotFoundError","message":"gone"}"#
        guard case .refused = await opencode.deliver("x", images: [], request: "R3", to: location("ses_gone")) else { Issue.record("not refused"); return }
        fake.down = true
        #expect(await opencode.deliver("x", images: [], request: "R4", to: location("ses_busy")) == .uncertain)
        fake.down = false
        fake.promptStatus = 500
        fake.promptReply = "{}"
        #expect(await opencode.deliver("x", images: [], request: "R5", to: location("ses_busy")) == .uncertain)
    }

    @Test func aLocationOfAnotherHostOrInstanceIsNeverSentTo() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        let other = AgentHostLocation(host: "opencode", instance: "/elsewhere", native: "ses_busy")
        guard case .refused = await opencode.deliver("x", images: [], request: "R6", to: other) else { Issue.record("not refused"); return }
        #expect(!fake.calls.contains { $0.path.hasSuffix("/prompt") })
    }

    @Test func noServiceRefusesTheSendWithoutCallingAnything() async {
        let fake = FakeOpencode()
        guard case .refused(let why) = await host(fake, running: false).deliver("x", images: [], request: "R7", to: location("ses_busy"))
        else { Issue.record("not refused"); return }
        #expect(why == OpencodeHost.notRunning)
        #expect(fake.calls.isEmpty)
    }

    @Test func confirmFindsOurMessageInTheConversationOrStillInItsInbox() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        fake.messages["msg_keyscribe_R8"] = #"{"id":"msg_keyscribe_R8","type":"user","text":"x"}"#
        #expect(await opencode.confirm(request: "R8", at: location("ses_busy")) == true)
        fake.inbox["ses_busy"] = ["msg_keyscribe_R9"]
        #expect(await opencode.confirm(request: "R9", at: location("ses_busy")) == true)
        #expect(await opencode.confirm(request: "R10", at: location("ses_busy")) == false)
        fake.down = true
        #expect(await opencode.confirm(request: "R10", at: location("ses_busy")) == nil)
    }

    @Test func watchingReportsTurnsRepliesAndPromptsAsTheyHappen() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        let changes = Changes()
        opencode.watch { changes.all.append($0) }
        _ = await opencode.scan()
        await settle()
        #expect(opencode.reportsTurns(at: location("ses_busy")))
        let stream = try! #require(fake.streams.last)
        stream.emit("session.inbox.enqueued", #"{"sessionID":"ses_shown","inboxID":"msg_keyscribe_R1","item":{"type":"user","payload":{"text":"fix it"}}}"#)
        stream.emit("session.execution.started", id: "evt_t", #"{"sessionID":"ses_shown"}"#)
        stream.emit("session.inbox.delivered", #"{"sessionID":"ses_shown","inboxID":"msg_keyscribe_R1"}"#)
        stream.emit("permission.asked", #"{"id":"per_1","sessionID":"ses_shown","action":"shell","resources":["make"]}"#)
        stream.emit("session.text.ended", #"{"sessionID":"ses_shown","text":"done"}"#)
        stream.emit("session.execution.succeeded", #"{"sessionID":"ses_shown"}"#)
        await settle()
        let key = location("ses_shown").conversationKey
        #expect(changes.events == [
            .turnStarted(session: key, turn: "evt_t"),
            .turnStarted(session: key, turn: "evt_t", prompt: AgentPromptDigest.of("fix it")),
            .waiting(session: key, prompt: AgentPrompt(kind: "confirm", tool: "shell", detail: "make")),
            .turnComplete(session: key, reason: "complete", answer: "done", turn: "evt_t"),
        ])
        #expect(changes.all.contains(.listing))
    }

    @Test func aTurnThatEndedWhileTheStreamWasDownIsEndedOnReconnect() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        let changes = Changes()
        opencode.watch { changes.all.append($0) }
        _ = await opencode.scan()
        await settle()
        fake.streams.last?.emit("session.execution.started", id: "evt_t", #"{"sessionID":"ses_busy"}"#)
        await settle()
        fake.streams.last?.onClose()
        await settle()
        fake.active = []
        fake.messages["list:ses_busy"] = #"{"data":[{"id":"m2","type":"idle","outcome":"succeeded"},{"id":"m1","type":"assistant","content":[{"type":"text","text":"all done"}]}]}"#
        _ = await opencode.scan()
        await settle()
        #expect(fake.streams.count == 2)
        #expect(changes.events.last == .turnComplete(session: location("ses_busy").conversationKey, reason: "complete", answer: "all done", turn: "evt_t"))
    }

    @Test func unwatchingClosesTheStreamAndStopsReportingTurns() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        opencode.watch { _ in }
        _ = await opencode.scan()
        await settle()
        opencode.unwatch()
        #expect(fake.streams.last?.cancelled == true)
        #expect(!opencode.reportsTurns(at: location("ses_busy")))
    }

    @Test func theConversationInFrontIsTheOneItsTerminalTitleShows() async {
        let fake = FakeOpencode()
        let app = AgentHostApp(bundle: "com.mitchellh.ghostty", pid: 77, name: "Ghostty")
        let opencode = host(fake, front: (app, "OC | Fix the login bug"))
        _ = await opencode.scan()
        let front = await opencode.front(among: [location("ses_shown"), location("ses_busy")], reported: nil, in: nil)
        #expect(front == .shown(location("ses_shown"), in: app))
        let home = host(fake, front: (app, "OpenCode"))
        _ = await home.scan()
        #expect(await home.front(among: [location("ses_shown")], reported: nil, in: nil) == .unknown)
    }

    @Test func renamingSetsTheSessionTitle() async {
        let fake = FakeOpencode()
        let opencode = host(fake)
        #expect(await opencode.rename(location("ses_busy"), to: "Login work"))
        let patch = fake.calls.last { $0.method == "PATCH" }
        #expect(patch?.path == "/api/session/ses_busy")
        #expect(patch?.body?["title"] as? String == "Login work")
    }
}
