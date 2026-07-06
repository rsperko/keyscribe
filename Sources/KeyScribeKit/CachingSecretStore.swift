import Foundation

// In-memory cache in front of a secret backend (the Keychain) so a BYOK key is decrypted (and thus prompts
// the login keychain's ACL) at most once per process, not per rewrite. Concurrent cold reads of the same
// keyRef coalesce behind a per-keyRef load lock, so a race prompts once. The load runs outside the map lock
// (it can block on the ACL prompt), so a mutation can land mid-load; a per-key generation (set/delete) plus
// a global epoch (deleteAll) let the returning load drop its now-stale value instead of clobbering the
// mutation. Only successful decrypts are cached (a miss is cheap and stays re-readable, so an out-of-band
// key is still seen). Never persisted. Thread-safe via NSLock.
public final class CachingSecretStore: @unchecked Sendable {
    public struct Backend: Sendable {
        public var load: @Sendable (_ keyRef: String) -> String?
        public var save: @Sendable (_ secret: String, _ keyRef: String, _ cachedOld: String?) -> Bool
        public var remove: @Sendable (_ keyRef: String) -> Void
        public var removeAll: @Sendable () -> Int

        public init(
            load: @escaping @Sendable (String) -> String?,
            save: @escaping @Sendable (String, String, String?) -> Bool,
            remove: @escaping @Sendable (String) -> Void,
            removeAll: @escaping @Sendable () -> Int
        ) {
            self.load = load
            self.save = save
            self.remove = remove
            self.removeAll = removeAll
        }
    }

    private enum Probe {
        case hit(String)
        case miss(generation: Int, epoch: Int)
    }

    private let backend: Backend
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var loadLocks: [String: NSLock] = [:]
    private var generation: [String: Int] = [:]
    private var epoch = 0

    public init(backend: Backend) { self.backend = backend }

    public func get(_ keyRef: String) -> String? {
        if let cached = lock.withLock({ cache[keyRef] }) { return cached }
        let perKeyLoad = lock.withLock { loadLock(for: keyRef) }
        perKeyLoad.lock()
        defer { perKeyLoad.unlock() }

        let probe: Probe = lock.withLock {
            if let cached = cache[keyRef] { return .hit(cached) }
            return .miss(generation: generation[keyRef] ?? 0, epoch: epoch)
        }
        switch probe {
        case .hit(let value):
            return value
        case .miss(let capturedGeneration, let capturedEpoch):
            guard let secret = backend.load(keyRef) else { return nil }
            lock.withLock {
                if (generation[keyRef] ?? 0) == capturedGeneration, epoch == capturedEpoch {
                    cache[keyRef] = secret
                }
            }
            return secret
        }
    }

    @discardableResult
    public func set(_ secret: String, for keyRef: String) -> Bool {
        let cachedOld = lock.withLock { cache[keyRef] }
        let stored = backend.save(secret, keyRef, cachedOld)
        lock.withLock {
            generation[keyRef, default: 0] += 1
            cache[keyRef] = stored ? secret : nil
        }
        return stored
    }

    public func delete(_ keyRef: String) {
        backend.remove(keyRef)
        lock.withLock {
            generation[keyRef, default: 0] += 1
            cache[keyRef] = nil
        }
    }

    @discardableResult
    public func deleteAll() -> Int {
        let count = backend.removeAll()
        lock.withLock {
            epoch += 1
            cache.removeAll()
        }
        return count
    }

    private func loadLock(for keyRef: String) -> NSLock {
        if let existing = loadLocks[keyRef] { return existing }
        let created = NSLock()
        loadLocks[keyRef] = created
        return created
    }
}
