import Foundation

public enum CodexNotification: Equatable, Sendable {
    case statusChanged(threadId: String, status: CodexThreadStatus)
    case nameUpdated(threadId: String, name: String?)
    case started(CodexThread)
    case closed(threadId: String)
    case other(method: String)
}

public enum CodexDaemon {
    public enum RequestID: Hashable, Sendable {
        case number(Int)
        case text(String)
    }

    public enum Message: Equatable, Sendable {
        case response(id: Int, result: Data)
        case error(id: Int?, code: Int?, message: String?)
        case notification(CodexNotification)
        case serverRequest(id: RequestID, method: String)
        case unreadable
    }

    private struct Request<Params: Encodable>: Encodable {
        var id: Int
        var method: String
        var params: Params
    }

    public static func request<Params: Encodable>(id: Int, method: String, params: Params) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(id: id, method: method, params: params))
    }

    public static let initialized = Data(#"{"method":"initialized"}"#.utf8)

    public static func decode(_ data: Data) -> Message {
        guard let message = CodexJSON.object(data) else { return .unreadable }
        if let method = message["method"] as? String {
            guard message.keys.contains("id") else { return notification(method, message["params"]) }
            if let id = CodexJSON.int(message["id"]) { return .serverRequest(id: .number(id), method: method) }
            if let id = message["id"] as? String { return .serverRequest(id: .text(id), method: method) }
            return .unreadable
        }
        if let error = message["error"] as? [String: Any] {
            if !(message["id"] is NSNull), CodexJSON.int(message["id"]) == nil { return .unreadable }
            return .error(id: CodexJSON.int(message["id"]), code: CodexJSON.int(error["code"]), message: error["message"] as? String)
        }
        guard let id = CodexJSON.int(message["id"]), let value = message["result"], let result = CodexJSON.data(value) else { return .unreadable }
        return .response(id: id, result: result)
    }

    private static func notification(_ method: String, _ value: Any?) -> Message {
        let params = value as? [String: Any]
        let threadId = CodexJSON.text(params?["threadId"])
        switch method {
        case "thread/status/changed":
            guard let threadId, let status = params?["status"] as? [String: Any] else { return .unreadable }
            return .notification(.statusChanged(threadId: threadId, status: CodexThreadStatus(status)))
        case "thread/name/updated":
            guard let threadId else { return .unreadable }
            return .notification(.nameUpdated(threadId: threadId, name: params?["threadName"] as? String))
        case "thread/started":
            guard let thread = CodexThread(params?["thread"]) else { return .unreadable }
            return .notification(.started(thread))
        case "thread/closed":
            guard let threadId else { return .unreadable }
            return .notification(.closed(threadId: threadId))
        default:
            return .notification(.other(method: method))
        }
    }

    public static func loadedThreads(_ result: Data) -> (ids: [String], nextCursor: String?)? {
        guard let page = CodexJSON.object(result), let ids = page["data"] as? [String] else { return nil }
        return (ids, page["nextCursor"] as? String)
    }

    public static func thread(_ result: Data) -> CodexThread? {
        CodexThread(CodexJSON.object(result)?["thread"])
    }
}
