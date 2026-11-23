import Foundation
import Testing
@testable import KeyScribeKit

struct AgentOutboxTests {
    private func message(_ id: String, to conversation: String = "s1") -> AgentOutbox.Message {
        AgentOutbox.Message(id: id, conversation: conversation, text: "run the tests")
    }

    @Test func anIdleConversationGetsTheMessageAndNothingIsHeld() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .idle) == .handOff)
        #expect(outbox.held.isEmpty)
    }

    @Test func aBusyConversationHoldsTheMessageUntilItFinishes() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working) == .queue(.working))
        #expect(outbox.release { _ in .working }.isEmpty)
        #expect(outbox.held.map(\.id) == ["m1"])

        let released = outbox.release { _ in .idle }
        #expect(released == [.init(message: message("m1"), decision: .handOff)])
        #expect(outbox.held.isEmpty)
    }

    @Test func aMessageSentAgainGoesBackAheadOfWhatItsConversationQueuedAfterItAndBehindOtherConversations() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("other", to: "s2"), state: .working)
        _ = outbox.send(message("m2"), state: .working)
        #expect(outbox.send(message("m1"), state: .working, ahead: true) == .queue(.working))
        _ = outbox.send(message("m3"), state: .working)
        #expect(outbox.held.map(\.id) == ["other", "m1", "m2", "m3"])
        #expect(outbox.release { _ in .idle }.map(\.message.id) == ["other", "m1"])
    }

    @Test func aMessageBeingSentStaysFirstSoNothingForItsConversationOvertakesIt() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2"), state: .working)
        _ = outbox.send(message("m3", to: "s2"), state: .working)
        let first = outbox.release(state: { _ in .idle }, keeping: { $0.conversation == "s1" })
        #expect(first.map(\.message.id) == ["m1", "m3"])
        #expect(outbox.held.map(\.id) == ["m1", "m2"])
        #expect(outbox.release(state: { _ in .idle }, keeping: { _ in true }).isEmpty)
        #expect(outbox.send(message("m4"), state: .idle) == .queue(.working))
        outbox.finish("m1")
        #expect(outbox.release(state: { _ in .idle }, keeping: { _ in true }).map(\.message.id) == ["m2"])
    }

    @Test func aMessageTheConversationCouldNotTakeYetKeepsItsPlaceAndWhatHappenedWhileItWasBeingSent() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2"), state: .working)
        _ = outbox.release(state: { _ in .idle }, keeping: { _ in true })
        outbox.noteTyped(conversation: "s1")
        outbox.retry("m1", at: Date())
        #expect(outbox.held.map(\.id) == ["m1", "m2"])
        let released = outbox.release(state: { _ in .idle }, keeping: { _ in true })
        #expect(released.map(\.message.id) == ["m1"])
        #expect(released.first?.decision == .needsReview(.typedSince))
    }

    @Test func withdrawingAConversationLeavesTheMessageBeingSentToFinish() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2"), state: .working)
        _ = outbox.release(state: { _ in .idle }, keeping: { _ in true })
        #expect(outbox.withdraw(conversation: "s1").map(\.id) == ["m2"])
        #expect(outbox.held.map(\.id) == ["m1"])
    }

    @Test func aMessageForAPromptBoxIsEnteredThereAndNotHeld() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working, canEnterPromptBox: true) == .enterPromptBox)
        #expect(outbox.held.isEmpty)
    }

    @Test(arguments: [
        (AgentLiveState.waitingApproval, AgentDeliveryDecision.QueueReason.approval),
        (.waitingQuestion, .question), (.userDialog, .userDialog), (.idle, .working), (.working, .working),
    ])
    func aMessageHeldBehindAnotherSaysWhatTheConversationWaitsOn(state: AgentLiveState, reason: AgentDeliveryDecision.QueueReason) {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working) == .queue(.working))
        #expect(outbox.send(message("m2"), state: state, canEnterPromptBox: true, canSteer: true) == .queue(reason))
        #expect(outbox.held.map(\.id) == ["m1", "m2"])
    }

    @Test func aMessageNeverOvertakesOneHeldForTheSameConversationThroughThePromptBox() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working) == .queue(.working))
        #expect(outbox.send(message("m2"), state: .working, canEnterPromptBox: true) == .queue(.working))
        #expect(outbox.send(message("m3", to: "s2"), state: .working, canEnterPromptBox: true) == .enterPromptBox)
        #expect(outbox.held.map(\.id) == ["m1", "m2"])
    }

    @Test func aMessageNeverOvertakesOneHeldForTheSameConversationBySteering() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working) == .queue(.working))
        #expect(outbox.send(message("m2"), state: .working, canSteer: true) == .queue(.working))
        #expect(outbox.send(message("m3", to: "s2"), state: .working, canSteer: true) == .handOff)
    }

    @Test func aHeldMessageForAnAgentThatSteersIsReleasedWhileItWorks() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: .working) == .queue(.working))
        #expect(outbox.release(state: { _ in .working }).isEmpty)
        #expect(outbox.release(state: { _ in .working }, canSteer: { _ in true }) == [.init(message: message("m1"), decision: .handOff)])
    }

    @Test func aMissingConversationIsNotSentAndNotHeld() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: nil) == .disconnected)
        #expect(outbox.held.isEmpty)
    }

    @Test func aHeldMessageWhoseConversationWentAwayComesBackNotSent() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.release { _ in nil } == [.init(message: message("m1"), decision: .disconnected)])
        #expect(outbox.held.isEmpty)
    }

    @Test func onlyTheOldestHeldMessagePerConversationIsReleasedAtATime() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2"), state: .working)
        _ = outbox.send(message("m3", to: "s2"), state: .working)

        #expect(outbox.release { _ in .idle }.map(\.message.id) == ["m1", "m3"])
        #expect(outbox.held.map(\.id) == ["m2"])
    }

    @Test func aMessageQueuedBehindAnotherWaitsEvenIfTheConversationLooksIdle() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.send(message("m2"), state: .idle) == .queue(.working))
        #expect(outbox.held.map(\.id) == ["m1", "m2"])
    }

    @Test func typingIntoTheConversationWhileHeldNeedsReviewOnRelease() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2", to: "s2"), state: .working)
        outbox.noteTyped(conversation: "s1")

        let released = outbox.release { _ in .idle }
        #expect(released.map(\.decision) == [.needsReview(.typedSince), .handOff])
        #expect(outbox.held.isEmpty)
    }

    @Test func typingBeforeAMessageIsQueuedDoesNotCount() {
        var outbox = AgentOutbox()
        outbox.noteTyped(conversation: "s1")
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.release { _ in .idle }.map(\.decision) == [.handOff])
    }

    @Test func aConnectionGapWhileHeldNeedsReviewOnRelease() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        _ = outbox.send(message("m2", to: "s2"), state: .working)
        outbox.noteConnectionGap(conversation: "s1")
        #expect(outbox.release { _ in .idle }.map(\.decision) == [.needsReview(.connectionGap), .handOff])
    }

    @Test func aConnectionGapBeforeAMessageIsQueuedDoesNotCount() {
        var outbox = AgentOutbox()
        outbox.noteConnectionGap(conversation: "s1")
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.release { _ in .idle }.map(\.decision) == [.handOff])
    }

    @Test func anInterruptedTurnHoldsForReconfirmation() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        outbox.noteInterrupted(conversation: "s1")
        #expect(outbox.release { _ in .idle }.map(\.decision) == [.needsReview(.interrupted)])
    }

    @Test func aWithdrawnMessageIsNeverReleased() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.withdraw("m1")?.id == "m1")
        #expect(outbox.withdraw("m1") == nil)
        #expect(outbox.release { _ in .idle }.isEmpty)
    }

    @Test func withdrawingAConversationReturnsEveryMessageHeldForItAndKeepsTheOthers() {
        var outbox = AgentOutbox()
        _ = outbox.send(AgentOutbox.Message(id: "a1", conversation: "a", text: "one"), state: .working)
        _ = outbox.send(AgentOutbox.Message(id: "b1", conversation: "b", text: "two"), state: .working)
        _ = outbox.send(AgentOutbox.Message(id: "a2", conversation: "a", text: "three"), state: .working)
        #expect(outbox.withdraw(conversation: "a").map(\.id) == ["a1", "a2"])
        #expect(outbox.held.map(\.id) == ["b1"])
    }
}
