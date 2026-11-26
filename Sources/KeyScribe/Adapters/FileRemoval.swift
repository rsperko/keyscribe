import Foundation

extension FileManager {
    func removeIfPresent(_ url: URL) -> Bool {
        do {
            try removeItem(at: url)
            return true
        } catch {
            return isMissing(url)
        }
    }

    func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
}
