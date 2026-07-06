import Foundation

// Optional injected one-time config import from a legacy app. KeyScribe ships no importer; this is a seam so
// a build can populate its config directory before KeyScribe seeds or loads defaults. None injected =
// bootstrap unchanged.
public protocol LegacyConfigImporter {
    // Runs before KeyScribe writes or loads default config. Host calls it at most once, on first run before
    // `supportDir` exists. Implementations may re-check and no-op.
    func importIfNeeded(into supportDir: URL) throws
}
