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

    // Replace every ⟦SN:…⟧ token with its original in a single linear scan, repeating only while a
    // round actually restores something — so a restored original that itself contains a token (a
    // redaction span captured around an earlier verbatim token) still unwinds. order has no cycles
    // (a token's original predates the token), so the fixpoint converges in passes equal to the
    // nesting depth (≤2 in practice) rather than the previous one-full-pass-per-token loop.
    public func restore(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !originals.isEmpty else { return text }
        var result = text
        while result.contains(Self.tokenOpen) {
            var didRestore = false
            var out = ""
            out.reserveCapacity(result.count)
            var cursor = result.startIndex
            while let open = result.range(of: Self.tokenOpen, range: cursor..<result.endIndex),
                  let close = result.range(of: Self.tokenClose, range: open.upperBound..<result.endIndex) {
                let token = String(result[open.lowerBound..<close.upperBound])
                out += result[cursor..<open.lowerBound]
                if let original = originals[token] {
                    out += original
                    didRestore = true
                } else {
                    out += token
                }
                cursor = close.upperBound
            }
            out += result[cursor..<result.endIndex]
            result = out
            if !didRestore { break }
        }
        return result
    }

    private static let tokenOpen = "⟦SN:"
    private static let tokenClose = "⟧"
}
