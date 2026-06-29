import Foundation

// A durable record of GLOBAL macOS state KeyScribe has temporarily changed for the duration of a
// dictation and MUST put back: the system default input device (while we override it to honor a preferred
// mic the AUHAL cannot pin) and the output device's mute flag (while we mute during dictation). Restore
// normally runs in-process on the dictation's teardown path — but a crash (the 0.1.7 SIGSEGV), SIGKILL,
// force-quit, or panic kills the process first, stranding the change system-wide: a hijacked default mic,
// a muted output, with no recovery. This marker is written BEFORE each change and cleared AFTER the
// restore, so the next launch can reconcile — any field still present means we died dirty. Output mute
// is recorded only when KeyScribe changed an audible output to muted; if output was already muted, there
// is nothing for crash recovery to put back.
//
// Identity is by device UID (stable across reconnect/reboot), never AudioDeviceID (transient, so a stored
// AudioDeviceID could resolve to a different device after a reboot).
public struct PendingSystemRestore: Codable, Equatable, Sendable {
    public struct OutputMute: Codable, Equatable, Sendable {
        public var deviceUID: String
        public var previousMute: UInt32
        public init(deviceUID: String, previousMute: UInt32) {
            self.deviceUID = deviceUID
            self.previousMute = previousMute
        }
    }

    // The user's original system default INPUT device UID, saved while we override it. nil = not overridden.
    public var defaultInputUID: String?
    // The output device KeyScribe muted from an audible state. nil = we did not change audible output.
    public var outputMute: OutputMute?

    public init(defaultInputUID: String? = nil, outputMute: OutputMute? = nil) {
        self.defaultInputUID = defaultInputUID
        self.outputMute = outputMute
    }

    public var isEmpty: Bool { defaultInputUID == nil && outputMute == nil }
}

// The on-disk read side of the store, behind a seam so the merge/clear logic can be unit-tested without
// touching the filesystem. `read` returns the raw bytes (nil if absent); `write(nil)` deletes.
public protocol PendingSystemRestorePersisting: Sendable {
    func read() -> Data?
    func write(_ data: Data?)
}

// Thread-safe read-modify-write over the marker. The audio control queue (default-input swap) and the
// main actor (output mute) update DIFFERENT fields concurrently, so every change goes through `update`,
// which reloads under the lock and merges — neither writer can clobber the other's field. When the merged
// state is empty the file is deleted, so a clean run never leaves a stale marker for launch to reconcile.
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
