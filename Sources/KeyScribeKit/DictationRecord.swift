import Foundation

// A cheap, high-signal fingerprint of text that crossed a pipeline boundary — used to verify exactly
// what text reached each stage and catch whitespace/encoding mangling WITHOUT logging the text
// itself. `hash` is FNV-1a 64-bit over the UTF-8 bytes; the counts catch grapheme/byte/whitespace
// drift the hash alone would only flag as "different". Pure and OS-free.
public struct TextFingerprint: Codable, Equatable, Sendable {
    public let hash: UInt64
    public let chars: Int
    public let bytes: Int
    public let newlines: Int
    public let tabs: Int

    public init(hash: UInt64, chars: Int, bytes: Int, newlines: Int, tabs: Int) {
        self.hash = hash
        self.chars = chars
        self.bytes = bytes
        self.newlines = newlines
        self.tabs = tabs
    }

    public static func of(_ text: String) -> TextFingerprint {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        var bytes = 0, newlines = 0, tabs = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
            bytes += 1
            if byte == 0x0A { newlines += 1 }
            if byte == 0x09 { tabs += 1 }
        }
        return TextFingerprint(hash: hash, chars: text.count, bytes: bytes, newlines: newlines, tabs: tabs)
    }

    public var hex: String { String(format: "%016llx", hash) }
}

// One structured, in-memory record of the most recent dictation, kept UNCONDITIONALLY (even when
// persistent history is off) so a dictation is auditable without logs — the reliable ground truth
// given that `os.Logger` / `log show` is unreliable on this machine (AGENTS).
//
// Privacy (hard footguns, design.md §4.2): the token→original map NEVER enters this record — only
// `issuedTokenCount` and the restored `final` fingerprint. Fingerprints and timings are safe to log;
// `humanSummary()` emits ONLY hashes, counts, and milliseconds — never transcript text. The struct
// MAY hold real text indirectly only via fingerprints (which are one-way hashes), never the text.
public struct DictationRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case inserted, copied, localFallback, noSpeech, failed
    }

    // Wall-clock stage timings, stamped by the app layer (the clock stays out of this pure type).
    // Ordered chronologically: `arm` is press→mic-live, `modelWait` is the commit-time load await.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case arm, drain, modelWait, transcribe, streamFinalize, localProcess, rewrite, insert
    }

    // The text boundaries a fingerprint is taken at, in pipeline order.
    public enum Boundary: String, Codable, Sendable, CaseIterable {
        case raw, localProcessed, sentToLLM, llmOut, final
    }

    public var modeName: String
    public var outcome: Outcome?
    public var stageMillis: [Stage: Double]
    public var fingerprints: [Boundary: TextFingerprint]
    public var audioSeconds: Double?
    public var cloudInvolved: Bool
    public var redaction: Bool
    public var issuedTokenCount: Int
    public var connection: String?
    public var model: String?
    public var error: String?
    public var targetBundleId: String?
    public var fallbackReason: String?

    public init(modeName: String) {
        self.modeName = modeName
        self.outcome = nil
        self.stageMillis = [:]
        self.fingerprints = [:]
        self.audioSeconds = nil
        self.cloudInvolved = false
        self.redaction = false
        self.issuedTokenCount = 0
        self.connection = nil
        self.model = nil
        self.error = nil
        self.targetBundleId = nil
        self.fallbackReason = nil
    }

    // Real-time factor: how long STT took relative to the audio it transcribed (< 1 is faster than
    // real time). nil unless both a transcribe time and a positive audio duration are known.
    public var rtf: Double? {
        guard let transcribe = stageMillis[.transcribe], let audio = audioSeconds, audio > 0 else { return nil }
        return (transcribe / 1000) / audio
    }

    // One line, hashes + counts + milliseconds + metadata, NO transcript text. Safe to log.
    public func humanSummary() -> String {
        var parts: [String] = [modeName, outcome?.rawValue ?? "incomplete"]

        let stages = Stage.allCases.compactMap { stage -> String? in
            stageMillis[stage].map { "\(stage.rawValue) \(Int($0.rounded()))ms" }
        }
        if !stages.isEmpty { parts.append(stages.joined(separator: " ")) }

        let prints = Boundary.allCases.compactMap { boundary -> String? in
            fingerprints[boundary].map { "\(boundary.rawValue)=\($0.hex.prefix(8))(\($0.chars)c/\($0.bytes)b)" }
        }
        if !prints.isEmpty { parts.append(prints.joined(separator: " ")) }

        if let audio = audioSeconds {
            var av = String(format: "audio %.2fs", audio)
            if let rtf { av += String(format: " rtf %.2f", rtf) }
            parts.append(av)
        }

        if cloudInvolved {
            var cloud = "cloud conn=\(connection ?? "?") model=\(model ?? "?") tokens=\(issuedTokenCount)"
            if redaction { cloud += " redaction" }
            parts.append(cloud)
        } else {
            parts.append("local")
        }

        if let targetBundleId { parts.append("target=\(targetBundleId)") }
        if let fallbackReason { parts.append("fallback=\(fallbackReason)") }
        if let error { parts.append("error=\(error)") }

        return parts.joined(separator: " · ")
    }
}
