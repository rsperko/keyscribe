import Foundation

// Optional, injected one-time import of configuration from a different legacy app. KeyScribe ships no
// importer; this is a seam so a build can populate its config directory before KeyScribe seeds or
// loads its own defaults. Default is no importer injected, in which case bootstrap is unchanged.
public protocol LegacyConfigImporter {
    // Runs before KeyScribe writes or loads its default config. The host calls this at most once —
    // on first run, before `supportDir` exists. Implementations may re-check and no-op as needed.
    func importIfNeeded(into supportDir: URL) throws
}
