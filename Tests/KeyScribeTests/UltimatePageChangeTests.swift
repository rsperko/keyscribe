import Foundation
import Network
import Testing
@testable import KeyScribeApp

private final class FakeUltimateUI: @unchecked Sendable {
    typealias Rule = @Sendable ([String: Any]) -> (status: Int, state: [String: Any]?, error: String?)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-ultimate-ui")
    private let rule: Rule
    private let lock = NSLock()
    private var applied: [String: Any] = [:]

    init(_ rule: @escaping Rule) throws {
        self.rule = rule
        listener = try NWListener(using: .tcp, on: .any)
    }

    var state: [String: Any] { lock.withLock { applied } }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            read(connection, Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: Int(listener.port!.rawValue))
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

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] chunk, _, done, _ in
            let data = received + (chunk ?? Data())
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
                if !done { read(connection, data) }
                return
            }
            let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = data[split.upperBound...]
            guard body.count >= length else {
                if !done { read(connection, data) }
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]
            let answer = rule(json)
            if let state = answer.state { lock.withLock { applied.merge(state) { $1 } } }
            let reply = answer.error.map { "{\"error\":\"\($0)\"}" } ?? "{\"ok\":true,\"rev\":1}"
            let text = "HTTP/1.1 \(answer.status) X\r\nContent-Type: application/json\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n\(reply)"
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    static let current: Rule = { body in
        guard let ops = body["ops"] as? [[String: Any]] else { return (400, nil, "Invalid UI update") }
        var state: [String: Any] = [:]
        for op in ops {
            guard let key = op["key"] as? String else { return (400, nil, "Invalid UI key") }
            state[key] = op["value"]
        }
        return (200, state, nil)
    }

    static let older: Rule = { body in
        guard let set = (body["set"] ?? [String: Any]()) as? [String: Any] else { return (400, nil, "Invalid UI update") }
        return (200, set, nil)
    }
}

@Suite(.serialized)
struct UltimatePageChangeTests {
    @Test(arguments: ["current", "older"])
    func showingAConversationMovesThePageOnEveryUltimateTheAppSupports(_ version: String) async throws {
        let server = try FakeUltimateUI(version == "current" ? FakeUltimateUI.current : FakeUltimateUI.older)
        let port = try await server.start()
        defer { server.stop() }
        #expect(await UltimateHost.show(port: port, conversation: 61) == .changed)
        #expect(server.state["shell.surface"] as? String == "agent")
        #expect(server.state["shell.conversation"] as? Int == 61)
        #expect(server.state["ext.side-chat.front"] is NSNull, "a side chat left in front covers the conversation opened")
    }

    @Test func aPageChangeUltimateRefusesCarriesItsError() async throws {
        let server = try FakeUltimateUI { _ in (400, nil, "Invalid UI key") }
        let port = try await server.start()
        defer { server.stop() }
        #expect(await UltimateHost.show(port: port, conversation: 61) == .refused("Invalid UI key"))
    }

    @Test func aRefusalWithNoErrorTextNamesItsStatusAndALongOneIsCut() async throws {
        let blank = try FakeUltimateUI { _ in (400, nil, "  ") }
        let blankPort = try await blank.start()
        defer { blank.stop() }
        #expect(await UltimateHost.show(port: blankPort, conversation: 61) == .refused("HTTP 400"))
        let long = try FakeUltimateUI { _ in (400, nil, String(repeating: "x", count: 5000)) }
        let longPort = try await long.start()
        defer { long.stop() }
        guard case .refused(let why) = await UltimateHost.show(port: longPort, conversation: 61) else {
            Issue.record("a long refusal is still a refusal")
            return
        }
        #expect(why.count <= UltimateHost.refusalLimit)
    }
}
