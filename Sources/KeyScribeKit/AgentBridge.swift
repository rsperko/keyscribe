import Foundation

public enum AgentCommand: Equatable, Sendable {
    case submit(id: String, expectedSession: String, text: String, expectedPrompts: Int? = nil, expiresAt: Date)
    case status(id: String, expectedSession: String, text: String)
    case focus(id: String, expectedSession: String, expiresAt: Date)
    case quiet(id: String, expectedSession: String)
    case admit(id: String, expectedSession: String)

    public var id: String {
        switch self {
        case .submit(let id, _, _, _, _), .status(let id, _, _): id
        case .focus(let id, _, _), .quiet(let id, _), .admit(let id, _): id
        }
    }

    public var expiresAt: Date? {
        switch self {
        case .focus(_, _, let expiresAt), .submit(_, _, _, _, let expiresAt): expiresAt
        case .status, .quiet, .admit: nil
        }
    }
}

public struct AgentPrompt: Equatable, Sendable, Codable {
    public var kind: String?
    public var title: String?
    public var tool: String?
    public var detail: String?
    public var said: String?
    public init(kind: String? = nil, title: String? = nil, tool: String? = nil, detail: String? = nil, said: String? = nil) {
        self.kind = kind
        self.title = title
        self.tool = tool
        self.detail = detail
        self.said = said
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
        public var features: [String]
        public var title: String?
        public var prompts: Int?
        public var idle: Bool?
        public var gap: Bool?
        public var connection: String?
        public var installation: String?
        public var environment: [String: String]
        public var cwd: String?
        public var waiting: AgentPrompt?
        public var version: String?
        public var quiet: Bool
        public var turn: String?
        public init(
            protocolVersion: Int, agent: String, agentVersion: String, instance: String, session: String, pid: Int,
            features: [String] = [], title: String? = nil, prompts: Int? = nil, idle: Bool? = nil, gap: Bool? = nil,
            connection: String? = nil, installation: String? = nil, environment: [String: String] = [:], cwd: String? = nil,
            waiting: AgentPrompt? = nil, version: String? = nil, quiet: Bool = false, turn: String? = nil
        ) {
            self.turn = turn
            self.version = version
            self.quiet = quiet
            self.waiting = waiting
            self.cwd = cwd
            self.environment = environment
            self.connection = connection
            self.installation = installation
            self.prompts = prompts
            self.idle = idle
            self.gap = gap
            self.features = features
            self.title = title
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
    case typed(session: String, prompts: Int? = nil)
    case turnStarted(session: String, turn: String)
    case turnComplete(session: String, reason: String, answer: String)
    case undelivered(request: String, reason: String, handedOff: Bool)
    case focused(request: String)
    case title(session: String, text: String)
    case waiting(session: String, prompt: AgentPrompt?)
    case notify(session: String, turn: String, on: Bool)
}

extension AgentEvent {
    public var session: String? {
        switch self {
        case .hello(let hello): hello.session
        case .typed(let session, _), .turnStarted(let session, _), .turnComplete(let session, _, _), .title(let session, _),
             .waiting(let session, _), .notify(let session, _, _): session
        case .ack, .submitted, .refused, .undelivered, .focused: nil
        }
    }

    public func renamingSession(_ rename: (String) -> String) -> AgentEvent {
        switch self {
        case .hello(var hello):
            hello.session = rename(hello.session)
            return .hello(hello)
        case .typed(let session, let prompts): return .typed(session: rename(session), prompts: prompts)
        case .turnStarted(let session, let turn): return .turnStarted(session: rename(session), turn: turn)
        case .turnComplete(let session, let reason, let answer): return .turnComplete(session: rename(session), reason: reason, answer: answer)
        case .title(let session, let text): return .title(session: rename(session), text: text)
        case .waiting(let session, let prompt): return .waiting(session: rename(session), prompt: prompt)
        case .notify(let session, let turn, let on): return .notify(session: rename(session), turn: turn, on: on)
        case .ack, .submitted, .refused, .undelivered, .focused: return self
        }
    }
}

extension AgentCommand {
    public func renamingSession(_ rename: (String) -> String) -> AgentCommand {
        switch self {
        case .submit(let id, let s, let text, let prompts, let expiresAt):
            .submit(id: id, expectedSession: rename(s), text: text, expectedPrompts: prompts, expiresAt: expiresAt)
        case .status(let id, let s, let text): .status(id: id, expectedSession: rename(s), text: text)
        case .focus(let id, let s, let expiresAt): .focus(id: id, expectedSession: rename(s), expiresAt: expiresAt)
        case .quiet(let id, let s): .quiet(id: id, expectedSession: rename(s))
        case .admit(let id, let s): .admit(id: id, expectedSession: rename(s))
        }
    }
}

extension AgentEvent.Hello {
    public var withoutContent: AgentEvent.Hello {
        var stripped = self
        stripped.title = nil
        stripped.prompts = nil
        stripped.waiting = nil
        stripped.environment = [:]
        stripped.turn = nil
        stripped.quiet = true
        return stripped
    }
}

extension AgentEvent.Hello {
    public var knownIdle: Bool { features.contains("readiness") && idle == true }
    public var reportsTurn: Bool { features.contains("notify") }
    public var resumesAfterGap: Bool { !features.contains("readiness") || gap != false }
}

public enum AgentBridgeCodec {
    public static let protocolVersion = 3
    public static let maxFrameBytes = 256 * 1024

    public enum CodecError: Error, Equatable { case tooLarge, unknownOp(String), malformed }

    public struct Envelope: Equatable, Sendable {
        public var instance: String?
        public var connection: String?
        public init(instance: String?, connection: String?) {
            self.instance = instance
            self.connection = connection
        }
    }

    private struct Wire: Codable {
        var op: String
        var id: String?
        var expectedSession: String?
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
        var features: [String]?
        var expiresAt: Double?
        var title: String?
        var prompts: Int?
        var expectedPrompts: Int?
        var gap: Bool?
        var idle: Bool?
        var connection: String?
        var installation: String?
        var environment: [String: String]?
        var cwd: String?
        var waiting: AgentPrompt?
        var version: String?
        var on: Bool?
    }

    public static func encode(_ commands: [AgentCommand]) throws -> Data {
        try JSONEncoder().encode(commands.map(wire))
    }

    public static func decodeCommands(_ data: Data) throws -> [AgentCommand] {
        try JSONDecoder().decode([Wire].self, from: data).map(command)
    }

    public static func decodeFrame(_ data: Data) throws -> (event: AgentEvent, envelope: Envelope) {
        guard data.count <= maxFrameBytes else { throw CodecError.tooLarge }
        let w = try JSONDecoder().decode(Wire.self, from: data)
        return (try event(w), Envelope(instance: w.instance, connection: w.connection))
    }

    public static func decodeEvent(_ data: Data) throws -> AgentEvent {
        try decodeFrame(data).event
    }

    private static func event(_ w: Wire) throws -> AgentEvent {
        switch w.op {
        case "hello":
            guard let p = w.protocol, let agent = w.agent, let instance = w.instance, let session = w.session, let pid = w.pid
            else { throw CodecError.malformed }
            return .hello(.init(
                protocolVersion: p, agent: agent, agentVersion: w.agentVersion ?? "", instance: instance, session: session, pid: pid,
                features: w.features ?? [], title: w.title, prompts: w.prompts, idle: w.idle, gap: w.gap, connection: w.connection,
                installation: w.installation, environment: w.environment ?? [:], cwd: w.cwd, waiting: w.waiting, version: w.version,
                turn: w.turn))
        case "ack":
            return .ack(request: try required(w.request))
        case "submitted":
            return .submitted(request: try required(w.request), turn: w.turn ?? "")
        case "refused":
            return .refused(request: try required(w.request), reason: w.reason ?? "")
        case "typed":
            return .typed(session: try required(w.session), prompts: w.prompts)
        case "focused":
            return .focused(request: try required(w.request))
        case "title":
            return .title(session: try required(w.session), text: try required(w.text))
        case "turnStarted":
            return .turnStarted(session: try required(w.session), turn: try required(w.turn))
        case "waiting":
            return .waiting(session: try required(w.session), prompt: w.waiting)
        case "notify":
            guard let on = w.on else { throw CodecError.malformed }
            return .notify(session: try required(w.session), turn: w.turn ?? "", on: on)
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
        case .submit(let id, let s, let t, let prompts, let expiresAt):
            Wire(op: "submit", id: id, expectedSession: s, text: t, expiresAt: milliseconds(expiresAt), expectedPrompts: prompts)
        case .status(let id, let s, let t): Wire(op: "status", id: id, expectedSession: s, text: t)
        case .focus(let id, let s, let expiresAt):
            Wire(op: "focus", id: id, expectedSession: s, expiresAt: milliseconds(expiresAt))
        case .quiet(let id, let s): Wire(op: "quiet", id: id, expectedSession: s)
        case .admit(let id, let s): Wire(op: "admit", id: id, expectedSession: s)
        }
    }

    private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    private static func date(_ milliseconds: Double?) throws -> Date {
        guard let milliseconds else { throw CodecError.malformed }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func command(_ w: Wire) throws -> AgentCommand {
        guard let id = w.id, let s = w.expectedSession else { throw CodecError.malformed }
        switch w.op {
        case "submit":
            return .submit(
                id: id, expectedSession: s, text: try required(w.text), expectedPrompts: w.expectedPrompts, expiresAt: try date(w.expiresAt))
        case "status": return .status(id: id, expectedSession: s, text: try required(w.text))
        case "focus": return .focus(id: id, expectedSession: s, expiresAt: try date(w.expiresAt))
        case "quiet": return .quiet(id: id, expectedSession: s)
        case "admit": return .admit(id: id, expectedSession: s)
        default: throw CodecError.unknownOp(w.op)
        }
    }
}

public struct AgentCommandQueue: Sendable {
    public static let ackTimeout: TimeInterval = 5
    public static let activeWindow: TimeInterval = 5
    public static var ambiguityGrace: TimeInterval { activeWindow * 2 }

    public enum Undeliverable: String, Sendable { case instanceGone, ambiguous, connectionGap, retired, expired }

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
        var holder: String?
        var connection: String?
    }

    private struct InFlight: Sendable {
        var entry: Entry
        var deadline: Date
    }

    private struct Registration: Sendable {
        var session: String
        var connection: String
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

    @discardableResult
    public mutating func hello(session: String, instance: String, connection: String, at now: Date) -> [Refusal] {
        registrations[instance] = Registration(session: session, connection: connection, since: now, lastSeen: now)
        let superseded: (Entry) -> Bool = { $0.holder == instance && $0.connection.map { $0 != connection } == true }
        let issued = inFlight.map(\.entry).filter(superseded) + pending.filter(superseded)
        inFlight.removeAll { superseded($0.entry) }
        pending.removeAll(where: superseded)
        return issued.map { Refusal(command: $0.command, reason: .connectionGap, handedOff: true) }
    }

    public mutating func retire() -> [Refusal] {
        let refusals = inFlight.map { Refusal(command: $0.entry.command, reason: .retired, handedOff: true) }
            + pending.map { Refusal(command: $0.command, reason: .retired, handedOff: $0.handedOff) }
        inFlight = []
        pending = []
        registrations = [:]
        return refusals
    }

    public mutating func retire(where retiring: (String) -> Bool) -> [Refusal] {
        let refusals = inFlight.filter { retiring($0.entry.session) }.map { Refusal(command: $0.entry.command, reason: .retired, handedOff: true) }
            + pending.filter { retiring($0.session) }.map { Refusal(command: $0.command, reason: .retired, handedOff: $0.handedOff) }
        inFlight.removeAll { retiring($0.entry.session) }
        pending.removeAll { retiring($0.session) }
        registrations = registrations.filter { !retiring($0.value.session) }
        return refusals
    }

    public mutating func retire(instances: Set<String>) -> [Refusal] {
        let sessions = Set(registrations.filter { instances.contains($0.key) }.map(\.value.session))
        let refusals = retire(where: sessions.contains)
        registrations = registrations.filter { !instances.contains($0.key) }
        return refusals
    }

    public mutating func forget(session: String) {
        registrations = registrations.filter { $0.value.session != session }
    }

    public func isCurrent(instance: String, connection: String) -> Bool {
        registrations[instance]?.connection == connection
    }

    public mutating func connectionGap(session: String, instance: String) -> [Refusal] {
        let affected: (Entry) -> Bool = { $0.session == session && ($0.instance == nil || $0.instance == instance) }
        let issued = inFlight.map(\.entry).filter(affected)
        let waiting = pending.filter(affected)
        inFlight.removeAll { affected($0.entry) }
        pending.removeAll(where: affected)
        return (issued + waiting).map { Refusal(command: $0.command, reason: .connectionGap, handedOff: $0.handedOff) }
    }

    public mutating func touch(instance: String, connection: String, at now: Date) {
        guard isCurrent(instance: instance, connection: connection), let seen = registrations[instance]?.lastSeen else { return }
        registrations[instance]?.lastSeen = max(seen, now)
    }

    public mutating func enqueue(_ command: AgentCommand, for session: String, instance: String? = nil, at now: Date) {
        pending.append(Entry(command: command, session: session, instance: instance, queuedAt: now))
    }

    public mutating func poll(session: String, instance: String, connection: String, at now: Date) -> [AgentCommand]? {
        guard registrations[instance]?.session == session, isCurrent(instance: instance, connection: connection) else { return nil }
        touch(instance: instance, connection: connection, at: now)
        let active = activeInstances(session: session, at: now)
        let sole = active == [instance]
        let mine: (Entry) -> Bool = { entry in
            guard entry.session == session, !Self.expired(entry, at: now) else { return false }
            if let pinned = entry.connection { return entry.holder == instance && pinned == connection }
            return entry.instance == instance || (entry.instance == nil && sole)
        }
        let ready = pending.filter(mine)
        pending.removeAll(where: mine)
        inFlight += ready.map { entry in
            var delivered = entry
            delivered.handedOff = true
            delivered.holder = instance
            delivered.connection = connection
            return InFlight(entry: delivered, deadline: now.addingTimeInterval(Self.ackTimeout))
        }
        return ready.map(\.command)
    }

    public mutating func ack(_ id: String, instance: String, connection: String) {
        inFlight.removeAll { $0.entry.command.id == id && $0.entry.holder == instance && $0.entry.connection == connection }
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

    private static func expired(_ entry: Entry, at now: Date) -> Bool {
        entry.command.expiresAt.map { $0 <= now } == true
    }

    private func refusalReason(for entry: Entry, at now: Date) -> Undeliverable? {
        if Self.expired(entry, at: now) { return .expired }
        let active = activeInstances(session: entry.session, at: now)
        if let holder = entry.holder, let pinned = entry.connection {
            if !isCurrent(instance: holder, connection: pinned) { return .connectionGap }
            return active.contains(holder) ? nil : .instanceGone
        }
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
