import Foundation
import Testing
@testable import KeyScribeKit

private final class FakeSecretBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String]
    private(set) var loadCalls: [String] = []
    private(set) var saveCalls: [(secret: String, keyRef: String, cachedOld: String?)] = []
    private(set) var removeCalls: [String] = []
    private(set) var removeAllCalls = 0
    var saveShouldSucceed = true

    init(_ seed: [String: String] = [:]) { store = seed }

    var loadResult: SecretLookup?

    func backend() -> CachingSecretStore.Backend {
        CachingSecretStore.Backend(
            load: { [self] keyRef in
                lock.withLock {
                    loadCalls.append(keyRef)
                    if let loadResult { return loadResult }
                    return store[keyRef].map(SecretLookup.found) ?? .absent
                }
            },
            save: { [self] secret, keyRef, cachedOld in
                lock.withLock {
                    saveCalls.append((secret, keyRef, cachedOld))
                    guard saveShouldSucceed else { return false }
                    store[keyRef] = secret
                    return true
                }
            },
            remove: { [self] keyRef in
                lock.withLock {
                    removeCalls.append(keyRef)
                    store[keyRef] = nil
                }
            },
            removeAll: { [self] in
                lock.withLock {
                    removeAllCalls += 1
                    let n = store.count
                    store.removeAll()
                    return n
                }
            }
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func append(_ item: String?) { lock.withLock { items.append(item) } }
    var values: [String?] { lock.withLock { items } }
}

// A backend whose FIRST load blocks (having snapshotted the value at entry) until released, so a test
// can slip a mutation in while a cold load is in flight and prove the returning stale load is dropped.
// Later loads do not block, so post-race verification reads run freely.
private final class RaceHarness: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    private var loadCount = 0

    init(_ initial: String?) { value = initial }

    var stored: String? { lock.withLock { value } }

    func backend() -> CachingSecretStore.Backend {
        CachingSecretStore.Backend(
            load: { [self] _ in
                let (snapshot, isFirst) = lock.withLock { () -> (String?, Bool) in
                    loadCount += 1
                    return (value, loadCount == 1)
                }
                if isFirst {
                    entered.signal()
                    release.wait()
                }
                return snapshot.map(SecretLookup.found) ?? .absent
            },
            save: { [self] secret, _, _ in lock.withLock { value = secret }; return true },
            remove: { [self] _ in lock.withLock { value = nil } },
            removeAll: { [self] in lock.withLock { let n = value == nil ? 0 : 1; value = nil; return n } }
        )
    }
}

@Suite struct CachingSecretStoreTests {
    @Test func getReadsBackendOnceThenServesFromCache() {
        let fake = FakeSecretBackend(["keyscribe.llm.fast": "sk-secret"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("keyscribe.llm.fast") == "sk-secret")
        #expect(store.get("keyscribe.llm.fast") == "sk-secret")

        #expect(fake.loadCalls == ["keyscribe.llm.fast"])
    }

    @Test func getDoesNotCacheAMiss() {
        let fake = FakeSecretBackend()
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("absent") == nil)
        #expect(store.get("absent") == nil)

        #expect(fake.loadCalls == ["absent", "absent"])
    }

    @Test func setPopulatesCacheSoTheNextGetSkipsTheBackend() {
        let fake = FakeSecretBackend()
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.set("sk-new", for: "keyscribe.llm.fast"))
        #expect(store.get("keyscribe.llm.fast") == "sk-new")

        #expect(fake.loadCalls.isEmpty)
    }

    @Test func setPassesTheCachedOldValueToTheBackendWhenWarm() {
        let fake = FakeSecretBackend(["k": "old"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("k") == "old")
        #expect(store.set("new", for: "k"))

        #expect(fake.saveCalls.count == 1)
        #expect(fake.saveCalls[0].cachedOld == "old")
    }

    @Test func setPassesNilCachedOldWhenTheCacheIsCold() {
        let fake = FakeSecretBackend(["k": "old"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.set("new", for: "k"))

        #expect(fake.saveCalls.count == 1)
        #expect(fake.saveCalls[0].cachedOld == nil)
    }

    @Test func failedSetInvalidatesTheCacheSoTheNextGetReReads() {
        let fake = FakeSecretBackend(["k": "old"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("k") == "old")
        fake.saveShouldSucceed = false
        #expect(store.set("new", for: "k") == false)

        #expect(store.get("k") == "old")
        #expect(fake.loadCalls == ["k", "k"])
    }

    @Test func deleteInvalidatesTheCache() {
        let fake = FakeSecretBackend(["k": "v"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("k") == "v")
        store.delete("k")

        #expect(store.get("k") == nil)
        #expect(fake.removeCalls == ["k"])
        #expect(fake.loadCalls == ["k", "k"])
    }

    @Test func concurrentColdReadsOfTheSameKeyRefDecryptOnlyOnce() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loadCount = Counter()
        let results = Collector()

        let store = CachingSecretStore(backend: CachingSecretStore.Backend(
            load: { _ in
                loadCount.increment()
                entered.signal()
                release.wait()
                return .found("sk-secret")
            },
            save: { _, _, _ in true },
            remove: { _ in },
            removeAll: { 0 }
        ))

        let group = DispatchGroup()
        func read() {
            group.enter()
            DispatchQueue.global().async {
                let value = store.get("k")
                results.append(value)
                group.leave()
            }
        }

        read()
        entered.wait()
        read()
        Thread.sleep(forTimeInterval: 0.1)
        release.signal()
        release.signal()
        group.wait()

        #expect(loadCount.value == 1)
        #expect(results.values.count == 2)
        #expect(results.values.allSatisfy { $0 == "sk-secret" })
    }

    @Test func aSetRacingAnInFlightColdLoadIsNotClobbered() {
        let harness = RaceHarness("OLD")
        let store = CachingSecretStore(backend: harness.backend())
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { _ = store.get("k"); group.leave() }
        harness.entered.wait()
        #expect(store.set("NEW", for: "k"))
        harness.release.signal()
        group.wait()

        #expect(store.get("k") == "NEW")
        #expect(harness.stored == "NEW")
    }

    @Test func aDeleteRacingAnInFlightColdLoadIsNotResurrected() {
        let harness = RaceHarness("OLD")
        let store = CachingSecretStore(backend: harness.backend())
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { _ = store.get("k"); group.leave() }
        harness.entered.wait()
        store.delete("k")
        harness.release.signal()
        group.wait()

        #expect(store.get("k") == nil)
        #expect(harness.stored == nil)
    }

    @Test func aDeleteAllRacingAnInFlightColdLoadIsNotResurrected() {
        let harness = RaceHarness("OLD")
        let store = CachingSecretStore(backend: harness.backend())
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { _ = store.get("k"); group.leave() }
        harness.entered.wait()
        #expect(store.deleteAll() == 1)
        harness.release.signal()
        group.wait()

        #expect(store.get("k") == nil)
        #expect(harness.stored == nil)
    }

    @Test func lookupSurfacesDenialWithoutCachingIt() {
        let fake = FakeSecretBackend()
        fake.loadResult = .denied(status: -25308)
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.lookup("k") == .denied(status: -25308))
        #expect(store.get("k") == nil)
        #expect(fake.loadCalls == ["k", "k"])
    }

    @Test func deleteAllClearsEveryCachedEntryAndReturnsTheCount() {
        let fake = FakeSecretBackend(["a": "1", "b": "2"])
        let store = CachingSecretStore(backend: fake.backend())

        #expect(store.get("a") == "1")
        #expect(store.get("b") == "2")
        #expect(store.deleteAll() == 2)

        #expect(store.get("a") == nil)
        #expect(store.get("b") == nil)
        #expect(fake.removeAllCalls == 1)
        #expect(fake.loadCalls == ["a", "b", "a", "b"])
    }
}
