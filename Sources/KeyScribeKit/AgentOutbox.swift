import Foundation

public struct AgentOutbox: Sendable {
    public struct Message: Equatable, Sendable {
        public let id: String
        public let conversation: String
        public let text: String
        public let images: [String]

        public init(id: String, conversation: String, text: String, images: [String] = []) {
            self.id = id
            self.conversation = conversation
            self.text = text
            self.images = images
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
        var sending = false
        var refusedSince: Date?
    }

    private var queue: [Held] = []

    public init() {}

    public var held: [Message] { queue.map(\.message) }

    public mutating func send(
        _ message: Message, state: AgentLiveState?, canEnterPromptBox: Bool = false, canSteer: Bool = false, keeping: Bool = false
    ) -> AgentDeliveryDecision {
        var context = AgentDeliveryContext(state: state ?? .disconnected)
        context.canEnterPromptBox = canEnterPromptBox
        context.canSteer = canSteer
        if state != nil, queue.contains(where: { $0.message.conversation == message.conversation }) {
            if ![.waitingApproval, .waitingQuestion, .userDialog].contains(context.state) { context.state = .working }
            context.canEnterPromptBox = false
            context.canSteer = false
        }
        let decision = AgentDeliveryPolicy.decide(context)
        switch decision {
        case .queue: queue.append(Held(message: message))
        case .handOff, .enterPromptBox: if keeping { queue.append(Held(message: message, sending: true)) }
        case .needsReview, .disconnected: break
        }
        return decision
    }

    public mutating func release(
        state: (String) -> AgentLiveState?, canSteer: (String) -> Bool = { _ in false }, keeping: (Message) -> Bool = { _ in false }
    ) -> [Release] {
        var released: [Release] = []
        var seen: Set<String> = []
        var remaining: [Held] = []
        for var held in queue {
            let conversation = held.message.conversation
            guard seen.insert(conversation).inserted, !held.sending else {
                remaining.append(held)
                continue
            }
            var context = AgentDeliveryContext(state: state(conversation) ?? .disconnected)
            context.typedSinceQueued = held.typedSince
            context.interruptedSinceQueued = held.interruptedSince
            context.connectionGapSinceQueued = held.connectionGapSince
            context.canSteer = canSteer(conversation)
            let decision = AgentDeliveryPolicy.decide(context)
            switch decision {
            case .queue:
                remaining.append(held)
            case .handOff, .enterPromptBox:
                released.append(Release(message: held.message, decision: decision))
                if keeping(held.message) {
                    held.sending = true
                    remaining.append(held)
                }
            case .needsReview, .disconnected:
                released.append(Release(message: held.message, decision: decision))
            }
        }
        queue = remaining
        return released
    }

    public mutating func finish(_ id: String) {
        queue.removeAll { $0.message.id == id }
    }

    @discardableResult
    public mutating func retry(_ id: String, at now: Date, turnRunning: Bool = false) -> (since: Date, marked: Bool) {
        guard let i = queue.firstIndex(where: { $0.message.id == id }) else { return (now, false) }
        queue[i].sending = false
        queue[i].refusedSince = turnRunning ? nil : queue[i].refusedSince ?? now
        let held = queue[i]
        return (held.refusedSince ?? now, held.typedSince || held.interruptedSince || held.connectionGapSince)
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
        guard let index = queue.firstIndex(where: { $0.message.id == id && !$0.sending }) else { return nil }
        return queue.remove(at: index).message
    }

    public mutating func withdraw(conversation: String) -> [Message] {
        let withdrawn = queue.filter { $0.message.conversation == conversation && !$0.sending }.map(\.message)
        queue.removeAll { $0.message.conversation == conversation && !$0.sending }
        return withdrawn
    }
}
