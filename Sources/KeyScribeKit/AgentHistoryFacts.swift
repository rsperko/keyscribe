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
        address: AgentAddress, resolution: AgentRecipient.Resolution, focused: String?,
        conversations: [AgentConversation]
    ) -> [HistoryEntry.Fact] {
        let spoken = spokenAddress(address)
        var facts = [fact(command: command(address))]
        if let said = spoken.said { facts.append(.init(label: "Spoken address", value: said)) }
        if let closest = spoken.closest { facts.append(.init(label: "Closest name", value: closest)) }
        if let candidates = spoken.candidates { facts.append(.init(label: "Candidates", value: candidates.sorted().joined(separator: ", "))) }
        if let id = resolution.recipient {
            facts.append(.init(label: "Conversation", value: described(id, in: conversations)))
            facts.append(.init(label: "Chosen by", value: chosenBy(resolution, spoken: spoken.how)))
        } else {
            facts.append(.init(label: "Conversation", value: "None resolved"))
        }
        facts += inFront(focused, in: conversations)
        return facts
    }

    public static func delivery(_ delivery: AgentDelivery, agent: String, timeZone: TimeZone = .current) -> HistoryEntry.Fact {
        .init(label: "Delivery", value: delivery.describe(agent: agent, timeZone: timeZone))
    }

    public static func replacing(_ fact: HistoryEntry.Fact, in entry: HistoryEntry) -> HistoryEntry {
        var next = entry
        next.facts = (entry.facts ?? []).filter { $0.label != fact.label } + [fact]
        return next
    }

    public static func cancel(focused: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "Cancel")] + inFront(focused, in: conversations)
    }

    public static func goBack(focused: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "Go back")] + inFront(focused, in: conversations)
    }

    public static func repeatSummary(focused: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "Repeat that")] + inFront(focused, in: conversations)
    }

    public static func keepReply(focused: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        [fact(command: "That sounded wrong")] + inFront(focused, in: conversations)
    }

    public static func rename(focused: String?, to name: String?, conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        var facts = [fact(command: "Rename")]
        facts.append(.init(label: "Conversation", value: focused.map { described($0, in: conversations) } ?? "None resolved"))
        if let name { facts.append(.init(label: "New name", value: name)) }
        if focused != nil { facts.append(.init(label: "Chosen by", value: byFront)) }
        return facts
    }

    public static func status(
        address: AgentAddress?, resolution: AgentRecipient.Resolution, focused: String?, conversations: [AgentConversation]
    ) -> [HistoryEntry.Fact] {
        let recorded = facts(address: address ?? .none(body: ""), resolution: resolution, focused: focused, conversations: conversations)
        return [fact(command: "Check status")] + recorded.dropFirst().filter { $0.label != inFrontLabel }
    }

    public static func allConversations() -> [HistoryEntry.Fact] {
        [fact(command: "Check status"), .init(label: "Conversation", value: "All conversations")]
    }

    private static func described(_ id: String, in conversations: [AgentConversation]) -> String {
        let conversation = conversations.first { $0.id == id }
        return conversation.map { "\($0.handle) \u{00B7} \($0.agent) \u{00B7} \(AgentSessionID.native(id))" } ?? AgentSessionID.native(id)
    }

    private static func fact(command: String) -> HistoryEntry.Fact {
        HistoryEntry.Fact(label: "Command", value: command)
    }

    private static let inFrontLabel = "Conversation in front"

    private static func inFront(_ focused: String?, in conversations: [AgentConversation]) -> [HistoryEntry.Fact] {
        guard let focused else { return [] }
        let handle = conversations.first { $0.id == focused }?.handle ?? focused
        return [.init(label: inFrontLabel, value: handle)]
    }

    private static func command(_ address: AgentAddress) -> String {
        if case .open = address { return "Open" }
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
        case .row(let row, _): Spoken(said: "Conversation \(row)", how: "Its conversation number")
        case .unresolved(let spoken, _): Spoken(said: spoken)
        case .ambiguous(let spoken, let names, _): Spoken(said: spoken, how: "Its name", candidates: names)
        case .nearMiss(let spoken, let name, _, _): Spoken(said: spoken, how: "Sounded like its name", closest: name)
        case .none: Spoken()
        }
    }

    private static func chosenBy(_ resolution: AgentRecipient.Resolution, spoken: String?) -> String {
        if case .deliver(_, _, .front) = resolution { return byFront }
        return spoken ?? "Its name"
    }

    private static let byFront = "The conversation in front"
}

extension AgentRecipient.Resolution {
    public var recipient: String? {
        switch self {
        case .deliver(let id, _, _), .open(let id): id
        case .ask: nil
        }
    }
}
