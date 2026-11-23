import Foundation
import Network
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

private final class SilentStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class SlowReplyServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "slow-reply-server")
    private let delay: TimeInterval

    init(delay: TimeInterval) throws {
        self.delay = delay
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [queue, delay] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                queue.asyncAfter(deadline: .now() + delay) {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

private func transport(session: URLSession, connectTimeout: Duration) -> ProviderTransport {
    var t = ProviderTransport(
        session: session, keyProvider: { _ in .absent }, tokenCommandRunner: { _ in "" },
        tokenCache: TokenCommandCache(), now: { Date() })
    t.connectTimeout = connectTimeout
    return t
}

private func post(to url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"model":"m"}"#.utf8)
    return request
}

private actor ConnectWaits {
    private(set) var all: [Duration] = []
    func record(_ wait: Duration) { all.append(wait) }
}

@Suite(.serialized)
struct ProviderConnectTimeoutTests {
    @Test func aServiceThatNeverConnectsGivesUpAtTheConfiguredConnectTimeout() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SilentStubProtocol.self]
        var t = transport(session: URLSession(configuration: config), connectTimeout: .milliseconds(300))
        let waits = ConnectWaits()
        t.sleep = { await waits.record($0) }
        let started = ContinuousClock.now
        var caught: Error?
        do { _ = try await t.send(post(to: URL(string: "http://192.0.2.1/v1/chat/completions")!)) } catch { caught = error }
        guard case .unreachable? = caught as? ProviderTransportError else {
            Issue.record("expected unreachable, got \(String(describing: caught))")
            return
        }
        #expect(await waits.all == [.milliseconds(300)])
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func givingUpBeforeTheSessionHasMadeItsTaskStillCancelsThatTask() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://192.0.2.1/")!)
        let watch = ConnectWatch(task.originalRequest?.url)
        watch.giveUpIfNotConnected()
        watch.urlSession(session, didCreateTask: task)
        #expect(task.state == .canceling || task.state == .completed)
        #expect(watch.gaveUp)
        task.cancel()
    }

    @Test func aConnectedServiceThatAnswersSlowlyIsNotCutOff() async throws {
        let server = try SlowReplyServer(delay: 1.0)
        let port = try await server.start()
        defer { server.stop() }
        let t = transport(session: URLSession(configuration: .ephemeral), connectTimeout: .milliseconds(300))
        let data = try await t.send(post(to: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!))
        #expect(data == Data("{}".utf8))
    }

    @Test func aRequestWithoutABodyIsLeftToTheSessionsOwnTimeout() async throws {
        let server = try SlowReplyServer(delay: 1.0)
        let port = try await server.start()
        defer { server.stop() }
        let t = transport(session: URLSession(configuration: .ephemeral), connectTimeout: .milliseconds(300))
        let data = try await t.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!))
        #expect(data == Data("{}".utf8))
    }

    @Test func theRewriteFallsBackWithAReasonThatSaysTheServiceDidNotConnect() {
        let reason = ProviderTransportError.unreachable.rewriteFailureReason
        #expect(reason == "The AI service didn't connect in time.")
        #expect(ProviderTransportError.unreachable.description == reason)
        #expect(!ProviderTransport.isTransient(ProviderTransportError.unreachable))
    }

    @Test func aServiceGetsThreeSecondsToConnect() {
        let t = ProviderTransport(
            session: URLSession(configuration: .ephemeral), keyProvider: { _ in .absent },
            tokenCommandRunner: { _ in "" }, tokenCache: TokenCommandCache(), now: { Date() })
        #expect(t.connectTimeout == .seconds(3))
    }
}
