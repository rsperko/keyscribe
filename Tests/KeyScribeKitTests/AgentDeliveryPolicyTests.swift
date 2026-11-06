import Foundation
import Testing
@testable import KeyScribeKit

struct AgentDeliveryPolicyTests {
    private func decide(_ edit: (inout AgentDeliveryContext) -> Void = { _ in }) -> AgentDeliveryDecision {
        var context = AgentDeliveryContext(state: .idle)
        edit(&context)
        return AgentDeliveryPolicy.decide(context)
    }

    @Test func anIdleConversationGetsItRightAway() {
        #expect(decide() == .handOff)
    }

    @Test(arguments: [
        (AgentLiveState.working, AgentDeliveryDecision.queue(.working)),
        (.waitingApproval, .queue(.approval)),
        (.waitingQuestion, .queue(.question)),
        (.userDialog, .queue(.userDialog)),
    ])
    func busyOrWaitingConversationsQueue(state: AgentLiveState, expected: AgentDeliveryDecision) {
        #expect(decide { $0.state = state } == expected)
    }

    @Test func recentTypingInThatTerminalQueuesBriefly() {
        #expect(decide { $0.userTypingRecently = true } == .queue(.userTyping))
    }

    @Test func aDisconnectedConversationIsNotSent() {
        #expect(decide { $0.state = .disconnected } == .notSent(.disconnected))
    }

    @Test func aChangedConversationIsNeverRedirected() {
        #expect(decide { $0.conversationChanged = true; $0.state = .idle } == .notSent(.conversationChanged))
        #expect(decide { $0.conversationChanged = true; $0.state = .working } == .notSent(.conversationChanged))
    }

    @Test func somethingThatChangedSinceQueueingNeedsReview() {
        #expect(decide { $0.typedSinceQueued = true } == .needsReview(.typedSince))
        #expect(decide { $0.questionResolvedSinceQueued = true } == .needsReview(.questionResolved))
        #expect(decide { $0.interruptedSinceQueued = true } == .needsReview(.interrupted))
        #expect(decide { $0.historyMovedSinceQueued = true } == .needsReview(.historyMoved))
    }

    @Test func aReviewOutranksWaitingButNotAChangedConversation() {
        #expect(decide { $0.typedSinceQueued = true; $0.state = .working } == .needsReview(.typedSince))
        #expect(decide { $0.typedSinceQueued = true; $0.conversationChanged = true } == .notSent(.conversationChanged))
    }

    @Test func confirmingAReviewClearsItsReasonsOnly() {
        #expect(decide { $0.typedSinceQueued = true; $0.confirmed = true } == .handOff)
        #expect(decide { $0.typedSinceQueued = true; $0.confirmed = true; $0.state = .working } == .queue(.working))
    }

    @Test func reviewBeforeSendingShowsADraftFirst() {
        #expect(decide { $0.delivery = .draft } == .draft(.modeReviews))
        #expect(decide { $0.delivery = .draft; $0.confirmed = true } == .handOff)
    }

    @Test func aSideConversationForcesADraftEvenWhenSendingAfterSpeaking() {
        #expect(decide { $0.sideConversationOpen = true } == .draft(.sideConversation))
        #expect(decide { $0.sideConversationOpen = true; $0.confirmed = true } == .handOff)
    }

    @Test func aStopLockedClaudeRecoversThroughItsComposer() {
        #expect(decide { $0.stopLocked = true } == .escRecovery(.fillComposer))
        #expect(decide { $0.stopLocked = true; $0.composerHasDraft = true } == .escRecovery(.button))
    }

    @Test func aStopLockMattersOnlyOnceItIsTimeToSend() {
        #expect(decide { $0.stopLocked = true; $0.state = .working } == .queue(.working))
        #expect(decide { $0.stopLocked = true; $0.state = .idle } == .escRecovery(.fillComposer))
    }
}
