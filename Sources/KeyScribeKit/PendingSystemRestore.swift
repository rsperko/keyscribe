import Foundation

// Legacy marker for global macOS audio state that earlier builds changed during dictation and might have
// stranded after a crash. Current builds only decode, reconcile, and clear it. Identity is by stable device
// UID, never transient AudioDeviceID.
public struct PendingSystemRestore: Codable, Equatable, Sendable {
    // The user's original system default input device UID from a legacy marker.
    public var defaultInputUID: String?
    // Output mute marker decoded from earlier builds. Never encoded by current builds.
    public var legacyMutedOutputUID: String?

    public init(defaultInputUID: String? = nil, legacyMutedOutputUID: String? = nil) {
        self.defaultInputUID = defaultInputUID
        self.legacyMutedOutputUID = legacyMutedOutputUID
    }

    public var isEmpty: Bool { defaultInputUID == nil && legacyMutedOutputUID == nil }

    enum CodingKeys: String, CodingKey {
        case defaultInputUID
        case outputMute
    }

    private struct LegacyOutputMute: Decodable { let deviceUID: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultInputUID = try c.decodeIfPresent(String.self, forKey: .defaultInputUID)
        legacyMutedOutputUID =
            (try? c.decodeIfPresent(LegacyOutputMute.self, forKey: .outputMute))??.deviceUID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(defaultInputUID, forKey: .defaultInputUID)
    }
}

// The on-disk read side of the store, behind a seam so the merge/clear logic can be unit-tested without
// touching the filesystem. `read` returns the raw bytes (nil if absent); `write(nil)` deletes.
public protocol PendingSystemRestorePersisting: Sendable {
    func read() -> Data?
    func write(_ data: Data?)
}

// Thread-safe read-modify-write over the marker. Every change goes through `update`, which reloads under
// the lock and mutates, so concurrent writers cannot clobber each other. When the resulting state is empty
// the file is deleted, so a clean run never leaves a stale marker for launch to reconcile.
public final class PendingSystemRestoreStore: @unchecked Sendable {
    private let persistence: PendingSystemRestorePersisting
    private let lock = NSLock()

    public init(persistence: PendingSystemRestorePersisting) {
        self.persistence = persistence
    }

    public func load() -> PendingSystemRestore {
        lock.withLock { readLocked() }
    }

    public func update(_ mutate: (inout PendingSystemRestore) -> Void) {
        lock.withLock {
            var state = readLocked()
            mutate(&state)
            if state.isEmpty {
                persistence.write(nil)
            } else if let data = try? JSONEncoder().encode(state) {
                persistence.write(data)
            }
        }
    }

    private func readLocked() -> PendingSystemRestore {
        guard let data = persistence.read(),
              let state = try? JSONDecoder().decode(PendingSystemRestore.self, from: data) else {
            return PendingSystemRestore()
        }
        return state
    }
}

// File-backed persistence. Writes atomically (so a crash mid-write never leaves a half-written marker that
// would fail to decode and silently drop a needed restore) and creates the parent directory on demand.
public struct FilePendingSystemRestorePersistence: PendingSystemRestorePersisting {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> Data? { try? Data(contentsOf: url) }

    public func write(_ data: Data?) {
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
