import Foundation

// Pure retention decision for the archived capture WAVs: given the archive's files and a byte budget,
// return the names to delete, newest kept first. The listing is passed in (not read from the filesystem)
// so this stays deterministic.
public enum CaptureRetention {
    public struct File: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let modified: Date

        public init(name: String, bytes: Int64, modified: Date) {
            self.name = name
            self.bytes = bytes
            self.modified = modified
        }
    }

    public static func expired(files: [File], maxBytes: Int64) -> [String] {
        let newestFirst = files.sorted {
            $0.modified == $1.modified ? $0.name > $1.name : $0.modified > $1.modified
        }
        var retained: Int64 = 0
        var expired: [String] = []
        for (index, file) in newestFirst.enumerated() {
            retained += file.bytes
            // The newest capture is retained unconditionally: a single take can exceed the whole budget, and
            // deleting it would leave nothing to inspect — the one thing the archive exists for.
            guard index > 0, retained > maxBytes else { continue }
            retained -= file.bytes
            expired.append(file.name)
        }
        return expired
    }
}
