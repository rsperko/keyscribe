import Testing
@testable import KeyScribeKit

struct EvictionPolicyTests {
    // After a dictation finishes
    @Test func fastestKeepsLoadedAfterDictation() {
        #expect(EvictionPolicy.afterDictation(mode: .fastest, idleSeconds: 120) == .keepLoaded)
    }

    @Test func frugalEvictsImmediatelyAfterDictation() {
        #expect(EvictionPolicy.afterDictation(mode: .frugal, idleSeconds: 120) == .evictNow)
    }

    @Test func balancedSchedulesIdleEvictionAfterDictation() {
        #expect(EvictionPolicy.afterDictation(mode: .balanced, idleSeconds: 90)
            == .scheduleIdleCheck(afterSeconds: 90))
    }

    // When the idle timer fires
    @Test func balancedEvictsWhenIdleElapsed() {
        #expect(EvictionPolicy.onIdleCheck(mode: .balanced, lastUsedAt: 100, now: 230, idleSeconds: 120)
            == .evictNow)
    }

    @Test func balancedRescheduleWhenStillActive() {
        // used again at 200; check fires at 230 — only 30s idle, reschedule the remaining 90
        #expect(EvictionPolicy.onIdleCheck(mode: .balanced, lastUsedAt: 200, now: 230, idleSeconds: 120)
            == .scheduleIdleCheck(afterSeconds: 90))
    }

    @Test func balancedEvictsExactlyAtThreshold() {
        #expect(EvictionPolicy.onIdleCheck(mode: .balanced, lastUsedAt: 0, now: 120, idleSeconds: 120)
            == .evictNow)
    }

    @Test func fastestNeverEvictsOnIdle() {
        #expect(EvictionPolicy.onIdleCheck(mode: .fastest, lastUsedAt: 0, now: 9999, idleSeconds: 120)
            == .keepLoaded)
    }

    @Test func defaultIdleSecondsApplied() {
        #expect(EvictionPolicy.afterDictation(mode: .balanced, idleSeconds: nil)
            == .scheduleIdleCheck(afterSeconds: EvictionPolicy.defaultIdleSeconds))
    }

    // A large model on Fastest would pin its whole footprint resident forever; cap it at Balanced so it
    // idle-evicts. Small models keep Fastest's instant residency; Balanced/Frugal are user choices and
    // pass through unchanged for any size.
    @Test func fastestDowngradesToBalancedForLargeModel() {
        #expect(EvictionPolicy.effective(.fastest, modelBytes: 2_000_000_000) == .balanced)
    }

    @Test func fastestHonoredForSmallModel() {
        #expect(EvictionPolicy.effective(.fastest, modelBytes: 141_000_000) == .fastest)
    }

    @Test func fastestHonoredExactlyBelowThreshold() {
        #expect(EvictionPolicy.effective(.fastest, modelBytes: EvictionPolicy.largeModelByteThreshold - 1) == .fastest)
    }

    @Test func fastestDowngradesExactlyAtThreshold() {
        #expect(EvictionPolicy.effective(.fastest, modelBytes: EvictionPolicy.largeModelByteThreshold) == .balanced)
    }

    @Test func balancedAndFrugalPassThroughRegardlessOfSize() {
        #expect(EvictionPolicy.effective(.balanced, modelBytes: 2_000_000_000) == .balanced)
        #expect(EvictionPolicy.effective(.frugal, modelBytes: 2_000_000_000) == .frugal)
        #expect(EvictionPolicy.effective(.frugal, modelBytes: 0) == .frugal)
    }
}
