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

// The hard post-LLM gate (design.md §4.2). A dropped redaction token leaks the protected span and
// a dropped verbatim token corrupts the insert, so this is a safety check, not normalization:
// every issued nonce token must return exactly once (unless the mode allows deletion), the model
// must not invent sentinel-like tokens we never issued, and the output must be non-empty.
public enum ValidationGate {
    private static let sentinelPattern = "⟦SN:[^⟧]*⟧"

    public static func check(output: String, issuedTokens: [String], allowDeletion: Bool = false) -> GateVerdict {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .fail(.empty) }

        for token in issuedTokens {
            let count = occurrences(of: token, in: output)
            if count > 1 { return .fail(.duplicatedToken(token)) }
            if count == 0 && !allowDeletion { return .fail(.missingToken(token)) }
        }

        let issued = Set(issuedTokens)
        for found in sentinels(in: output) where !issued.contains(found) {
            return .fail(.strayToken(found))
        }
        return .pass
    }

    // On failure: one stricter retry, then fall back to the local un-rewritten text (never insert
    // partially-restored text).
    public static func recovery(attempt: Int) -> GateRecovery {
        attempt == 0 ? .retryStricter : .localFallback
    }

    private static func occurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }

    private static func sentinels(in text: String) -> [String] {
        guard let re = RegexCache.regex(sentinelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
