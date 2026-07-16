import Foundation

// Compiles each regex pattern once and memoizes it. The hot-path patterns repeat across dictations
// (static redaction/sentinel patterns, and cached config-derived triggers/URLs/replacements), and
// `NSRegularExpression` re-parses per construction. Invalid patterns are memoized too, so a malformed user
// rule isn't re-parsed every dictation. Thread-safe; bounded by static + config patterns, so no eviction.
public enum RegexCache {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var failed: Set<String> = []
    private static let lock = NSLock()

    // Compile-check without memoizing — for interactive validation, so transient input never fills the cache.
    public static func isValidPattern(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: options)) != nil
    }

    public static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)\u{1}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            failed.insert(key)
            return nil
        }
        cache[key] = compiled
        return compiled
    }

    public static func routingRegex(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        guard ReplacementSafety.isSafe(pattern) else { return nil }
        return regex(pattern, options: options)
    }

    #if DEBUG
    static func isKnownInvalid(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        let key = "\(options.rawValue)\u{1}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        return failed.contains(key)
    }
    #endif
}
