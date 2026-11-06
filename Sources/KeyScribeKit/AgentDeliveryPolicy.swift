import Foundation

public enum AgentLiveState: Equatable, Sendable {
    case idle, working, waitingApproval, waitingQuestion, userDialog, disconnected
}

public struct AgentDeliveryContext: Equatable, Sendable {
    public var state: AgentLiveState
    public var delivery: Mode.Agent.Delivery = .submit
    public var confirmed = false
    public var conversationChanged = false
    public var userTypingRecently = false
    public var typedSinceQueued = false
    public var questionResolvedSinceQueued = false
    public var interruptedSinceQueued = false
    public var historyMovedSinceQueued = false
    public var connectionGapSinceQueued = false
    public var sideConversationOpen = false
    public var stopLocked = false
    public var composerHasDraft = false

    public init(state: AgentLiveState) {
        self.state = state
    }
}

public enum AgentDeliveryDecision: Equatable, Sendable {
    public enum QueueReason: Equatable, Sendable { case working, approval, question, userDialog, userTyping }
    public enum ReviewReason: Equatable, Sendable { case typedSince, questionResolved, interrupted, historyMoved, connectionGap }
    public enum DraftReason: Equatable, Sendable { case modeReviews, sideConversation }
    public enum NotSentReason: Equatable, Sendable { case disconnected, conversationChanged }
    public enum Recovery: Equatable, Sendable { case fillComposer, button }

    case handOff
    case queue(QueueReason)
    case draft(DraftReason)
    case needsReview(ReviewReason)
    case notSent(NotSentReason)
    case escRecovery(Recovery)
}

public enum AgentDeliveryPolicy {
    public static func decide(_ c: AgentDeliveryContext) -> AgentDeliveryDecision {
        if c.conversationChanged { return .notSent(.conversationChanged) }
        if c.state == .disconnected { return .notSent(.disconnected) }
        if !c.confirmed {
            if c.typedSinceQueued { return .needsReview(.typedSince) }
            if c.questionResolvedSinceQueued { return .needsReview(.questionResolved) }
            if c.interruptedSinceQueued { return .needsReview(.interrupted) }
            if c.historyMovedSinceQueued { return .needsReview(.historyMoved) }
            if c.connectionGapSinceQueued { return .needsReview(.connectionGap) }
            if c.sideConversationOpen { return .draft(.sideConversation) }
            if c.delivery == .draft { return .draft(.modeReviews) }
        }
        switch c.state {
        case .waitingApproval: return .queue(.approval)
        case .waitingQuestion: return .queue(.question)
        case .userDialog: return .queue(.userDialog)
        case .working: return .queue(.working)
        case .idle, .disconnected: break
        }
        if c.userTypingRecently { return .queue(.userTyping) }
        if c.stopLocked { return .escRecovery(c.composerHasDraft ? .button : .fillComposer) }
        return .handOff
    }
}
