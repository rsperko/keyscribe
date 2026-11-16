import Foundation

public enum AgentLiveState: Equatable, Sendable {
    case idle, working, waitingApproval, waitingQuestion, userDialog, disconnected

    public func named(by prompt: AgentPrompt?) -> AgentLiveState {
        guard self == .userDialog else { return self }
        switch prompt?.kind {
        case "confirm": return .waitingApproval
        case "select", "input", "editor": return .waitingQuestion
        default: return .userDialog
        }
    }
}

public struct AgentDeliveryContext: Equatable, Sendable {
    public var state: AgentLiveState
    public var typedSinceQueued = false
    public var interruptedSinceQueued = false
    public var connectionGapSinceQueued = false
    public var canEnterPromptBox = false
    public var canSteer = false

    public init(state: AgentLiveState) {
        self.state = state
    }
}

public enum AgentDeliveryDecision: Equatable, Sendable {
    public enum QueueReason: Equatable, Sendable { case working, approval, question, userDialog }
    public enum ReviewReason: Equatable, Sendable { case typedSince, interrupted, connectionGap }

    case handOff
    case enterPromptBox
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
        case .working: return c.canSteer ? .handOff : c.canEnterPromptBox ? .enterPromptBox : .queue(.working)
        case .idle, .disconnected: return .handOff
        }
    }
}
