import Foundation

// A take is written to the temporary directory and deleted after transcription, so a crash mid-dictation
// strands raw speech there. Each name carries its writer's pid, so a take is abandoned exactly when that
// process is gone, and a take another running copy is still recording or transcribing is never touched.
enum CaptureLeftovers {
    static let prefix = "keyscribe-capture-"
    // Names from builds before the pid was recorded have no owner to check.
    static let legacyMinimumAge: TimeInterval = 600

    static func newURL(in dir: URL = FileManager.default.temporaryDirectory, pid: Int32 = getpid()) -> URL {
        dir.appendingPathComponent("\(prefix)\(pid)-\(UUID().uuidString).wav")
    }

    @discardableResult
    static func sweep(
        in dir: URL = FileManager.default.temporaryDirectory, now: Date = Date(),
        isAlive: (Int32) -> Bool = isRunning
    ) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        var removed = 0
        for file in files {
            guard let owner = owner(of: file.lastPathComponent),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            switch owner {
            case .process(let pid): guard !isAlive(pid) else { continue }
            case .unknown:
                guard let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= legacyMinimumAge else { continue }
            }
            guard (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private enum Owner {
        case process(Int32)
        case unknown
    }

    private static func owner(of name: String) -> Owner? {
        guard name.hasPrefix(prefix), name.hasSuffix(".wav") else { return nil }
        let stem = name.dropFirst(prefix.count).dropLast(".wav".count)
        if UUID(uuidString: String(stem)) != nil { return .unknown }
        guard let dash = stem.firstIndex(of: "-"), let pid = Int32(stem[..<dash]), pid > 0,
              UUID(uuidString: String(stem[stem.index(after: dash)...])) != nil else { return nil }
        return .process(pid)
    }
}
