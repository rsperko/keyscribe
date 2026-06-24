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
}

struct EvictionCopyTests {
    @Test func fastestStatesResidentFootprint() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Qwen3-ASR 1.7B", bytes: 1_800_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("Keeps Qwen3-ASR 1.7B loaded"))
        #expect(s.contains("on disk, similar in memory"))
        #expect(s.contains("1.8 GB"))
    }

    @Test func balancedUsesIdleLabel() {
        let s = EvictionCopy.footer(
            policy: .balanced, modelName: "Qwen3-ASR 1.7B", bytes: 1_800_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("frees it after 30 min idle"))
        #expect(s.contains("1.8 GB"))
    }

    @Test func frugalLeadsWithFreeing() {
        let s = EvictionCopy.footer(
            policy: .frugal, modelName: "Whisper Large v3 Turbo", bytes: 1_500_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("Frees Whisper Large v3 Turbo"))
        #expect(s.contains("after each dictation"))
    }

    // A model under the small threshold collapses to the "costs you little" line regardless of policy.
    @Test func smallModelSoftenerReplacesPolicyCopy() {
        for policy: Eviction in [.fastest, .balanced, .frugal] {
            let s = EvictionCopy.footer(
                policy: policy, modelName: "Moonshine Base (English)", bytes: 141_000_000,
                systemManaged: false, idleLabel: "30 min")
            #expect(s.contains("is small"))
            #expect(s.contains("cost you little"))
        }
    }

    @Test func atThresholdIsNotSmall() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Big", bytes: EvictionCopy.smallModelBytes,
            systemManaged: false, idleLabel: "30 min")
        #expect(!s.contains("is small"))
    }

    @Test func systemManagedHasNoFootprintCopy() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Apple Speech", bytes: 0,
            systemManaged: true, idleLabel: "30 min")
        #expect(s.contains("managed by macOS"))
        #expect(!s.contains("loaded ("))
    }
}
