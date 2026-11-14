import Foundation

public struct AgentRoster: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let id: String
        public let number: Int
        public let name: String
        public let detail: String
        public let state: String
        public let available: Bool
        public let current: Bool

        public init(id: String, number: Int, name: String, detail: String, state: String, available: Bool, current: Bool) {
            self.id = id
            self.number = number
            self.name = name
            self.detail = detail
            self.state = state
            self.available = available
            self.current = current
        }
    }

    public let rows: [Row]
    public let source: AgentRecipient.Source?
    public let namesAvailable: Bool
    public let disconnectedRecipient: String?

    public init(
        frozen: [AgentConversation], live: [AgentConversation], recipient: AgentRecipient.Frozen?, namesAvailable: Bool = true,
        disconnected: [AgentConversation] = []
    ) {
        self.namesAvailable = namesAvailable
        disconnectedRecipient = disconnected.first { $0.id == recipient?.id }?.handle
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = recipient.map { wanted in frozen.contains { $0.id == wanted.id } } ?? false
        let mixed = Set(frozen.map(\.agent)).count > 1
        rows = frozen.enumerated().map { index, conversation in
            let now = byId[conversation.id]
            return Row(
                id: conversation.id, number: index + 1, name: conversation.handle,
                detail: Self.detail(conversation, namingAgent: mixed),
                state: now.map(Self.stateLabel) ?? "Ended",
                available: now.map(Self.isAvailable) ?? false,
                current: listed && conversation.id == recipient?.id)
        }
        source = listed ? recipient?.source : nil
    }

    public var recipientName: String? {
        rows.first(where: \.current)?.name ?? disconnectedRecipient.map { "\($0), disconnected" }
    }

    public static func isWaitingForInput(_ conversation: AgentConversation) -> Bool {
        switch conversation.state {
        case .waitingApproval, .waitingQuestion, .userDialog: true
        case .idle, .working, .disconnected: false
        }
    }

    public static func recordingOrder(
        _ conversations: [AgentConversation], current: String?, lastUsed: [String: Date]
    ) -> [AgentConversation] {
        let alphabetical = conversations.sorted { $0.handle < $1.handle }
        let recency = { (conversation: AgentConversation) in
            max(lastUsed[conversation.id] ?? .distantPast, conversation.startedAt ?? .distantPast)
        }
        let recent = { (list: [AgentConversation]) in
            list.sorted {
                let (first, second) = (recency($0), recency($1))
                return first != second ? first > second : $0.handle < $1.handle
            }
        }
        let others = alphabetical.filter { $0.id != current }
        let waiting = recent(others.filter(isWaitingForInput))
        let rest = others.filter { !isWaitingForInput($0) }
        return alphabetical.filter { $0.id == current } + waiting + recent(rest)
    }

    public static func isAvailable(_ conversation: AgentConversation) -> Bool {
        conversation.reachable && conversation.state != .disconnected
    }

    public static func stateLabel(_ conversation: AgentConversation) -> String {
        guard conversation.reachable else { return "Not connected" }
        switch conversation.state {
        case .idle: return "Ready"
        case .working: return "Working"
        case .waitingApproval: return "Waiting for approval"
        case .waitingQuestion: return "Waiting for an answer"
        case .userDialog: return "Dialog open"
        case .disconnected: return "Disconnected"
        }
    }

    public static func distinctTitle(_ conversation: AgentConversation) -> String? {
        guard let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              AgentHandles.matchKey(title) != AgentHandles.matchKey(conversation.handle)
        else { return nil }
        return title
    }

    private static func detail(_ conversation: AgentConversation, namingAgent: Bool) -> String {
        let parts: [String?] = [
            namingAgent ? conversation.agent.capitalized : nil, distinctTitle(conversation),
            URL(fileURLWithPath: conversation.cwd).lastPathComponent,
        ]
        return parts.compactMap(\.self).joined(separator: " \u{00B7} ")
    }
}
