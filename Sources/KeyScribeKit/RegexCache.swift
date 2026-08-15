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

    // Memoized like the compiled regexes above, and for the same reason: routing asks the same handful of
    // config patterns repeatedly within one dictation (ModeResolver.requiresURLContext walks every mode's
    // constraints), and re-deriving the verdict each time re-scanned the whole pattern on the main actor.
    nonisolated(unsafe) private static var safetyVerdicts: [String: Bool] = [:]

    public static func routingRegex(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let safe = lock.withLock { safetyVerdicts[pattern] }
            ?? {
                let verdict = ReplacementSafety.isSafe(pattern)
                lock.withLock { safetyVerdicts[pattern] = verdict }
                return verdict
            }()
        guard safe else { return nil }
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
