import Darwin
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@Suite(.serialized)
struct AgentBridgeServerTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentEvent] = []
        func append(_ event: AgentEvent) { lock.withLock { items.append(event) } }
        var all: [AgentEvent] { lock.withLock { items } }
    }

    final class Installation: @unchecked Sendable {
        private let lock = NSLock()
        private var id: String? = "inst-1"
        var current: String? {
            get { lock.withLock { id } }
            set { lock.withLock { id = newValue } }
        }
    }

    private func makeServer(
        pollHold: TimeInterval = 2, activeWindow: TimeInterval = 0.5, installation: Installation = Installation(),
        installationFor: (@Sendable (String) -> String?)? = nil, excludes: @escaping @Sendable (String) -> Bool = { _ in false },
        onHello: @escaping @Sendable (AgentEvent.Hello, @escaping @Sendable () -> Void) -> Void = { $1() },
        onNotify: @escaping @Sendable (AgentEvent, @escaping @Sendable (Bool) -> Void) -> Void = { $1(false) }
    ) throws -> (AgentBridgeServer, Events, URL) {
        let dir = URL(fileURLWithPath: "/tmp/ks-bridge-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let events = Events()
        let server = AgentBridgeServer(
            directory: dir, token: "secret",
            admits: { agent, offered in offered != nil && offered == (installationFor.map { $0(agent) } ?? installation.current) },
            excludes: excludes, pollHold: pollHold,
            activeWindow: activeWindow, onHello: onHello, onNotify: onNotify
        ) {
            events.append($0)
        }
        try server.start()
        return (server, events, dir)
    }

    private func request(_ dir: URL, path: String, body: String, token: String = "secret") throws -> (Int, String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let socketPath = dir.appendingPathComponent("bridge.sock").path
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let raw = "POST \(path) HTTP/1.1\r\nHost: ks\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
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
        let payload = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return (status, payload)
    }

    @discardableResult
    private func hello(
        _ dir: URL, session: String = "s1", instance: String = "i1", connection: String? = nil, installation: String = "inst-1", agent: String = "claude"
    ) throws -> Int {
        let body = #"{"op":"hello","protocol":3,"agent":"\#(agent)","agentVersion":"2.1.314","instance":"\#(instance)","session":"\#(session)","pid":1,"connection":"\#(connection ?? instance)","installation":"\#(installation)"}"#
        return try request(dir, path: "/event", body: body).0
    }

    private func readyHello(_ dir: URL, session: String = "s1", instance: String = "i1", connection: String? = nil, gap: Bool) throws -> Int {
        let body = #"{"op":"hello","protocol":3,"agent":"claude","instance":"\#(instance)","session":"\#(session)","pid":1,"features":["readiness"],"gap":\#(gap),"connection":"\#(connection ?? instance)","installation":"inst-1"}"#
        return try request(dir, path: "/event", body: body).0
    }

    private func poll(_ dir: URL, session: String = "s1", instance: String = "i1", connection: String? = nil) throws -> (Int, String) {
        try request(dir, path: "/poll", body: #"{"session":"\#(session)","instance":"\#(instance)","connection":"\#(connection ?? instance)"}"#)
    }

    @Test func aForgottenSessionMustSayHelloBeforeItsNextPollWhileOthersKeepPolling() async throws {
        let (server, _, dir) = try makeServer(pollHold: 5)
        defer { server.stop() }
        try hello(dir)
        try hello(dir, session: "s2", instance: "i2")
        server.forget(session: "claude:s1")
        server.enqueue(.submit(id: "r1", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        server.enqueue(.submit(id: "r2", expectedSession: "claude:s2", text: "y", expiresAt: .distantFuture), for: "claude:s2")
        #expect(try poll(dir).0 == 409)
        #expect(try poll(dir, session: "s2", instance: "i2").1.contains("r2"))
        #expect(try hello(dir) == 200)
        server.enqueue(.submit(id: "r3", expectedSession: "claude:s1", text: "z", expiresAt: .distantFuture), for: "claude:s1")
        let (status, body) = try poll(dir)
        #expect(status == 200)
        #expect(body.contains("r3"))
        #expect(!body.contains("r1"))
    }

    @Test func anExcludedConversationIsAnsweredQuietlyAndOnlyItsIdentityReachesTheApp() async throws {
        let (server, events, dir) = try makeServer(excludes: { $0 == "claude:s1" })
        defer { server.stop() }
        let body = #"{"op":"hello","protocol":3,"agent":"claude","instance":"i1","session":"s1","pid":1,"connection":"i1","installation":"inst-1","title":"secret plan","prompts":4,"environment":{"TMUX":"/t"},"waiting":{"title":"Allow?"}}"#
        let (status, answer) = try request(dir, path: "/event", body: body)
        #expect(status == 200)
        #expect(answer.contains(#""quiet":true"#))
        guard case .hello(let quietHello) = events.all.first else { Issue.record("no hello"); return }
        #expect(quietHello.session == "claude:s1")
        #expect(quietHello.quiet)
        #expect(quietHello.title == nil && quietHello.prompts == nil && quietHello.waiting == nil && quietHello.environment.isEmpty)
        let turn = #"{"op":"turnComplete","session":"s1","reason":"complete","answer":"private","instance":"i1","connection":"i1"}"#
        let (eventStatus, eventAnswer) = try request(dir, path: "/event", body: turn)
        #expect(eventStatus == 200)
        #expect(eventAnswer.contains(#""quiet":true"#))
        #expect(events.all.count == 1)
        try hello(dir, session: "s2", instance: "i2")
        #expect(events.all.contains { if case .hello(let other) = $0 { other.session == "claude:s2" && !other.quiet } else { false } })
    }

    @Test func quietAndAdmitTravelAsCommandsToTheConversation() async throws {
        let (server, _, dir) = try makeServer(pollHold: 5)
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.quiet(id: "q1", expectedSession: "claude:s1"), for: "claude:s1")
        let (status, body) = try poll(dir)
        #expect(status == 200)
        let frame = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
        #expect(frame?.first?["op"] as? String == "quiet")
        #expect(frame?.first?["expectedSession"] as? String == "s1")
    }

    @Test func retiringOneInstallationLeavesTheOthersConnected() async throws {
        let (server, events, dir) = try makeServer(pollHold: 5, installationFor: { $0 == "pi" ? "inst-pi" : "inst-1" })
        defer { server.stop() }
        try hello(dir)
        try hello(dir, session: "s2", instance: "i2", installation: "inst-pi", agent: "pi")
        server.enqueue(.submit(id: "r1", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        server.enqueue(.submit(id: "r2", expectedSession: "pi:s2", text: "y", expiresAt: .distantFuture), for: "pi:s2")
        #expect(try poll(dir, session: "s2", instance: "i2").1.contains("r2"))
        async let polled = Task.detached { try self.poll(dir, session: "s2", instance: "i2") }.value
        try await Task.sleep(for: .milliseconds(300))
        server.retire(installation: "inst-pi")
        let (status, body) = try await polled
        #expect(status == 200)
        let frame = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
        #expect(frame?.map { $0["op"] as? String } == ["retire"])
        #expect(events.all.contains(.undelivered(request: "r2", reason: "retired", handedOff: true)))
        #expect(try poll(dir, session: "s2", instance: "i2").0 == 409)
        let (first, body1) = try poll(dir)
        #expect(first == 200)
        #expect(body1.contains("r1"))
        #expect(server.isLive(session: "claude:s1"))
        #expect(!events.all.contains { if case .undelivered("r1", _, _) = $0 { true } else { false } })
    }

    @Test func aSessionIdSharedByTwoAgentsIsTwoSessions() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        #expect(try hello(dir) == 200)
        #expect(try hello(dir, instance: "i2", agent: "pi") == 200)
        #expect(server.isLive(session: "claude:s1"))
        #expect(server.isLive(session: "pi:s1"))
        #expect(events.all.compactMap { if case .hello(let hello) = $0 { hello.session } else { nil } } == ["claude:s1", "pi:s1"])
        server.enqueue(.submit(id: "r1", expectedSession: "pi:s1", text: "x", expiresAt: .distantFuture), for: "pi:s1")
        #expect(try poll(dir, session: "s1", instance: "i2").1.contains("r1"))
        #expect(try request(dir, path: "/event", body: #"{"op":"typed","session":"s1","instance":"i2","connection":"i2","prompts":1}"#).0 == 200)
        #expect(events.all.contains(.typed(session: "pi:s1", prompts: 1)))
    }

    @Test func aHelloTheBridgeRefusesNeverReachesTheHub() throws {
        let greeted = Events()
        let (server, _, dir) = try makeServer(onHello: { hello, done in greeted.append(.hello(hello)); done() })
        defer { server.stop() }
        #expect(try hello(dir, installation: "stale") == 403)
        #expect(greeted.all.isEmpty)
        #expect(try hello(dir) == 200)
        #expect(greeted.all.count == 1)
    }

    @Test func eachAgentIsCheckedAgainstItsOwnInstallation() throws {
        let (server, _, dir) = try makeServer(installationFor: { $0 == "claude" ? "inst-1" : nil })
        defer { server.stop() }
        #expect(try hello(dir) == 200)
        #expect(try hello(dir, session: "s2", instance: "i2", agent: "pi") == 403)
    }

    @Test func aWrongTokenIsRefused() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        let (status, _) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1","connection":"i1"}"#, token: "nope")
        #expect(status == 401)
    }

    @Test func theSocketAndItsFolderAreOwnerOnly() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        let sockMode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("bridge.sock").path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(sockMode == 0o600)
    }

    private func readiness(_ dir: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("ready.json").path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func aListeningBridgePublishesAnOwnerOnlyReadinessWithItsLaunch() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        let ready = try #require(readiness(dir))
        #expect(ready["protocol"] as? Int == AgentBridgeCodec.protocolVersion)
        #expect((ready["launch"] as? String)?.count ?? 0 >= 16)
        #expect(ready["launch"] as? String == server.launch)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ready.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try readyHello(dir, gap: false) == 200)
    }

    @Test func eachStartIsANewLaunch() throws {
        let (server, _, dir) = try makeServer()
        let first = try #require(readiness(dir)?["launch"] as? String)
        server.stop()
        try server.start()
        defer { server.stop() }
        let second = try #require(readiness(dir)?["launch"] as? String)
        #expect(first != second)
    }

    @Test func stoppingRemovesTheReadinessAndTheSocket() throws {
        let (server, _, dir) = try makeServer()
        server.stop()
        #expect(readiness(dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bridge.sock").path))
    }

    @Test func stoppingLeavesAReadinessItDoesNotOwn() throws {
        let (server, _, dir) = try makeServer()
        let other = Data(#"{"launch":"someone-else","protocol":1}"#.utf8)
        try other.write(to: dir.appendingPathComponent("ready.json"))
        server.stop()
        #expect(readiness(dir)?["launch"] as? String == "someone-else")
    }

    @Test func aFailedStartClearsAStaleReadiness() throws {
        let dir = URL(fileURLWithPath: "/tmp/ks-bridge-\(UUID().uuidString)-\(String(repeating: "x", count: 90))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"launch":"crashed","protocol":1}"#.utf8).write(to: dir.appendingPathComponent("ready.json"))
        let server = AgentBridgeServer(directory: dir, token: "secret", admits: { $1 == "inst-1" }) { _ in }
        #expect(throws: AgentBridgeServer.StartError.self) { try server.start() }
        #expect(readiness(dir) == nil)
        #expect(server.launch == nil)
    }

    @Test func eventsReachTheAppAndHelloRegistersTheInstance() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        #expect(events.all.first.map { if case .hello = $0 { true } else { false } } == true)
        #expect(server.isLive(session: "claude:s1"))
    }

    @Test func aRequestToReadTheReplyAloudIsAnsweredWithWhetherSpokenRepliesAreOn() throws {
        let asked = Events()
        let (server, events, dir) = try makeServer(onNotify: { event, answer in
            asked.append(event)
            answer(true)
        })
        defer { server.stop() }
        try hello(dir)
        let (status, body) = try request(dir, path: "/event", body: #"{"op":"notify","session":"s1","turn":"t1","on":true,"instance":"i1","connection":"i1"}"#)
        #expect(status == 200)
        #expect(body.contains(#""spoken":true"#))
        #expect(asked.all == [.notify(session: "claude:s1", turn: "t1", on: true)])
        #expect(!events.all.contains { if case .notify = $0 { true } else { false } })
    }

    @Test func aRequestFromADisconnectedConversationIsAnsweredQuietly() throws {
        let asked = Events()
        let (server, _, dir) = try makeServer(excludes: { $0 == "claude:s1" }, onNotify: { event, answer in
            asked.append(event)
            answer(true)
        })
        defer { server.stop() }
        try hello(dir)
        let (status, body) = try request(dir, path: "/event", body: #"{"op":"notify","session":"s1","turn":"t1","on":true,"instance":"i1","connection":"i1"}"#)
        #expect(status == 200)
        #expect(body.contains(#""quiet":true"#))
        #expect(asked.all.isEmpty)
    }

    @Test func aQueuedCommandIsReturnedByThePoll() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r1", expectedSession: "claude:s1", text: "run the tests", expiresAt: .distantFuture), for: "claude:s1")
        let (status, body) = try poll(dir)
        #expect(status == 200)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)) == [.submit(id: "r1", expectedSession: "s1", text: "run the tests", expiresAt: .distantFuture)])
    }

    @Test func aParkedPollIsAnsweredWhenACommandArrives() async throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        async let polled = Task.detached { try self.poll(dir) }.value
        try await Task.sleep(for: .milliseconds(300))
        server.enqueue(.status(id: "r2", expectedSession: "claude:s1", text: "Dictating"), for: "claude:s1")
        let (status, body) = try await polled
        #expect(status == 200)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)) == [.status(id: "r2", expectedSession: "s1", text: "Dictating")])
    }

    @Test func aParkedPollWithNothingToDoReturnsEmptyAfterTheHold() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.4)
        defer { server.stop() }
        try hello(dir)
        let started = Date()
        let (status, body) = try poll(dir)
        #expect(status == 200)
        #expect(body == "[]")
        #expect(Date().timeIntervalSince(started) >= 0.35)
    }

    private func settles(_ server: AgentBridgeServer) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, server.nextWake != nil { usleep(20_000) }
        return server.nextWake == nil
    }

    @Test func anIdleBridgeSchedulesNoWake() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir)
        #expect(server.nextWake == nil)
        _ = try poll(dir)
        #expect(settles(server))
    }

    @Test func aParkedPollWakesTheBridgeOnlyAtItsDeadline() async throws {
        let (server, _, dir) = try makeServer(pollHold: 5)
        defer { server.stop() }
        try hello(dir)
        let parkedAt = Date()
        async let polled = Task.detached { try self.poll(dir) }.value
        try await Task.sleep(for: .milliseconds(300))
        let wake = try #require(server.nextWake)
        #expect(wake.timeIntervalSince(parkedAt) > 4)
        server.enqueue(.status(id: "r1", expectedSession: "claude:s1", text: "Dictating"), for: "claude:s1")
        _ = try await polled
    }

    @Test func aCommandWaitingToBeCollectedKeepsTheBridgeTickingUntilItIsAcknowledged() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.status(id: "r1", expectedSession: "claude:s1", text: "Dictating"), for: "claude:s1")
        let waiting = try #require(server.nextWake)
        #expect(waiting.timeIntervalSinceNow < 0.5)
        _ = try poll(dir)
        #expect(server.nextWake != nil)
        let ack = #"{"op":"ack","request":"r1","instance":"i1","connection":"i1"}"#
        #expect(try request(dir, path: "/event", body: ack).0 == 200)
        #expect(settles(server))
    }

    @Test func aParkedPollKeepsItsConversationLiveBeyondTheActiveWindow() async throws {
        let (server, _, dir) = try makeServer(pollHold: 3, activeWindow: 0.5)
        defer { server.stop() }
        try hello(dir)
        async let polled = Task.detached { try self.poll(dir) }.value
        try await Task.sleep(for: .milliseconds(1200))
        #expect(server.isLive(session: "claude:s1"))
        server.enqueue(.status(id: "r1", expectedSession: "claude:s1", text: "Dictating"), for: "claude:s1")
        _ = try await polled
    }

    @Test func anUnacknowledgedCommandNeverReachesAnInstanceThatResumesAfterAGap() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r3", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        _ = try poll(dir)
        try hello(dir, instance: "i2")
        let (_, body) = try poll(dir, instance: "i2")
        #expect(body == "[]")
        #expect(events.all.contains(.undelivered(request: "r3", reason: "connectionGap", handedOff: true)))
    }

    @Test func aQueuedCommandIsWithdrawnForReviewWhenTheConnectorResumesAfterAGap() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        _ = try readyHello(dir, gap: false)
        server.enqueue(.submit(id: "r7", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        _ = try readyHello(dir, connection: "c2", gap: true)
        let (_, body) = try poll(dir, connection: "c2")
        #expect(body == "[]")
        let gap = AgentEvent.undelivered(request: "r7", reason: "connectionGap", handedOff: false)
        let all = events.all
        #expect(all.contains(gap))
        let helloIndex = all.lastIndex { if case .hello = $0 { true } else { false } }
        #expect(all.firstIndex(of: gap).map { $0 < (helloIndex ?? -1) } == true)
    }

    @Test func aFreshHelloKeepsWhatWasQueuedForTheSession() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        server.enqueue(.submit(id: "r8", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        _ = try readyHello(dir, gap: false)
        let (_, body) = try poll(dir)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)).map(\.id) == ["r8"])
    }

    @Test func theAppReconcilesBeforeAHelloIsRegisteredOrAnswered() async throws {
        final class Gate: @unchecked Sendable {
            let lock = NSLock()
            var release: (@Sendable () -> Void)?
        }
        let gate = Gate()
        let (server, _, dir) = try makeServer(onHello: { _, done in gate.lock.withLock { gate.release = done } })
        defer { server.stop() }
        async let answered = Task.detached { try self.readyHello(dir, gap: true) }.value
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, gate.lock.withLock({ gate.release == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!server.isLive(session: "claude:s1"))
        gate.lock.withLock { gate.release }?()
        #expect(try await answered == 200)
        #expect(server.isLive(session: "claude:s1"))
    }

    @Test func aHelloStillBeingPreparedWhenTheInstallationIsRemovedIsRefused() async throws {
        final class Gate: @unchecked Sendable {
            let lock = NSLock()
            var release: (@Sendable () -> Void)?
        }
        let gate = Gate()
        let installation = Installation()
        let (server, events, dir) = try makeServer(installation: installation, onHello: { _, done in gate.lock.withLock { gate.release = done } })
        defer { server.stop() }
        async let answered = Task.detached { try self.readyHello(dir, gap: false) }.value
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, gate.lock.withLock({ gate.release == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        installation.current = nil
        server.retire()
        gate.lock.withLock { gate.release }?()
        #expect(try await answered == 403)
        #expect(!server.isLive(session: "claude:s1"))
        #expect(!events.all.contains { if case .hello = $0 { true } else { false } })
    }

    @Test func aHelloReleasesThatInstancesOwnParkedPoll() async throws {
        let (server, _, dir) = try makeServer(pollHold: 5)
        defer { server.stop() }
        _ = try readyHello(dir, gap: false)
        let started = Date()
        async let polled = Task.detached { try self.poll(dir) }.value
        try await Task.sleep(for: .milliseconds(300))
        _ = try readyHello(dir, connection: "c2", gap: true)
        let (status, body) = try await polled
        #expect(status == 200)
        #expect(body == "[]")
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @MainActor
    @Test func aGapHelloDuringAnActiveTurnNeverReleasesTheQueuedTake() async throws {
        final class HubBox: @unchecked Sendable { weak var hub: AgentHub? }
        final class Registry: @unchecked Sendable { var status = "busy" }
        let box = HubBox()
        let registry = Registry()
        let dir = URL(fileURLWithPath: "/tmp/ks-bridge-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let server = AgentBridgeServer(
            directory: dir, token: "secret", admits: { $1 == "inst-1" }, pollHold: 0.3, activeWindow: 5,
            onHello: { hello, done in Task { @MainActor in box.hub?.prepare(for: hello); done() } }
        ) { event in Task { @MainActor in box.hub?.handle(event) } }
        try server.start()
        defer { server.stop() }
        let hub = AgentHub(transport: server, scan: {
            [ClaudeRegistryEntry(pid: 10, sessionId: "s1", cwd: "/src/keyscribe", name: nil, status: registry.status, waitingFor: nil)]
        }, scanDeadline: .seconds(30))
        box.hub = hub
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        let send = { (body: String) in try await Task.detached { try self.request(dir, path: "/event", body: body) }.value }
        let ready = #"{"op":"hello","protocol":3,"agent":"claude","instance":"i1","session":"s1","pid":1,"installation":"inst-1","features":["readiness"]"#

        _ = try await send(ready + #","idle":true,"gap":false,"connection":"c1"}"#)
        _ = try await Task.detached { try self.poll(dir, connection: "c1") }.value
        await hub.rescan()
        #expect(await hub.deliver("run the tests", to: "claude:s1") == .queued("keyscribe"))

        _ = try await send(ready + #","idle":false,"gap":true,"connection":"c2"}"#)
        registry.status = "idle"
        _ = try await send(#"{"op":"turnComplete","session":"s1","reason":"answer","instance":"i1","connection":"c2"}"#)
        for _ in 0..<20 { await Task.yield() }
        await hub.rescan()

        let (_, body) = try await Task.detached { try self.poll(dir, connection: "c2") }.value
        #expect(body == "[]")
        #expect(notices == [.kept("keyscribe", reason: .connectionGap)])
    }

    @Test func aGapInOneTerminalKeepsWhatWasAddressedToTheOther() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        _ = try readyHello(dir, instance: "left", gap: false)
        _ = try readyHello(dir, instance: "right", gap: false)
        server.enqueue(.submit(id: "r9", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1", instance: "left")
        _ = try readyHello(dir, instance: "right", connection: "right-2", gap: true)
        let (_, left) = try poll(dir, instance: "left")
        #expect(try AgentBridgeCodec.decodeCommands(Data(left.utf8)).map(\.id) == ["r9"])
        #expect(!events.all.contains(.undelivered(request: "r9", reason: "connectionGap", handedOff: false)))
    }

    @Test func anAcknowledgedCommandIsNotRedelivered() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r4", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        _ = try poll(dir)
        _ = try request(dir, path: "/event", body: #"{"op":"ack","request":"r4","instance":"i1","connection":"i1"}"#)
        try hello(dir, instance: "i2")
        let (_, body) = try poll(dir, instance: "i2")
        #expect(body == "[]")
    }

    @Test func aPollFromAnInstanceTheBridgeDoesNotKnowIsToldToRegister() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        let (status, _) = try poll(dir)
        #expect(status == 409)
        try hello(dir)
        let (after, _) = try poll(dir)
        #expect(after == 200)
    }

    @Test func aCommandForAnInstanceThatWentAwayIsRefusedToTheApp() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir, instance: "old")
        server.enqueue(.submit(id: "r6", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1", instance: "old")
        let deadline = Date().addingTimeInterval(3)
        let notSent = AgentEvent.undelivered(request: "r6", reason: "instanceGone", handedOff: false)
        while Date() < deadline, !events.all.contains(notSent) { usleep(50_000) }
        #expect(events.all.contains(notSent))
    }

    @Test func aCommandCanTargetOneOfTwoTerminalsSharingASession() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir, instance: "left")
        try hello(dir, instance: "right")
        server.enqueue(.submit(id: "r5", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1", instance: "left")
        let (_, right) = try poll(dir, instance: "right")
        #expect(right == "[]")
        let (_, left) = try poll(dir, instance: "left")
        #expect(try AgentBridgeCodec.decodeCommands(Data(left.utf8)).map(\.id) == ["r5"])
    }

    @Test func aHelloOnAnotherProtocolIsRejectedWithoutRegistering() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        let old = #"{"op":"hello","protocol":1,"agent":"claude","instance":"i1","session":"s1","pid":1,"connection":"c1"}"#
        #expect(try request(dir, path: "/event", body: old).0 == 426)
        let unbound = #"{"op":"hello","protocol":3,"agent":"claude","instance":"i1","session":"s1","pid":1,"installation":"inst-1"}"#
        #expect(try request(dir, path: "/event", body: unbound).0 == 400)
        #expect(events.all.isEmpty)
        #expect(!server.isLive(session: "claude:s1"))
        #expect(try poll(dir).0 == 409)
    }

    @Test func messagesFromASupersededConnectionNeverReachTheApp() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir, connection: "c1")
        try hello(dir, connection: "c2")
        let stale = #"{"op":"typed","session":"s1","prompts":1,"instance":"i1","connection":"c1"}"#
        #expect(try request(dir, path: "/event", body: stale).0 == 409)
        let anonymous = #"{"op":"typed","session":"s1","prompts":1}"#
        #expect(try request(dir, path: "/event", body: anonymous).0 == 409)
        #expect(try poll(dir, connection: "c1").0 == 409)
        #expect(!events.all.contains(.typed(session: "claude:s1", prompts: 1)))

        let current = #"{"op":"typed","session":"s1","prompts":2,"instance":"i1","connection":"c2"}"#
        #expect(try request(dir, path: "/event", body: current).0 == 200)
        #expect(events.all.contains(.typed(session: "claude:s1", prompts: 2)))
    }

    @Test func aCommandTheOldConnectionCollectedStaysUncertainEvenIfItsAckArrivesLate() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir, connection: "c1")
        server.enqueue(.submit(id: "r1", expectedSession: "claude:s1", text: "x", expiresAt: .distantFuture), for: "claude:s1")
        _ = try poll(dir, connection: "c1")
        _ = try readyHello(dir, connection: "c2", gap: false)
        #expect(events.all.contains(.undelivered(request: "r1", reason: "connectionGap", handedOff: true)))
        let late = #"{"op":"ack","request":"r1","instance":"i1","connection":"c1"}"#
        #expect(try request(dir, path: "/event", body: late).0 == 409)
        #expect(!events.all.contains(.ack(request: "r1")))
        #expect(try poll(dir, connection: "c2").1 == "[]")
    }

    @Test func aHelloFromAnotherOrARemovedInstallationIsRefusedWithoutRegistering() throws {
        let installation = Installation()
        let (server, events, dir) = try makeServer(installation: installation)
        defer { server.stop() }
        #expect(try hello(dir, installation: "inst-0") == 403)
        let unmarked = #"{"op":"hello","protocol":3,"agent":"claude","instance":"i1","session":"s1","pid":1,"connection":"c1"}"#
        #expect(try request(dir, path: "/event", body: unmarked).0 == 403)
        installation.current = nil
        #expect(try hello(dir) == 403)
        #expect(try poll(dir).0 == 409)
        #expect(events.all.isEmpty)
        installation.current = "inst-1"
        #expect(try hello(dir) == 200)
    }

    @Test func retiringAnswersWaitingPollsWithRetireAndWithdrawsEveryCommand() async throws {
        let (server, events, dir) = try makeServer(pollHold: 5)
        defer { server.stop() }
        try hello(dir)
        try hello(dir, session: "s2", instance: "i2")
        server.enqueue(.submit(id: "r2", expectedSession: "claude:s2", text: "x", expiresAt: .distantFuture), for: "claude:s2")
        async let polled = Task.detached { try self.poll(dir) }.value
        try await Task.sleep(for: .milliseconds(300))
        server.retire()
        let (status, body) = try await polled
        #expect(status == 200)
        let frame = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
        #expect(frame?.map { $0["op"] as? String } == ["retire"])
        #expect(events.all.contains(.undelivered(request: "r2", reason: "retired", handedOff: false)))
        #expect(try poll(dir, session: "s2", instance: "i2").0 == 409)
        #expect(!server.isLive(session: "claude:s1"))
    }

    @Test func aClientThatHangsUpBeforeTheBridgeAcceptsItDoesNotTakeTheAppDown() throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let answered = DispatchSemaphore(value: 0)
        let (server, _, dir) = try makeServer(onHello: { _, done in
            entered.signal()
            gate.wait()
            done()
        })
        defer { server.stop() }
        nonisolated(unsafe) var greeted = 0
        DispatchQueue.global().async {
            greeted = (try? self.hello(dir)) ?? -1
            answered.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        try hangUpAfterSending(dir, path: "/event", body: #"{"op":"explode"}"#)
        gate.signal()
        #expect(answered.wait(timeout: .now() + 10) == .success)
        #expect(greeted == 200)
        #expect(try request(dir, path: "/event", body: #"{"op":"explode"}"#).0 == 400)
    }

    private func hangUpAfterSending(_ dir: URL, path: String, body: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let socketPath = dir.appendingPathComponent("bridge.sock").path
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let raw = "POST \(path) HTTP/1.1\r\nHost: ks\r\nAuthorization: Bearer secret\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = raw.withCString { write(fd, $0, strlen($0)) }
    }

    @Test func malformedEventsAreRejectedWithoutReachingTheApp() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        let (status, _) = try request(dir, path: "/event", body: #"{"op":"explode"}"#)
        #expect(status == 400)
        #expect(events.all.isEmpty)
    }
}
