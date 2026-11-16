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

    @Test func aWorkingConversationWhosePromptBoxCanTakeItGetsItEnteredThere() {
        #expect(decide { $0.state = .working; $0.canEnterPromptBox = true } == .enterPromptBox)
    }

    @Test(arguments: [AgentLiveState.idle, .waitingApproval, .waitingQuestion, .userDialog, .disconnected])
    func onlyAWorkingConversationIsEverEnteredInItsPromptBox(state: AgentLiveState) {
        #expect(decide { $0.state = state; $0.canEnterPromptBox = true } != .enterPromptBox)
    }

    @Test func aWorkingConversationWhoseAgentSteersGetsItRightAway() {
        #expect(decide { $0.state = .working; $0.canSteer = true } == .handOff)
    }

    @Test func aWorkingConversationInFrontIsTypedIntoRatherThanSteered() {
        #expect(decide { $0.state = .working; $0.canSteer = true; $0.canEnterPromptBox = true } == .enterPromptBox)
    }

    @Test(arguments: [AgentLiveState.waitingApproval, .waitingQuestion, .userDialog, .disconnected])
    func aConversationWaitingOnTheUserIsNeverSteered(state: AgentLiveState) {
        #expect(decide { $0.state = state; $0.canSteer = true } != .handOff)
    }

    @Test func aReviewOutranksThePromptBox() {
        #expect(decide { $0.state = .working; $0.canEnterPromptBox = true; $0.typedSinceQueued = true } == .needsReview(.typedSince))
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
