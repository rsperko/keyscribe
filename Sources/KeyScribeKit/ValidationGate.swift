import Foundation

public enum GateFailure: Equatable, Sendable {
    case empty
    case missingToken(String)
    case duplicatedToken(String)
    case strayToken(String)
}

public enum GateVerdict: Equatable, Sendable {
    case pass
    case fail(GateFailure)
}

public enum GateRecovery: Equatable, Sendable {
    case retryStricter
    case localFallback
}

// The hard post-LLM gate (design.md §4.2). A dropped redaction token leaks the protected span and a dropped
// verbatim token corrupts the insert, so this is a safety check, not normalization: every required nonce token
// must return exactly once (unless the mode allows deletion), no invented sentinel-like tokens, non-empty output.
public enum ValidationGate {
    private static let sentinelPattern = "⟦SN:[^⟧]*⟧"

    // `allowedTokens` (selection-mode instruction redaction) are never required, but one occurrence isn't
    // stray; more than one is still ambiguous restore and fails.
    public static func check(
        output: String, issuedTokens: [String], allowedTokens: [String] = [], allowDeletion: Bool = false
    ) -> GateVerdict {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .fail(.empty) }

        // One regex pass finds every sentinel-shaped span, so a count map answers presence/duplication
        // without a scan per issued token. The stray check iterates matches in document order.
        let found = sentinels(in: output)
        var counts: [String: Int] = [:]
        for sentinel in found { counts[sentinel, default: 0] += 1 }

        for token in issuedTokens {
            let count = counts[token] ?? 0
            if count > 1 { return .fail(.duplicatedToken(token)) }
            if count == 0 && !allowDeletion { return .fail(.missingToken(token)) }
        }
        for token in allowedTokens where (counts[token] ?? 0) > 1 {
            return .fail(.duplicatedToken(token))
        }

        let issued = Set(issuedTokens).union(allowedTokens)
        for sentinel in found where !issued.contains(sentinel) {
            return .fail(.strayToken(sentinel))
        }
        return .pass
    }

    // On failure: one stricter retry, then fall back to local un-rewritten text (never insert
    // partially-restored text).
    public static func recovery(attempt: Int) -> GateRecovery {
        attempt == 0 ? .retryStricter : .localFallback
    }

    private static func sentinels(in text: String) -> [String] {
        guard let re = RegexCache.regex(sentinelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
