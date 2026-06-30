import Foundation

// A durable record of GLOBAL macOS state KeyScribe has temporarily changed for the duration of a
// dictation and MUST put back: the system default input device (while we override it to honor a preferred
// mic the AUHAL cannot pin). Restore normally runs in-process on the dictation's teardown path — but a
// crash (the 0.1.7 SIGSEGV), SIGKILL, force-quit, or panic kills the process first, stranding the change
// system-wide: a hijacked default mic, with no recovery. This marker is written BEFORE the change and
// cleared AFTER the restore, so the next launch can reconcile — any field still present means we died
// dirty. (Output silencing is NOT recorded here: it uses process-scoped ducking, which the OS releases
// automatically on process exit, so a crash cannot strand it — no marker needed.)
//
// Identity is by device UID (stable across reconnect/reboot), never AudioDeviceID (transient, so a stored
// AudioDeviceID could resolve to a different device after a reboot).
public struct PendingSystemRestore: Codable, Equatable, Sendable {
    // The user's original system default INPUT device UID, saved while we override it. nil = not overridden.
    public var defaultInputUID: String?
    // Set ONLY when decoding an OLDER build's marker that recorded an output-MUTE strand (the common legacy
    // shape, since most runs override no input). This build silences via ducking, which the OS releases on
    // exit and never strands — so it never writes this. It exists so launch reconcile can unmute a
    // pre-upgrade strand once, then clear the marker. Never encoded: a clean run stays clean.
    // Remove once no pre-duck markers remain in the wild.
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
