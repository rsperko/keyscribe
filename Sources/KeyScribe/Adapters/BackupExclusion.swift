import Foundation

// The exclusion xattr sits on the directory and covers its contents, so excluding `models/` covers every
// engine's weights without touching each subdir.
enum BackupExclusion {
    @discardableResult
    static func exclude(_ url: URL) -> Bool {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            Log.models.error(
                "backup exclusion failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
