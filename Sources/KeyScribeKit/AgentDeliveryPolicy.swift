import Foundation

public enum AgentLiveState: Equatable, Sendable {
    case idle, working, waitingApproval, waitingQuestion, userDialog, disconnected
}

public struct AgentDeliveryContext: Equatable, Sendable {
    public var state: AgentLiveState
    public var typedSinceQueued = false
    public var interruptedSinceQueued = false
    public var connectionGapSinceQueued = false

    public init(state: AgentLiveState) {
        self.state = state
    }
}

public enum AgentDeliveryDecision: Equatable, Sendable {
    public enum QueueReason: Equatable, Sendable { case working, approval, question, userDialog }
    public enum ReviewReason: Equatable, Sendable { case typedSince, interrupted, connectionGap }

    case handOff
    case queue(QueueReason)
    case needsReview(ReviewReason)
    case disconnected
}

public enum AgentDeliveryPolicy {
    public static func decide(_ c: AgentDeliveryContext) -> AgentDeliveryDecision {
        if c.state == .disconnected { return .disconnected }
        if c.typedSinceQueued { return .needsReview(.typedSince) }
        if c.interruptedSinceQueued { return .needsReview(.interrupted) }
        if c.connectionGapSinceQueued { return .needsReview(.connectionGap) }
        switch c.state {
        case .waitingApproval: return .queue(.approval)
        case .waitingQuestion: return .queue(.question)
        case .userDialog: return .queue(.userDialog)
        case .working: return .queue(.working)
        case .idle, .disconnected: return .handOff
        }
    }
}
