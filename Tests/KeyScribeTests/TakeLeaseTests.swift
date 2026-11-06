import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct TakeLeaseTests {
    @MainActor private final class State {
        var wanted = true
        var begins = 0
        var canBegin = true
    }

    private func lease(_ state: State) -> TakeLease {
        TakeLease(
            stillWanted: { state.wanted },
            beginActing: {
                guard state.canBegin else { return false }
                state.begins += 1
                state.canBegin = false
                return true
            },
            abortsActuation: { false })
    }

    @Test func keepActingBeginsOnceThenOnlyRechecks() {
        let state = State()
        let lease = lease(state)
        #expect(lease.keepActing())
        #expect(lease.keepActing())
        #expect(state.begins == 1)
        state.wanted = false
        #expect(!lease.keepActing())
    }

    @Test func aTakeNoLongerWantedNeverBeginsActing() {
        let state = State()
        state.wanted = false
        #expect(!lease(state).keepActing())
        #expect(state.begins == 0)
    }

    @Test func aSecondLeaseForTheSameTakeCannotBeginAgain() {
        let state = State()
        #expect(lease(state).beginActing())
        #expect(!lease(state).beginActing())
    }
}
