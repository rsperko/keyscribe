import Foundation
import Testing
@testable import KeyScribeKit

struct AgentOutboxTests {
    private func message(_ id: String, to conversation: String = "s1", delivery: Mode.Agent.Delivery = .submit) -> AgentOutbox.Message {
        AgentOutbox.Message(id: id, conversation: conversation, text: "run the tests", delivery: delivery)
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

    @Test func aMissingConversationIsNotSentAndNotHeld() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1"), state: nil) == .notSent(.disconnected))
        #expect(outbox.held.isEmpty)
    }

    @Test func aHeldMessageWhoseConversationWentAwayComesBackNotSent() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.release { _ in nil } == [.init(message: message("m1"), decision: .notSent(.disconnected))])
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

    @Test func aReviewModeMessageBecomesADraftInsteadOfSending() {
        var outbox = AgentOutbox()
        #expect(outbox.send(message("m1", delivery: .draft), state: .idle) == .draft(.modeReviews))
        #expect(outbox.held.isEmpty)
    }

    @Test func aWithdrawnMessageIsNeverReleased() {
        var outbox = AgentOutbox()
        _ = outbox.send(message("m1"), state: .working)
        #expect(outbox.withdraw("m1")?.id == "m1")
        #expect(outbox.withdraw("m1") == nil)
        #expect(outbox.release { _ in .idle }.isEmpty)
    }
}
