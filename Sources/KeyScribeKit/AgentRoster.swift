import Foundation

public struct AgentRoster: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let id: String
        public let number: Int
        public let name: String
        public let detail: String
        public let state: String
        public let available: Bool
        public let target: Bool

        public init(id: String, number: Int, name: String, detail: String, state: String, available: Bool, target: Bool) {
            self.id = id
            self.number = number
            self.name = name
            self.detail = detail
            self.state = state
            self.available = available
            self.target = target
        }
    }

    public let rows: [Row]
    public let namesAvailable: Bool
    public let disconnectedTarget: String?
    public let starting: String?

    public init(
        frozen: [AgentConversation], live: [AgentConversation], focused: String?, namesAvailable: Bool = true,
        disconnected: [AgentConversation] = [], prompts: [String: AgentPrompt] = [:], starting: String? = nil,
        agentNames: [String: String] = [:]
    ) {
        self.namesAvailable = namesAvailable
        self.starting = starting
        disconnectedTarget = disconnected.first { $0.id == focused }?.handle
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mixed = Set(frozen.map(\.agent)).count > 1
        rows = frozen.enumerated().map { index, conversation in
            let now = byId[conversation.id]
            return Row(
                id: conversation.id, number: index + 1, name: conversation.handle,
                detail: Self.detail(conversation, naming: mixed ? agentNames[conversation.agent] ?? conversation.agent.capitalized : nil),
                state: now.map { Self.stateLabel($0, prompt: prompts[$0.id]) } ?? "Ended",
                available: now.map(Self.isAvailable) ?? false,
                target: conversation.id == focused)
        }
    }

    public var targetName: String? {
        rows.first(where: \.target)?.name ?? disconnectedTarget.map { "\($0), disconnected" } ?? starting
    }

    public static func isWaitingForInput(_ conversation: AgentConversation) -> Bool {
        switch conversation.state {
        case .waitingApproval, .waitingQuestion, .userDialog: true
        case .idle, .working, .disconnected: false
        }
    }

    public static func recordingOrder(
        _ conversations: [AgentConversation], lastUsed: [String: Date]
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
        return recent(alphabetical.filter(isWaitingForInput)) + recent(alphabetical.filter { !isWaitingForInput($0) })
    }

    public static func isAvailable(_ conversation: AgentConversation) -> Bool {
        conversation.reachable && conversation.state != .disconnected
    }

    public static func stateLabel(_ conversation: AgentConversation, prompt: AgentPrompt? = nil) -> String {
        guard conversation.reachable else { return "Not connected" }
        switch conversation.state.named(by: prompt) {
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

    private static func detail(_ conversation: AgentConversation, naming agent: String?) -> String {
        let parts: [String?] = [
            agent, distinctTitle(conversation),
            URL(fileURLWithPath: conversation.cwd).lastPathComponent,
        ]
        return parts.compactMap(\.self).joined(separator: " \u{00B7} ")
    }
}
