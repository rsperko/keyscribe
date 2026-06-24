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
}

public enum EvictionCopy {
    // Below this footprint, reloading is fast enough that the policy choice barely matters, so the
    // footer says so instead of weighing memory against speed. Moonshine (~141 MB) lands here.
    public static let smallModelBytes: Int64 = 200_000_000

    public static func footer(
        policy: Eviction, modelName: String, bytes: Int64, systemManaged: Bool, idleLabel: String
    ) -> String {
        if systemManaged {
            return "\(modelName) is managed by macOS, so this setting does not change its memory use."
        }
        let size = formatBytes(bytes)
        if bytes > 0 && bytes < smallModelBytes {
            return "\(modelName) is small (~\(size)) and reloads almost instantly — Balanced and Frugal cost you little here."
        }
        switch policy {
        case .fastest:
            return "Keeps \(modelName) loaded (~\(size) on disk, similar in memory). Every dictation starts instantly."
        case .balanced:
            return "Keeps \(modelName) loaded (~\(size)), then frees it after \(idleLabel) idle. The next dictation reloads it with a brief delay."
        case .frugal:
            return "Frees \(modelName)’s ~\(size) after each dictation and reloads it next time — lowest memory use, with a brief delay before each."
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
