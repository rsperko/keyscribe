import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@Suite(.serialized)
struct CodexDaemonClientTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CodexNotification] = []
        private var closes = 0
        func append(_ item: CodexNotification) { lock.withLock { items.append(item) } }
        func closed() { lock.withLock { closes += 1 } }
        var all: [CodexNotification] { lock.withLock { items } }
        var closings: Int { lock.withLock { closes } }
    }

    private func client(_ daemon: FakeCodexDaemon, heard: Heard = Heard()) -> CodexDaemonClient {
        CodexDaemonClient(socketPath: daemon.socketPath, onNotification: { heard.append($0) }, onClose: { heard.closed() })
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func connectingInitializesWithTheExperimentalApiThenSaysInitialized() async throws {
        let daemon = try FakeCodexDaemon()
        try daemon.start()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        try await client.connect(timeout: 2)
        await eventually { daemon.received.count >= 2 }
        let calls = daemon.received
        #expect(calls.map(\.method) == ["initialize", "initialized"])
        let capabilities = calls.first?.params["capabilities"] as? [String: Any]
        #expect(capabilities?["experimentalApi"] as? Bool == true)
        #expect(calls.first?.params["collaborationMode"] == nil)
        #expect(client.isOpen)
    }

    @Test func aMissingSocketIsUnavailableAndNeverStartsADaemon() async throws {
        let daemon = try FakeCodexDaemon()
        defer { daemon.stop() }
        let client = client(daemon)
        await #expect(throws: CodexDaemonClient.Failure.unavailable) { try await client.connect(timeout: 1) }
        #expect(!FileManager.default.fileExists(atPath: daemon.socketPath))
        #expect(!client.isOpen)
    }

    @Test func aRefusedUpgradeIsUnavailable() async throws {
        let daemon = try FakeCodexDaemon()
        daemon.refuseUpgrade()
        try daemon.start()
        defer { daemon.stop() }
        await #expect(throws: CodexDaemonClient.Failure.unavailable) { try await client(daemon).connect(timeout: 1) }
    }

    @Test func aCallReturnsItsResultAndSendsItsParams() async throws {
        let daemon = try FakeCodexDaemon()
        daemon.answer { method, _ in method == "thread/loaded/list" ? .result(#"{"data":["t1"],"nextCursor":null}"#) : .silent }
        try daemon.start()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        try await client.connect(timeout: 2)
        let result = try await client.call("thread/loaded/list", ["limit": 50], timeout: 2)
        #expect(CodexDaemon.loadedThreads(result)?.ids == ["t1"])
        #expect(daemon.received.last?.params["limit"] as? Int == 50)
    }

    @Test func anErrorReplyIsRejectedWithItsMessage() async throws {
        let daemon = try FakeCodexDaemon()
        daemon.answer { _, _ in .error(code: -32600, message: "thread not found") }
        try daemon.start()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        try await client.connect(timeout: 2)
        await #expect(throws: CodexDaemonClient.Failure.rejected(code: -32600, message: "thread not found")) {
            try await client.call("thread/read", ["threadId": "t"], timeout: 2)
        }
    }

    @Test func aCallWithNoReplyTimesOutAndLeavesNothingWaiting() async throws {
        let daemon = try FakeCodexDaemon()
        daemon.answer { _, _ in .silent }
        try daemon.start()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        try await client.connect(timeout: 2)
        await #expect(throws: CodexDaemonClient.Failure.timedOut) { try await client.call("thread/read", ["threadId": "t"], timeout: 0.2) }
        #expect(client.waiting == 0)
    }

    @Test func notificationsReachTheListenerAndPingsAreAnswered() async throws {
        let daemon = try FakeCodexDaemon()
        try daemon.start()
        defer { daemon.stop() }
        let heard = Heard()
        let client = client(daemon, heard: heard)
        defer { client.close() }
        try await client.connect(timeout: 2)
        daemon.push(#"{"method":"thread/status/changed","params":{"threadId":"t1","status":{"type":"idle"}}}"#)
        daemon.ping()
        await eventually { heard.all.count == 1 && daemon.pongs == 1 }
        #expect(heard.all == [.statusChanged(threadId: "t1", status: .idle)])
        #expect(daemon.pongs == 1)
    }

    @Test func aRequestFromTheDaemonIsNeverAnswered() async throws {
        let daemon = try FakeCodexDaemon()
        try daemon.start()
        defer { daemon.stop() }
        let client = client(daemon)
        defer { client.close() }
        try await client.connect(timeout: 2)
        daemon.push(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t1"}}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(daemon.received.map(\.method) == ["initialize", "initialized"])
    }

    @Test func aDroppedConnectionFailsWaitingCallsAndIsReportedOnce() async throws {
        let daemon = try FakeCodexDaemon()
        daemon.answer { _, _ in .silent }
        try daemon.start()
        defer { daemon.stop() }
        let heard = Heard()
        let client = client(daemon, heard: heard)
        try await client.connect(timeout: 2)
        let waiting = Task { try await client.call("thread/read", ["threadId": "t"], timeout: 5) }
        await eventually { daemon.methods() == ["thread/read"] }
        daemon.dropClients()
        await #expect(throws: CodexDaemonClient.Failure.closed) { try await waiting.value }
        await eventually { heard.closings == 1 }
        client.close()
        #expect(heard.closings == 1)
        #expect(!client.isOpen)
        await #expect(throws: CodexDaemonClient.Failure.closed) { try await client.call("thread/read", ["threadId": "t"], timeout: 1) }
    }
}
