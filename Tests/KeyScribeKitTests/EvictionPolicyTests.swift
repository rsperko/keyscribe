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

    // Idle microphone warm-up rides the same tier as model residency.
    @Test func onlyFrugalSkipsPrewarm() {
        #expect(EvictionPolicy.shouldPrewarmCapture(mode: .fastest))
        #expect(EvictionPolicy.shouldPrewarmCapture(mode: .balanced))
        #expect(!EvictionPolicy.shouldPrewarmCapture(mode: .frugal))
    }

    @Test func onlyFastestRefreshesPeriodically() {
        #expect(EvictionPolicy.periodicallyRefreshesCapture(mode: .fastest))
        #expect(!EvictionPolicy.periodicallyRefreshesCapture(mode: .balanced))
        #expect(!EvictionPolicy.periodicallyRefreshesCapture(mode: .frugal))
    }

    @Test func onlyBalancedReleasesWarmOnIdle() {
        #expect(!EvictionPolicy.releasesWarmCaptureOnIdle(mode: .fastest))
        #expect(EvictionPolicy.releasesWarmCaptureOnIdle(mode: .balanced))
        #expect(!EvictionPolicy.releasesWarmCaptureOnIdle(mode: .frugal))
    }
}

struct EvictionCopyTests {
    // No footer string may ever contain a byte count (UX2 phase 3b) — the copy describes behavior, not size.
    private func hasNoByteCount(_ s: String) -> Bool {
        !s.contains("KB") && !s.contains("MB") && !s.contains("GB")
    }

    @Test func fastestStatesResidentBehaviorWithoutBytes() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Qwen3-ASR 1.7B", bytes: 1_800_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("Keeps Qwen3-ASR 1.7B loaded"))
        #expect(s.contains("microphone"))
        #expect(hasNoByteCount(s))
    }

    @Test func balancedUsesIdleLabelWithoutBytes() {
        let s = EvictionCopy.footer(
            policy: .balanced, modelName: "Qwen3-ASR 1.7B", bytes: 1_800_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("releases the microphone after 30 min idle"))
        #expect(s.contains("Qwen3-ASR 1.7B"))
        #expect(hasNoByteCount(s))
    }

    @Test func frugalLeadsWithFreeingWithoutBytes() {
        let s = EvictionCopy.footer(
            policy: .frugal, modelName: "Whisper Large v3 Turbo", bytes: 1_500_000_000,
            systemManaged: false, idleLabel: "30 min")
        #expect(s.contains("Frees Whisper Large v3 Turbo"))
        #expect(s.contains("after each dictation"))
        #expect(s.contains("microphone"))
        #expect(hasNoByteCount(s))
    }

    // A model under the small threshold collapses to the "costs you little" line regardless of policy.
    @Test func smallModelSoftenerReplacesPolicyCopy() {
        for policy: Eviction in [.fastest, .balanced, .frugal] {
            let s = EvictionCopy.footer(
                policy: policy, modelName: "Moonshine Base (English)", bytes: 141_000_000,
                systemManaged: false, idleLabel: "30 min")
            #expect(s.contains("is small"))
            #expect(s.contains("cost you little"))
            #expect(s.contains("Moonshine Base (English)"))
            #expect(hasNoByteCount(s))
        }
    }

    @Test func atThresholdIsNotSmall() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Big", bytes: EvictionCopy.smallModelBytes,
            systemManaged: false, idleLabel: "30 min")
        #expect(!s.contains("is small"))
        #expect(hasNoByteCount(s))
    }

    @Test func systemManagedHasNoFootprintCopy() {
        let s = EvictionCopy.footer(
            policy: .fastest, modelName: "Apple Speech", bytes: 0,
            systemManaged: true, idleLabel: "30 min")
        #expect(s.contains("managed by macOS"))
        #expect(s.contains("Apple Speech"))
        #expect(hasNoByteCount(s))
    }
}
