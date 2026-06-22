import Foundation

// Compiles each regex pattern once and memoizes it. The pipeline stages, tokenizers, and resolver
// all run regexes on the dictation hot path with patterns that repeat across dictations — the
// static redaction/sentinel patterns are constant, and the config-derived trigger phrases, URL
// patterns, and replacement rules are stable (config is cached). Compiling `NSRegularExpression`
// per call re-parses the pattern every time; this does it once. Thread-safe; the pattern set is
// bounded by the static patterns plus the user's config, so no eviction is needed.
public enum RegexCache {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    public static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)\u{1}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = compiled
        return compiled
    }
}
