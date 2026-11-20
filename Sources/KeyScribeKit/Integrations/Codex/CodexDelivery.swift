import Foundation

public enum CodexDelivery {
    public static let foreignPromptSettle: TimeInterval = 0.2

    public enum HoldReason: Equatable, Sendable {
        case typedJustNow, waitingApproval, waitingQuestion, unknownState
    }

    public enum RefuseReason: Equatable, Sendable {
        case notOpen
    }

    public enum Precheck: Equatable, Sendable {
        case send
        case hold(HoldReason)
        case refuse(RefuseReason)
    }

    public struct Turn: Equatable, Sendable {
        public var id: String
        public var status: String?
        public var clientIds: [String?]

        public init(id: String, status: String?, clientIds: [String?]) {
            self.id = id
            self.status = status
            self.clientIds = clientIds
        }
    }

    public static func precheck(status: CodexThreadStatus?, lastForeignPrompt: Date?, now: Date) -> Precheck {
        switch status {
        case nil, .notLoaded?: return .refuse(.notOpen)
        case .systemError?, .unknown?: return .hold(.unknownState)
        case .active?:
            switch status?.liveState {
            case .waitingApproval?: return .hold(.waitingApproval)
            case .waitingQuestion?: return .hold(.waitingQuestion)
            case .working?: return .send
            default: return .hold(.unknownState)
            }
        case .idle?:
            if let lastForeignPrompt, now.timeIntervalSince(lastForeignPrompt) < foreignPromptSettle { return .hold(.typedJustNow) }
            return .send
        }
    }

    public static func startedTurn(_ result: Data) -> String? {
        CodexJSON.text((CodexJSON.object(result)?["turn"] as? [String: Any])?["id"])
    }

    public static func turns(_ result: Data) -> (turns: [Turn], nextCursor: String?)? {
        guard let page = CodexJSON.object(result), let listed = page["data"] as? [[String: Any]] else { return nil }
        var turns: [Turn] = []
        for turn in listed {
            guard let id = CodexJSON.text(turn["id"]) else { return nil }
            let messages = ((turn["items"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "userMessage" }
            turns.append(Turn(id: id, status: turn["status"] as? String, clientIds: messages.map { $0["clientId"] as? String }))
        }
        return (turns, page["nextCursor"] as? String)
    }

    public static func turn(in turns: [Turn], clientUserMessageId: String) -> String? {
        placement(in: turns, clientUserMessageId: clientUserMessageId)?.turn
    }

    public static func placement(in turns: [Turn], clientUserMessageId: String) -> (turn: String, position: Int)? {
        for turn in turns {
            if let position = turn.clientIds.firstIndex(of: clientUserMessageId) { return (turn.id, position) }
        }
        return nil
    }

    public static func lastAgentWords(_ result: Data) -> String? {
        guard let newest = (CodexJSON.object(result)?["data"] as? [[String: Any]])?.first,
              let message = ((newest["items"] as? [[String: Any]]) ?? []).last(where: { $0["type"] as? String == "agentMessage" })
        else { return nil }
        return CodexJSON.clean(message["text"], limit: CodexHookReport.detailLimit)
    }
}
