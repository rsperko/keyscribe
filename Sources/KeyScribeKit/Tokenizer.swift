import Foundation

// Stateful nonce tokenization shared by verbatim and redaction (design.md §4.2). A span is
// replaced with a type+index token (⟦SN:REDACT:1⟧, ⟦SN:VERB:1⟧); the same value within one
// dictation always maps to the same token, distinct values get distinct indices. The
// token→original map lives ONLY here in memory — it is never written to history or logs — and is
// applied in reverse (LIFO) after the LLM returns so nested/overlapping spans unwind correctly.
// Confined to a single dictation but held by Sendable pipeline stages, so it locks its mutable
// state (same pattern as RegexCache) and is @unchecked Sendable.
public final class Tokenizer: @unchecked Sendable {
    public enum TokenType: String, Sendable {
        case redact = "REDACT"
        case verbatim = "VERB"
    }

    private var originals: [String: String] = [:]   // token → original value
    private var byValue: [String: String] = [:]      // type+value → token (stability)
    private var order: [String] = []                 // allocation order (LIFO restore)
    private var counters: [TokenType: Int] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func tokenize(_ value: String, type: TokenType) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(type.rawValue)\u{1}\(value)"
        if let existing = byValue[key] { return existing }
        let n = (counters[type] ?? 0) + 1
        counters[type] = n
        let token = "⟦SN:\(type.rawValue):\(n)⟧"
        originals[token] = value
        byValue[key] = token
        order.append(token)
        return token
    }

    public var issuedTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    public func restore(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        var result = text
        for token in order.reversed() {
            guard let original = originals[token] else { continue }
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }
}
