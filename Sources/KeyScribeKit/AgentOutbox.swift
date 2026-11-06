import Foundation

public struct AgentOutbox: Sendable {
    public struct Message: Equatable, Sendable {
        public let id: String
        public let conversation: String
        public let text: String
        public var delivery: Mode.Agent.Delivery

        public init(id: String, conversation: String, text: String, delivery: Mode.Agent.Delivery) {
            self.id = id
            self.conversation = conversation
            self.text = text
            self.delivery = delivery
        }
    }

    public struct Release: Equatable, Sendable {
        public let message: Message
        public let decision: AgentDeliveryDecision
    }

    private struct Held: Sendable {
        var message: Message
        var typedSince = false
        var interruptedSince = false
        var connectionGapSince = false
    }

    private var queue: [Held] = []

    public init() {}

    public var held: [Message] { queue.map(\.message) }

    public mutating func send(_ message: Message, state: AgentLiveState?) -> AgentDeliveryDecision {
        var context = AgentDeliveryContext(state: state ?? .disconnected)
        context.delivery = message.delivery
        if state != nil, queue.contains(where: { $0.message.conversation == message.conversation }) {
            context.state = .working
        }
        let decision = AgentDeliveryPolicy.decide(context)
        if case .queue = decision { queue.append(Held(message: message)) }
        return decision
    }

    public mutating func release(state: (String) -> AgentLiveState?) -> [Release] {
        var released: [Release] = []
        var seen: Set<String> = []
        var remaining: [Held] = []
        for held in queue {
            let conversation = held.message.conversation
            guard seen.insert(conversation).inserted else {
                remaining.append(held)
                continue
            }
            var context = AgentDeliveryContext(state: state(conversation) ?? .disconnected)
            context.delivery = .submit
            context.typedSinceQueued = held.typedSince
            context.interruptedSinceQueued = held.interruptedSince
            context.connectionGapSinceQueued = held.connectionGapSince
            let decision = AgentDeliveryPolicy.decide(context)
            if case .queue = decision {
                remaining.append(held)
            } else {
                released.append(Release(message: held.message, decision: decision))
            }
        }
        queue = remaining
        return released
    }

    public mutating func noteTyped(conversation: String) {
        for i in queue.indices where queue[i].message.conversation == conversation { queue[i].typedSince = true }
    }

    public mutating func noteInterrupted(conversation: String) {
        for i in queue.indices where queue[i].message.conversation == conversation { queue[i].interruptedSince = true }
    }

    public mutating func noteConnectionGap(conversation: String) {
        for i in queue.indices where queue[i].message.conversation == conversation { queue[i].connectionGapSince = true }
    }

    public mutating func withdraw(_ id: String) -> Message? {
        guard let index = queue.firstIndex(where: { $0.message.id == id }) else { return nil }
        return queue.remove(at: index).message
    }
}
