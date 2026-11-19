import Foundation

public struct OpencodeTurnEnd: Equatable, Sendable {
    public var reason: String
    public var answer: String

    public init(reason: String, answer: String) {
        self.reason = reason
        self.answer = answer
    }
}

public enum OpencodeMessages {
    static let messagePrefix = "msg_keyscribe_"

    public static func messageId(request: String) -> String {
        messagePrefix + request.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func isMessage(_ data: Data, id: String) -> Bool {
        (OpencodeJSON.object(data)?["data"] as? [String: Any])?["id"] as? String == id
    }

    public static func lastTurn(_ data: Data) -> OpencodeTurnEnd? {
        guard let messages = (OpencodeJSON.object(data)?["data"] as? [Any])?.compactMap({ $0 as? [String: Any] }),
              let newest = messages.first, newest["type"] as? String == "idle"
        else { return nil }
        let reason: String
        switch newest["outcome"] as? String {
        case "succeeded": reason = "complete"
        case "interrupted": reason = "aborted"
        default: reason = "error"
        }
        guard reason == "complete" else { return OpencodeTurnEnd(reason: reason, answer: "") }
        let reply = messages.dropFirst().first { $0["type"] as? String != "idle" }
        guard let reply, reply["type"] as? String == "assistant" else { return OpencodeTurnEnd(reason: reason, answer: "") }
        let texts = (reply["content"] as? [Any])?.compactMap { part -> String? in
            guard let part = part as? [String: Any], part["type"] as? String == "text" else { return nil }
            return OpencodeJSON.text(part["text"])
        }
        return OpencodeTurnEnd(reason: reason, answer: String((texts?.last ?? "").prefix(OpencodeTurns.answerLimit)))
    }
}
