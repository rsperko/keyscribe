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

    private func makeServer(pollHold: TimeInterval = 2, activeWindow: TimeInterval = 0.5) throws -> (AgentBridgeServer, Events, URL) {
        let dir = URL(fileURLWithPath: "/tmp/ks-bridge-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let events = Events()
        let server = AgentBridgeServer(directory: dir, token: "secret", pollHold: pollHold, activeWindow: activeWindow) { events.append($0) }
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

    private func hello(_ dir: URL, session: String = "s1", instance: String = "i1") throws {
        _ = try request(dir, path: "/event", body: #"{"op":"hello","protocol":1,"agent":"claude","agentVersion":"2.1.314","instance":"\#(instance)","session":"\#(session)","pid":1}"#)
    }

    @Test func aWrongTokenIsRefused() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        let (status, _) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#, token: "nope")
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

    @Test func eventsReachTheAppAndHelloRegistersTheInstance() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        #expect(events.all.first.map { if case .hello = $0 { true } else { false } } == true)
        #expect(server.isLive(session: "s1"))
    }

    @Test func aQueuedCommandIsReturnedByThePoll() throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r1", expectedSession: "s1", text: "run the tests"), for: "s1")
        let (status, body) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        #expect(status == 200)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)) == [.submit(id: "r1", expectedSession: "s1", text: "run the tests")])
    }

    @Test func aParkedPollIsAnsweredWhenACommandArrives() async throws {
        let (server, _, dir) = try makeServer()
        defer { server.stop() }
        try hello(dir)
        async let polled = Task.detached { try self.request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#) }.value
        try await Task.sleep(for: .milliseconds(300))
        server.enqueue(.abort(id: "r2", expectedSession: "s1", expectedTurn: "t1"), for: "s1")
        let (status, body) = try await polled
        #expect(status == 200)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)) == [.abort(id: "r2", expectedSession: "s1", expectedTurn: "t1")])
    }

    @Test func aParkedPollWithNothingToDoReturnsEmptyAfterTheHold() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.4)
        defer { server.stop() }
        try hello(dir)
        let started = Date()
        let (status, body) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        #expect(status == 200)
        #expect(body == "[]")
        #expect(Date().timeIntervalSince(started) >= 0.35)
    }

    @Test func anUnacknowledgedCommandReachesTheReloadedInstance() throws {
        let (server, _, dir) = try makeServer(pollHold: 2)
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r3", expectedSession: "s1", text: "x"), for: "s1")
        _ = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        try hello(dir, instance: "i2")
        let (_, body) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i2"}"#)
        #expect(try AgentBridgeCodec.decodeCommands(Data(body.utf8)).map(\.id) == ["r3"])
    }

    @Test func anAcknowledgedCommandIsNotRedelivered() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir)
        server.enqueue(.submit(id: "r4", expectedSession: "s1", text: "x"), for: "s1")
        _ = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        _ = try request(dir, path: "/event", body: #"{"op":"ack","request":"r4"}"#)
        try hello(dir, instance: "i2")
        let (_, body) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i2"}"#)
        #expect(body == "[]")
    }

    @Test func aPollFromAnInstanceTheBridgeDoesNotKnowIsToldToRegister() throws {
        let (server, _, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        let (status, _) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        #expect(status == 409)
        try hello(dir)
        let (after, _) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"i1"}"#)
        #expect(after == 200)
    }

    @Test func aCommandForAnInstanceThatWentAwayIsRefusedToTheApp() throws {
        let (server, events, dir) = try makeServer(pollHold: 0.3)
        defer { server.stop() }
        try hello(dir, instance: "old")
        server.enqueue(.submit(id: "r6", expectedSession: "s1", text: "x"), for: "s1", instance: "old")
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
        server.enqueue(.submit(id: "r5", expectedSession: "s1", text: "x"), for: "s1", instance: "left")
        let (_, right) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"right"}"#)
        #expect(right == "[]")
        let (_, left) = try request(dir, path: "/poll", body: #"{"session":"s1","instance":"left"}"#)
        #expect(try AgentBridgeCodec.decodeCommands(Data(left.utf8)).map(\.id) == ["r5"])
    }

    @Test func malformedEventsAreRejectedWithoutReachingTheApp() throws {
        let (server, events, dir) = try makeServer()
        defer { server.stop() }
        let (status, _) = try request(dir, path: "/event", body: #"{"op":"explode"}"#)
        #expect(status == 400)
        #expect(events.all.isEmpty)
    }
}
