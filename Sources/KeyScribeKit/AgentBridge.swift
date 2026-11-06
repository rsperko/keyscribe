import Foundation

public enum AgentCommand: Equatable, Sendable {
    case submit(id: String, expectedSession: String, text: String)
    case abort(id: String, expectedSession: String, expectedTurn: String)
    case fill(id: String, expectedSession: String, text: String)
    case offerButton(id: String, expectedSession: String, text: String)
    case status(id: String, expectedSession: String, text: String)

    public var id: String {
        switch self {
        case .submit(let id, _, _), .abort(let id, _, _), .fill(let id, _, _), .offerButton(let id, _, _), .status(let id, _, _): id
        }
    }
}

public enum AgentEvent: Equatable, Sendable {
    public struct Hello: Equatable, Sendable {
        public var protocolVersion: Int
        public var agent: String
        public var agentVersion: String
        public var instance: String
        public var session: String
        public var pid: Int
        public init(protocolVersion: Int, agent: String, agentVersion: String, instance: String, session: String, pid: Int) {
            self.protocolVersion = protocolVersion
            self.agent = agent
            self.agentVersion = agentVersion
            self.instance = instance
            self.session = session
            self.pid = pid
        }
    }

    case hello(Hello)
    case ack(request: String)
    case submitted(request: String, turn: String)
    case refused(request: String, reason: String)
    case typed(session: String)
    case turnStarted(session: String, turn: String)
    case turnComplete(session: String, reason: String, answer: String)
    case undelivered(request: String, reason: String, handedOff: Bool)
}

public enum AgentBridgeCodec {
    public static let protocolVersion = 1
    public static let maxFrameBytes = 256 * 1024

    public enum CodecError: Error, Equatable { case tooLarge, unknownOp(String), malformed }

    private struct Wire: Codable {
        var op: String
        var id: String?
        var expectedSession: String?
        var expectedTurn: String?
        var text: String?
        var request: String?
        var turn: String?
        var reason: String?
        var session: String?
        var answer: String?
        var `protocol`: Int?
        var agent: String?
        var agentVersion: String?
        var instance: String?
        var pid: Int?
    }

    public static func encode(_ commands: [AgentCommand]) throws -> Data {
        try JSONEncoder().encode(commands.map(wire))
    }

    public static func decodeCommands(_ data: Data) throws -> [AgentCommand] {
        try JSONDecoder().decode([Wire].self, from: data).map(command)
    }

    public static func decodeEvent(_ data: Data) throws -> AgentEvent {
        guard data.count <= maxFrameBytes else { throw CodecError.tooLarge }
        let w = try JSONDecoder().decode(Wire.self, from: data)
        switch w.op {
        case "hello":
            guard let p = w.protocol, let agent = w.agent, let instance = w.instance, let session = w.session, let pid = w.pid
            else { throw CodecError.malformed }
            return .hello(.init(protocolVersion: p, agent: agent, agentVersion: w.agentVersion ?? "", instance: instance, session: session, pid: pid))
        case "ack":
            return .ack(request: try required(w.request))
        case "submitted":
            return .submitted(request: try required(w.request), turn: w.turn ?? "")
        case "refused":
            return .refused(request: try required(w.request), reason: w.reason ?? "")
        case "typed":
            return .typed(session: try required(w.session))
        case "turnStarted":
            return .turnStarted(session: try required(w.session), turn: try required(w.turn))
        case "turnComplete":
            return .turnComplete(session: try required(w.session), reason: w.reason ?? "", answer: w.answer ?? "")
        default:
            throw CodecError.unknownOp(w.op)
        }
    }

    private static func required(_ value: String?) throws -> String {
        guard let value else { throw CodecError.malformed }
        return value
    }

    private static func wire(_ c: AgentCommand) -> Wire {
        switch c {
        case .submit(let id, let s, let t): Wire(op: "submit", id: id, expectedSession: s, text: t)
        case .abort(let id, let s, let t): Wire(op: "abort", id: id, expectedSession: s, expectedTurn: t)
        case .fill(let id, let s, let t): Wire(op: "fill", id: id, expectedSession: s, text: t)
        case .offerButton(let id, let s, let t): Wire(op: "offerButton", id: id, expectedSession: s, text: t)
        case .status(let id, let s, let t): Wire(op: "status", id: id, expectedSession: s, text: t)
        }
    }

    private static func command(_ w: Wire) throws -> AgentCommand {
        guard let id = w.id, let s = w.expectedSession else { throw CodecError.malformed }
        switch w.op {
        case "submit": return .submit(id: id, expectedSession: s, text: try required(w.text))
        case "abort": return .abort(id: id, expectedSession: s, expectedTurn: try required(w.expectedTurn))
        case "fill": return .fill(id: id, expectedSession: s, text: try required(w.text))
        case "offerButton": return .offerButton(id: id, expectedSession: s, text: try required(w.text))
        case "status": return .status(id: id, expectedSession: s, text: try required(w.text))
        default: throw CodecError.unknownOp(w.op)
        }
    }
}

public struct AgentCommandQueue: Sendable {
    public static let ackTimeout: TimeInterval = 5
    public static let activeWindow: TimeInterval = 5
    public static var ambiguityGrace: TimeInterval { activeWindow * 2 }

    public enum Undeliverable: String, Sendable { case instanceGone, ambiguous }

    public struct Refusal: Equatable, Sendable {
        public var command: AgentCommand
        public var reason: Undeliverable
        public var handedOff: Bool
    }

    private struct Entry: Sendable {
        var command: AgentCommand
        var session: String
        var instance: String?
        var queuedAt: Date
        var handedOff = false
    }

    private struct InFlight: Sendable {
        var entry: Entry
        var deadline: Date
    }

    private struct Registration: Sendable {
        var session: String
        var since: Date
        var lastSeen: Date
    }

    private let window: TimeInterval
    private var pending: [Entry] = []
    private var inFlight: [InFlight] = []
    private var registrations: [String: Registration] = [:]

    public init(activeWindow: TimeInterval = Self.activeWindow) {
        window = activeWindow
    }

    public mutating func hello(session: String, instance: String, at now: Date) {
        registrations[instance] = Registration(session: session, since: now, lastSeen: now)
        requeue { $0.entry.session == session && $0.entry.instance == nil }
    }

    public mutating func touch(instance: String, at now: Date) {
        guard let seen = registrations[instance]?.lastSeen else { return }
        registrations[instance]?.lastSeen = max(seen, now)
    }

    public mutating func enqueue(_ command: AgentCommand, for session: String, instance: String? = nil, at now: Date) {
        pending.append(Entry(command: command, session: session, instance: instance, queuedAt: now))
    }

    public mutating func poll(session: String, instance: String, at now: Date) -> [AgentCommand]? {
        guard registrations[instance]?.session == session else { return nil }
        touch(instance: instance, at: now)
        let active = activeInstances(session: session, at: now)
        let sole = active == [instance]
        let mine: (Entry) -> Bool = { $0.session == session && ($0.instance == instance || ($0.instance == nil && sole)) }
        let ready = pending.filter(mine)
        pending.removeAll(where: mine)
        inFlight += ready.map { entry in
            var delivered = entry
            delivered.handedOff = true
            return InFlight(entry: delivered, deadline: now.addingTimeInterval(Self.ackTimeout))
        }
        return ready.map(\.command)
    }

    public mutating func ack(_ id: String) {
        inFlight.removeAll { $0.entry.command.id == id }
    }

    public mutating func tick(at now: Date) {
        requeue { $0.deadline < now }
    }

    public mutating func undeliverable(at now: Date) -> [Refusal] {
        let found = pending.enumerated().compactMap { index, entry in
            refusalReason(for: entry, at: now).map { (index, Refusal(command: entry.command, reason: $0, handedOff: entry.handedOff)) }
        }
        for (index, _) in found.reversed() { pending.remove(at: index) }
        return found.map(\.1)
    }

    private func refusalReason(for entry: Entry, at now: Date) -> Undeliverable? {
        let active = activeInstances(session: entry.session, at: now)
        if let target = entry.instance { return active.contains(target) ? nil : .instanceGone }
        return active.count > 1 && now.timeIntervalSince(entry.queuedAt) > window * 2 ? .ambiguous : nil
    }

    public mutating func withdraw(_ id: String) -> Bool {
        guard let index = pending.firstIndex(where: { $0.command.id == id && !$0.handedOff }) else { return false }
        pending.remove(at: index)
        return true
    }

    public func activeInstances(session: String, at now: Date) -> [String] {
        registrations
            .filter { $0.value.session == session && now.timeIntervalSince($0.value.lastSeen) <= window }
            .sorted { $0.value.since > $1.value.since }
            .map(\.key)
    }

    public func isLive(session: String, at now: Date) -> Bool {
        !activeInstances(session: session, at: now).isEmpty
    }

    private mutating func requeue(where shouldRequeue: (InFlight) -> Bool) {
        let expired = inFlight.filter(shouldRequeue)
        inFlight.removeAll(where: shouldRequeue)
        pending.insert(contentsOf: expired.map(\.entry), at: 0)
    }
}
