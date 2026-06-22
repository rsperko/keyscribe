import Foundation

// Compiles each regex pattern once and memoizes it. The pipeline stages, tokenizers, and resolver
// all run regexes on the dictation hot path with patterns that repeat across dictations — the
// static redaction/sentinel patterns are constant, and the config-derived trigger phrases, URL
// patterns, and replacement rules are stable (config is cached). Compiling `NSRegularExpression`
// per call re-parses the pattern every time; this does it once. Invalid patterns are memoized too,
// so a malformed user rule is not re-parsed on every dictation it runs in. Thread-safe; the pattern
// set is bounded by the static patterns plus the user's config, so no eviction is needed.
public enum RegexCache {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var failed: Set<String> = []
    private static let lock = NSLock()

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

    #if DEBUG
    static func isKnownInvalid(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        let key = "\(options.rawValue)\u{1}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        return failed.contains(key)
    }
    #endif
}
