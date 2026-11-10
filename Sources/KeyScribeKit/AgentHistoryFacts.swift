import Foundation

public enum AgentHistoryFacts {
    public static func spokenReplyEntry(id: String, mode: String, reply: HistoryEntry.SpokenReply) -> HistoryEntry {
        var entry = HistoryEntry(
            id: id, timestamp: reply.at, modeName: mode, heard: "", result: "", outcome: .command,
            cloudInvolved: false, redaction: false, contextCategories: [])
        entry.summary = "Reply from " + reply.conversation
        entry.spokenReply = reply
        return entry
    }

    public static func facts(
        address: AgentAddress, resolution: AgentRecipient.Resolution, frozen: AgentRecipient.Frozen?,
        conversations: [AgentConversation]
    ) -> [HistoryEntry.Fact] {
        let spoken = spokenAddress(address)
        var facts = [fact(command: command(address, resolution))]
        if let said = spoken.said { facts.append(.init(label: "Spoken address", value: said)) }
        if let closest = spoken.closest { facts.append(.init(label: "Closest name", value: closest)) }
        if let candidates = spoken.candidates { facts.append(.init(label: "Candidates", value: candidates.sorted().joined(separator: ", "))) }
        if let id = resolution.recipient {
            facts.append(.init(label: "Conversation", value: described(id, in: conversations)))
            facts.append(.init(label: "Chosen by", value: chosenBy(resolution, spoken: spoken.how)))
        } else {
            facts.append(.init(label: "Conversation", value: "None resolved"))
        }
        facts += defaultRecipient(frozen, in: conversations)
        return facts
    }

    public static func goBack(frozen: AgentRecipient.Frozen?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "Go back")] + defaultRecipient(frozen, in: conversations)
    }

    public static func repeatSummary(frozen: AgentRecipient.Frozen?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "Repeat that")] + defaultRecipient(frozen, in: conversations)
    }

    public static func rename(frozen: AgentRecipient.Frozen?, to name: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        var facts = [fact(command: "Rename")]
        facts.append(.init(label: "Conversation", value: frozen.map { described($0.id, in: conversations) } ?? "None resolved"))
        if let name { facts.append(.init(label: "New name", value: name)) }
        if let frozen {
            facts.append(.init(label: "Chosen by", value: chosenBy(.deliver(id: frozen.id, body: "", source: frozen.source), spoken: nil)))
        }
        return facts
    }

    public static func status(
        address: AgentAddress?, resolution: AgentRecipient.Resolution, frozen: AgentRecipient.Frozen?, conversations: [AgentConversation]
    ) -> [HistoryEntry.Fact] {
        let recorded = facts(address: address ?? .none(body: ""), resolution: resolution, frozen: frozen, conversations: conversations)
        return [fact(command: "Check status")] + recorded.dropFirst().filter { $0.label != "Default recipient" }
    }

    public static func whoNeedsMe() -> [HistoryEntry.Fact] {
        [fact(command: "Who needs me")]
    }

    private static func described(_ id: String, in conversations: [AgentConversation]) -> String {
        let conversation = conversations.first { $0.id == id }
        return conversation.map { "\($0.handle) \u{00B7} \($0.agent) \u{00B7} \(AgentSessionID.native(id))" } ?? AgentSessionID.native(id)
    }

    private static func fact(command: String) -> HistoryEntry.Fact {
        HistoryEntry.Fact(label: "Command", value: command)
    }

    private static func defaultRecipient(_ frozen: AgentRecipient.Frozen?, in conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        guard let frozen else { return [] }
        let handle = conversations.first { $0.id == frozen.id }?.handle ?? frozen.id
        return [.init(label: "Default recipient", value: handle)]
    }

    private static func command(_ address: AgentAddress, _ resolution: AgentRecipient.Resolution) -> String {
        if case .open = address { return "Open" }
        if case .select = resolution { return "Choose recipient" }
        return "Send message"
    }

    private struct Spoken {
        var said: String?
        var how: String?
        var closest: String?
        var candidates: [String]?
    }

    private static func spokenAddress(_ address: AgentAddress) -> Spoken {
        switch address {
        case .open(let inner), .unbroken(let inner, _): spokenAddress(inner)
        case .name(let name, _): Spoken(said: name, how: "Its name")
        case .row(let row, _): Spoken(said: "Session \(row)", how: "Its session number")
        case .unresolved(let spoken, _): Spoken(said: spoken)
        case .ambiguous(let spoken, let names, _): Spoken(said: spoken, how: "Its name", candidates: names)
        case .nearMiss(let spoken, let name, _, _): Spoken(said: spoken, how: "Sounded like its name", closest: name)
        case .none: Spoken()
        }
    }

    private static func chosenBy(_ resolution: AgentRecipient.Resolution, spoken: String?) -> String {
        if case .deliver(_, _, let source) = resolution, source != .spoken {
            return switch source {
            case .fixed: "The mode\u{2019}s fixed conversation"
            case .front: "The conversation in front"
            case .current, .spoken: "The current conversation"
            }
        }
        return spoken ?? "Its name"
    }
}

extension AgentRecipient.Resolution {
    public var recipient: String? {
        switch self {
        case .deliver(let id, _, _), .select(let id), .open(let id): id
        case .ask: nil
        }
    }
}
