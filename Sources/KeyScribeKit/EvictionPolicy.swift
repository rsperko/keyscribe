import Foundation

public enum EvictionDecision: Equatable, Sendable {
    case keepLoaded
    case evictNow
    case scheduleIdleCheck(afterSeconds: Double)
}

public enum EvictionPolicy {
    public static let defaultIdleSeconds: Double = 1800

    // Models at/above this download size are treated as "large" and never kept permanently resident:
    // Fastest pins a model forever, which is fine for the small default engine but would hold ~1.5–2 GB
    // for a Whisper/Qwen tier. The download size is a free, monotonic proxy for resident footprint — no
    // live memory probing. Balanced/Frugal are explicit user choices and pass through unchanged.
    public static let largeModelByteThreshold: Int64 = 1_000_000_000

    public static func effective(_ mode: Eviction, modelBytes: Int64) -> Eviction {
        if mode == .fastest && modelBytes >= largeModelByteThreshold { return .balanced }
        return mode
    }

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
}
