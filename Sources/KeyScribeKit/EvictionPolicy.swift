import Foundation

public enum EvictionDecision: Equatable, Sendable {
    case keepLoaded
    case evictNow
    case scheduleIdleCheck(afterSeconds: Double)
}

public enum EvictionPolicy {
    public static let defaultIdleSeconds: Double = 120

    // The Fastest profile keeps the engine resident (afterDictation → .keepLoaded), but nothing
    // preloads it, so the very first press still paid a cold load. Preload at launch for that profile
    // only; Balanced/Frugal stay lazy.
    public static func preloadAtLaunch(mode: Eviction) -> Bool { mode == .fastest }

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
