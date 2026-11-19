import Foundation

public enum OpencodeChange: Equatable, Sendable {
    case event(AgentEvent)
    case listing
}

public struct OpencodeTurns: Sendable {
    public static let answerLimit = 8192
    public static let detailLimit = 1000
    public static let titleLimit = 300
    public static let pendingLimit = 32

    private struct Request: Sendable {
        var id: String
        var prompt: AgentPrompt
    }

    private var turn: [String: String] = [:]
    private var answer: [String: String] = [:]
    private var open: [String: [Request]] = [:]
    private var pending: [(inbox: String, digest: String)] = []
    private var userTitled: Set<String> = []

    public init() {}

    public static func isOurs(_ message: String) -> Bool { message.hasPrefix(OpencodeMessages.messagePrefix) }

    public var running: [String: String] { turn }

    public func titledByUser(_ session: String) -> Bool { userTitled.contains(session) }

    public func asking(_ session: String) -> AgentPrompt? { open[session]?.last?.prompt }

    public mutating func reset(permissions: Data?, forms: Data?) {
        turn = [:]
        answer = [:]
        open = [:]
        pending = []
        for entry in permissions.flatMap(Self.listed) ?? [] {
            if let (session, request) = Self.permission(entry) { open[session, default: []].append(request) }
        }
        for entry in forms.flatMap(Self.listed) ?? [] {
            let state = (entry["state"] as? [String: Any])?["status"] as? String
            if state == nil || state == "pending", let (session, request) = Self.form(entry) { open[session, default: []].append(request) }
        }
    }

    public mutating func apply(_ data: Data, key: (String) -> String) -> [OpencodeChange] {
        guard let event = OpencodeJSON.object(data), let type = event["type"] as? String, let body = event["data"] as? [String: Any] else { return [] }
        switch type {
        case "session.renamed":
            if let session = OpencodeJSON.text(body["sessionID"]) {
                if event["location"] == nil { userTitled.insert(session) } else { userTitled.remove(session) }
            }
            return [.listing]
        case "session.created", "session.deleted", "session.archived", "session.moved":
            return [.listing]
        case "permission.asked":
            guard let (session, request) = Self.permission(body) else { return [] }
            return ask(session, request, key: key)
        case "form.created":
            guard let form = body["form"] as? [String: Any], let (session, request) = Self.form(form) else { return [] }
            return ask(session, request, key: key)
        case "permission.replied":
            return settle(body["sessionID"], request: body["requestID"], key: key)
        case "form.replied", "form.cancelled":
            return settle(body["sessionID"], request: body["id"], key: key)
        default:
            break
        }
        guard let session = OpencodeJSON.text(body["sessionID"]) else { return [] }
        switch type {
        case "session.execution.started":
            guard let id = OpencodeJSON.text(event["id"]) else { return [] }
            turn[session] = id
            answer[session] = nil
            return [.event(.turnStarted(session: key(session), turn: id))]
        case "session.text.ended":
            if let text = OpencodeJSON.text(body["text"]) { answer[session] = String(text.prefix(Self.answerLimit)) }
            return []
        case "session.execution.succeeded":
            return [.event(end(session, reason: "complete", key: key))]
        case "session.execution.interrupted":
            return [.event(end(session, reason: "aborted", key: key))]
        case "session.execution.failed":
            return [.event(end(session, reason: "error", key: key))]
        case "session.inbox.enqueued":
            guard let inbox = OpencodeJSON.text(body["inboxID"]), let item = body["item"] as? [String: Any], item["type"] as? String == "user"
            else { return [] }
            let text = (item["payload"] as? [String: Any])?["text"] as? String ?? ""
            pending.append((inbox, AgentPromptDigest.of(text)))
            if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
            return Self.isOurs(inbox) ? [] : [.event(.typed(session: key(session)))]
        case "session.inbox.delivered":
            guard let inbox = OpencodeJSON.text(body["inboxID"]), let index = pending.firstIndex(where: { $0.inbox == inbox }) else { return [] }
            let digest = pending.remove(at: index).digest
            guard let id = turn[session] else { return [] }
            return [.event(.turnStarted(session: key(session), turn: id, prompt: digest))]
        default:
            return []
        }
    }

    private mutating func end(_ session: String, reason: String, key: (String) -> String) -> AgentEvent {
        let said = reason == "complete" ? answer[session] ?? "" : ""
        let id = turn.removeValue(forKey: session)
        answer[session] = nil
        open[session] = nil
        return .turnComplete(session: key(session), reason: reason, answer: said, turn: id)
    }

    private mutating func ask(_ session: String, _ request: Request, key: (String) -> String) -> [OpencodeChange] {
        open[session, default: []].removeAll { $0.id == request.id }
        open[session, default: []].append(request)
        return [.event(.waiting(session: key(session), prompt: request.prompt))]
    }

    private mutating func settle(_ session: Any?, request: Any?, key: (String) -> String) -> [OpencodeChange] {
        guard let session = OpencodeJSON.text(session), let id = OpencodeJSON.text(request) else { return [] }
        open[session]?.removeAll { $0.id == id }
        if open[session]?.isEmpty == true { open[session] = nil }
        return [.event(.waiting(session: key(session), prompt: asking(session)))]
    }

    private static func listed(_ data: Data) -> [[String: Any]]? {
        (OpencodeJSON.object(data)?["data"] as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    private static func permission(_ body: [String: Any]) -> (String, Request)? {
        guard let id = OpencodeJSON.text(body["id"]), let session = OpencodeJSON.text(body["sessionID"]) else { return nil }
        let resources = (body["resources"] as? [Any])?.compactMap { $0 as? String }.joined(separator: "\n")
        let prompt = AgentPrompt(
            kind: "confirm", tool: clean(body["action"], limit: titleLimit), detail: clean(resources, limit: detailLimit))
        return (session, Request(id: id, prompt: prompt))
    }

    private static func form(_ form: [String: Any]) -> (String, Request)? {
        guard let id = OpencodeJSON.text(form["id"]), let session = OpencodeJSON.text(form["sessionID"]) else { return nil }
        var title = clean(form["title"], limit: titleLimit)
        if (form["metadata"] as? [String: Any])?["kind"] as? String == "question",
           let first = (form["fields"] as? [Any])?.first as? [String: Any] {
            title = clean(first["description"], limit: titleLimit) ?? clean(first["title"], limit: titleLimit) ?? title
        }
        return (session, Request(id: id, prompt: AgentPrompt(kind: "select", title: title)))
    }

    private static func clean(_ value: Any?, limit: Int) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }
}
