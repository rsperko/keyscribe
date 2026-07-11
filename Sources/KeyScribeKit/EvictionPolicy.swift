import Foundation

public enum EvictionDecision: Equatable, Sendable {
    case keepLoaded
    case evictNow
    case scheduleIdleCheck(afterSeconds: Double)
}

public enum EvictionPolicy {
    public static let defaultIdleSeconds: Double = 1800

    public static func afterDictation(mode: Eviction, idleSeconds: Double?) -> EvictionDecision {
        switch mode {
        case .fastest: return .keepLoaded
        case .frugal: return .evictNow
        case .balanced: return .scheduleIdleCheck(afterSeconds: idleSeconds ?? defaultIdleSeconds)
        }
    }

    public static func onIdleCheck(
        mode: Eviction, lastUsedAt: Double, now: Double, idleSeconds: Double?
    ) -> EvictionDecision {
        switch mode {
        case .fastest: return .keepLoaded
        case .frugal: return .evictNow
        case .balanced:
            let limit = idleSeconds ?? defaultIdleSeconds
            let idle = now - lastUsedAt
            if idle >= limit { return .evictNow }
            return .scheduleIdleCheck(afterSeconds: limit - idle)
        }
    }

    // Idle microphone warm-up rides the same tier as model residency: Fastest holds the input unit
    // warm (and periodically refreshes its binding), Balanced warms around use and releases at the
    // model's idle checkpoint, Frugal never warms and opens the mic only on trigger.
    public static func shouldPrewarmCapture(mode: Eviction) -> Bool { mode != .frugal }

    public static func periodicallyRefreshesCapture(mode: Eviction) -> Bool { mode == .fastest }

    public static func releasesWarmCaptureOnIdle(mode: Eviction) -> Bool { mode == .balanced }
}

public enum EvictionCopy {
    // Below this footprint, reloading is fast enough that the policy choice barely matters. Moonshine
    // (~141 MB) lands here.
    public static let smallModelBytes: Int64 = 200_000_000

    // Humanized footer (UX2 phase 3b): NEVER interpolate a byte count. `bytes` is kept only to classify a
    // small model (which reloads fast enough that the tier barely matters); the strings describe behavior.
    public static func footer(
        policy: Eviction, modelName: String, bytes: Int64, systemManaged: Bool, idleLabel: String
    ) -> String {
        if systemManaged {
            return "\(modelName) is managed by macOS, so this setting does not change its memory use."
        }
        if bytes > 0 && bytes < smallModelBytes {
            return "\(modelName) is small and reloads almost instantly — Balanced and Frugal cost you little here."
        }
        switch policy {
        case .fastest:
            return "Keeps \(modelName) loaded and the microphone connection ready. Every dictation starts instantly; some apps may see the mic as in use."
        case .balanced:
            return "Keeps \(modelName) loaded, then frees its memory and releases the microphone after \(idleLabel) idle. The next dictation reloads with a brief delay."
        case .frugal:
            return "Frees \(modelName)’s memory after each dictation and opens the microphone only while dictating — lowest memory use, with a brief delay before each."
        }
    }
}
