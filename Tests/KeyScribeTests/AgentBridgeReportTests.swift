import Darwin
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@Suite(.serialized)
struct AgentBridgeReportTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentEvent] = []
        private var decoded = 0
        func append(_ event: AgentEvent) { lock.withLock { items.append(event) } }
        func decoding() { lock.withLock { decoded += 1 } }
        var all: [AgentEvent] { lock.withLock { items } }
        var decodes: Int { lock.withLock { decoded } }
    }

    private func makeServer(
        decode: @escaping @Sendable (String, String, Data) -> AgentBridgeServer.Report,
        excludes: @escaping @Sendable (String) -> Bool = { _ in false },
        onNotify: @escaping @Sendable (AgentEvent, @escaping @Sendable (Bool) -> Void) -> Void = { $1(false) }
    ) throws -> (AgentBridgeServer, Recorder, URL) {
        let dir = URL(fileURLWithPath: "/tmp/ks-report-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let recorder = Recorder()
        let server = AgentBridgeServer(
            directory: dir, token: "secret", admits: { agent, installation in agent != "claude" && installation == "inst-1" },
            excludes: excludes, pollHold: 2, activeWindow: 0.5, onNotify: onNotify,
            onReport: { agent, installation, body in
                recorder.decoding()
                return decode(agent, installation, body)
            }
        ) {
            recorder.append($0)
        }
        try server.start()
        return (server, recorder, dir)
    }

    private func post(
        _ dir: URL, path: String = "/report", body: String = "{}", token: String = "secret", agent: String? = "codex",
        installation: String? = "inst-1"
    ) throws -> (Int, String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let socketPath = dir.appendingPathComponent("bridge.sock").path
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let headers = [agent.map { "X-KeyScribe-Agent: \($0)\r\n" }, installation.map { "X-KeyScribe-Installation: \($0)\r\n" }]
            .compactMap { $0 }.joined()
        let raw = "POST \(path) HTTP/1.1\r\nHost: ks\r\nAuthorization: Bearer \(token)\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = raw.withCString { write(fd, $0, strlen($0)) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
        }
        let text = String(decoding: response, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func settled(_ events: Recorder, count: Int) async {
        for _ in 0..<100 where events.all.count < count { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aReportFromAnEnrolledInstallationReachesTheAppFiledUnderItsAgentWithNoHello() async throws {
        let (server, events, dir) = try makeServer { _, _, _ in .events([.turnStarted(session: "t1@home", turn: "u1", prompt: "d1")]) }
        defer { server.stop() }
        let (status, body) = try post(dir, body: #"{"hook_event_name":"UserPromptSubmit"}"#)
        await settled(events, count: 1)
        #expect(status == 200)
        #expect(body == #"{"ok":true}"#)
        #expect(events.all == [.turnStarted(session: "codex:t1@home", turn: "u1", prompt: "d1")])
        #expect(!server.isLive(session: "codex:t1@home"))
    }

    @Test func theDecoderIsGivenTheAgentTheInstallationAndTheBodyAsSent() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var value: (String, String, String)?
        }
        let seen = Seen()
        let (server, _, dir) = try makeServer { agent, installation, body in
            seen.lock.withLock { seen.value = (agent, installation, String(decoding: body, as: UTF8.self)) }
            return .events([])
        }
        defer { server.stop() }
        #expect(try post(dir, body: #"{"prompt":"100% \"quoted\""}"#).0 == 200)
        let value = seen.lock.withLock { seen.value }
        #expect(value?.0 == "codex")
        #expect(value?.1 == "inst-1")
        #expect(value?.2 == #"{"prompt":"100% \"quoted\""}"#)
    }

    @Test func aReportWithTheWrongTokenIsRefusedBeforeItIsDecoded() throws {
        let (server, events, dir) = try makeServer { _, _, _ in .events([.title(session: "t", text: "x")]) }
        defer { server.stop() }
        #expect(try post(dir, token: "wrong").0 == 401)
        #expect(events.decodes == 0)
        #expect(events.all.isEmpty)
    }

    @Test func aReportFromAnInstallationTheBridgeDoesNotAdmitIsRefusedBeforeItIsDecoded() throws {
        let (server, events, dir) = try makeServer { _, _, _ in .events([.title(session: "t", text: "x")]) }
        defer { server.stop() }
        #expect(try post(dir, installation: "inst-2").0 == 403)
        #expect(try post(dir, agent: "claude").0 == 403)
        #expect(events.decodes == 0)
        #expect(events.all.isEmpty)
    }

    @Test func aReportMissingItsAgentOrInstallationIsMalformed() throws {
        let (server, events, dir) = try makeServer { _, _, _ in .events([.title(session: "t", text: "x")]) }
        defer { server.stop() }
        #expect(try post(dir, agent: nil).0 == 400)
        #expect(try post(dir, installation: nil).0 == 400)
        #expect(try post(dir, agent: "").0 == 400)
        #expect(events.decodes == 0)
    }

    @Test func aDecoderThatRefusesOrCannotReadTheBodyAnswersWithoutReachingTheApp() throws {
        let (refusing, refused, refusingDir) = try makeServer { _, _, _ in .refused }
        defer { refusing.stop() }
        #expect(try post(refusingDir).0 == 403)
        #expect(refused.all.isEmpty)
        let (unreadable, unread, unreadableDir) = try makeServer { _, _, _ in .malformed }
        defer { unreadable.stop() }
        #expect(try post(unreadableDir).0 == 400)
        #expect(unread.all.isEmpty)
    }

    @Test func aReportCanNeverSettleConfirmOrOpenAnything() async throws {
        let hello = AgentEvent.Hello(protocolVersion: AgentBridgeCodec.protocolVersion, agent: "codex", agentVersion: "", instance: "i", session: "t", pid: 1)
        let (server, events, dir) = try makeServer { _, _, _ in
            .events([
                .hello(hello), .ack(request: "r1"), .submitted(request: "r1", turn: "u1"), .refused(request: "r1", reason: "x"),
                .checked(request: "r1", check: "c", report: AgentDeliveryReport()), .focused(request: "r1"),
                .undelivered(request: "r1", reason: "expired", handedOff: false), .typed(session: "t"),
                .absorbed(session: "t", turn: "u1", prompt: "d"), .shown(session: "t", on: true), .title(session: "t", text: "name"),
                .turnComplete(session: "t", reason: "complete", answer: "done"),
            ])
        }
        defer { server.stop() }
        #expect(try post(dir).0 == 200)
        await settled(events, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.all == [.turnComplete(session: "codex:t", reason: "complete", answer: "done")])
    }

    @Test func everyReportKindAnAgentMaySendReachesTheApp() async throws {
        let (server, events, dir) = try makeServer { _, _, _ in
            .events([
                .turnStarted(session: "t", turn: "u1", prompt: "d"), .waiting(session: "t", prompt: AgentPrompt(kind: "confirm")),
                .turnComplete(session: "t", reason: "aborted", answer: ""),
            ])
        }
        defer { server.stop() }
        #expect(try post(dir).0 == 200)
        await settled(events, count: 3)
        #expect(events.all == [
            .turnStarted(session: "codex:t", turn: "u1", prompt: "d"), .waiting(session: "codex:t", prompt: AgentPrompt(kind: "confirm")),
            .turnComplete(session: "codex:t", reason: "aborted", answer: ""),
        ])
    }

    @Test func aReportForAnExcludedConversationIsAnsweredQuietlyAndDispatchesNothing() async throws {
        let (server, events, dir) = try makeServer(
            decode: { _, _, _ in .events([.turnComplete(session: "t", reason: "complete", answer: "secret reply")]) },
            excludes: { $0 == "codex:t" })
        defer { server.stop() }
        let (status, body) = try post(dir)
        try await Task.sleep(for: .milliseconds(100))
        #expect(status == 200)
        #expect(body == #"{"ok":true,"quiet":true}"#)
        #expect(events.all.isEmpty)
    }

    @Test func aNotifyReportIsAnsweredWithWhetherTheReplyWillBeSpoken() async throws {
        final class Asked: @unchecked Sendable {
            let lock = NSLock()
            var event: AgentEvent?
        }
        let asked = Asked()
        let (server, events, dir) = try makeServer(
            decode: { _, _, _ in .events([.notify(session: "t", turn: "u1", on: true)]) },
            onNotify: { event, answer in
                asked.lock.withLock { asked.event = event }
                answer(true)
            })
        defer { server.stop() }
        let (status, body) = try post(dir)
        #expect(status == 200)
        #expect(body == #"{"ok":true,"spoken":true}"#)
        #expect(asked.lock.withLock { asked.event } == .notify(session: "codex:t", turn: "u1", on: true))
        #expect(events.all.isEmpty)
    }

    @Test func aNotifyReportForAnExcludedConversationIsNeverSpoken() throws {
        let (server, _, dir) = try makeServer(
            decode: { _, _, _ in .events([.notify(session: "t", turn: "u1", on: true)]) }, excludes: { _ in true },
            onNotify: { _, answer in answer(true) })
        defer { server.stop() }
        #expect(try post(dir).1 == #"{"ok":true,"quiet":true}"#)
    }

    @Test func reportsLeaveNothingBehindToWakeFor() async throws {
        let (server, events, dir) = try makeServer { _, _, _ in .events([.turnStarted(session: "t", turn: "u1", prompt: "d")]) }
        defer { server.stop() }
        for _ in 0..<50 { #expect(try post(dir).0 == 200) }
        await settled(events, count: 50)
        #expect(server.nextWake == nil)
        #expect(!server.isLive(session: "codex:t"))
    }

    @Test func aReportDoesNotLetAPollOrAnEventFromTheSameSessionIn() throws {
        let (server, _, dir) = try makeServer { _, _, _ in .events([.turnStarted(session: "t", turn: "u1", prompt: "d")]) }
        defer { server.stop() }
        #expect(try post(dir).0 == 200)
        #expect(try post(dir, path: "/poll", body: #"{"session":"t","instance":"t","connection":"t"}"#).0 == 409)
        #expect(try post(dir, path: "/event", body: #"{"op":"title","session":"t","text":"x","instance":"t","connection":"t"}"#).0 == 409)
    }
}
