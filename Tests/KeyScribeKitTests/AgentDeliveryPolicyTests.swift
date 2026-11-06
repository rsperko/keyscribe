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

    @Test func aDisconnectedConversationIsNotSent() {
        #expect(decide { $0.state = .disconnected } == .disconnected)
    }

    @Test func aConnectionGapSinceQueueingNeedsReview() {
        #expect(decide { $0.connectionGapSinceQueued = true } == .needsReview(.connectionGap))
    }

    @Test func somethingThatChangedSinceQueueingNeedsReview() {
        #expect(decide { $0.typedSinceQueued = true } == .needsReview(.typedSince))
        #expect(decide { $0.interruptedSinceQueued = true } == .needsReview(.interrupted))
    }

    @Test func aReviewOutranksWaitingButNotADisconnection() {
        #expect(decide { $0.typedSinceQueued = true; $0.state = .working } == .needsReview(.typedSince))
        #expect(decide { $0.typedSinceQueued = true; $0.state = .disconnected } == .disconnected)
    }
}
