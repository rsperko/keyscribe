import Foundation
import Testing
@testable import KeyScribeKit

private final class InMemoryPersistence: PendingSystemRestorePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    func read() -> Data? { lock.withLock { data } }

    func write(_ data: Data?) {
        lock.withLock {
            self.data = data
            if data == nil { deleteCount += 1 } else { writeCount += 1 }
        }
    }
}

struct PendingSystemRestoreModelTests {
    @Test func isEmptyOnlyWhenAllFieldsNil() {
        #expect(PendingSystemRestore().isEmpty)
        #expect(!PendingSystemRestore(defaultInputUID: "uid").isEmpty)
        #expect(!PendingSystemRestore(outputMute: .init(deviceUID: "out", previousMute: 0)).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let state = PendingSystemRestore(
            defaultInputUID: "BuiltInMicrophoneDevice",
            outputMute: .init(deviceUID: "BuiltInSpeakerDevice", previousMute: 0))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PendingSystemRestore.self, from: data)
        #expect(decoded == state)
    }
}

struct PendingSystemRestoreStoreTests {
    @Test func loadOnEmptyPersistenceIsEmpty() {
        let store = PendingSystemRestoreStore(persistence: InMemoryPersistence())
        #expect(store.load().isEmpty)
    }

    @Test func updatePersistsAndReloads() {
        let store = PendingSystemRestoreStore(persistence: InMemoryPersistence())
        store.update { $0.defaultInputUID = "headset-uid" }
        #expect(store.load().defaultInputUID == "headset-uid")
    }

    // The two writers (audio control queue / main actor) touch different fields; a field update must not
    // clobber the other field even though each does a full read-modify-write of the same file.
    @Test func independentFieldUpdatesDoNotClobber() {
        let store = PendingSystemRestoreStore(persistence: InMemoryPersistence())
        store.update { $0.defaultInputUID = "headset-uid" }
        store.update { $0.outputMute = .init(deviceUID: "out-uid", previousMute: 0) }

        let state = store.load()
        #expect(state.defaultInputUID == "headset-uid")
        #expect(state.outputMute == .init(deviceUID: "out-uid", previousMute: 0))
    }

    @Test func clearingOneFieldLeavesTheOther() {
        let store = PendingSystemRestoreStore(persistence: InMemoryPersistence())
        store.update { $0.defaultInputUID = "headset-uid" }
        store.update { $0.outputMute = .init(deviceUID: "out-uid", previousMute: 0) }

        store.update { $0.defaultInputUID = nil }

        let state = store.load()
        #expect(state.defaultInputUID == nil)
        #expect(state.outputMute == .init(deviceUID: "out-uid", previousMute: 0))
    }

    // A clean run must leave NO marker behind, or launch reconcile would restore stale state every time.
    @Test func clearingAllFieldsDeletesTheFile() {
        let persistence = InMemoryPersistence()
        let store = PendingSystemRestoreStore(persistence: persistence)
        store.update { $0.defaultInputUID = "headset-uid" }
        store.update { $0.defaultInputUID = nil }

        #expect(store.load().isEmpty)
        #expect(persistence.read() == nil)
        #expect(persistence.deleteCount >= 1)
    }

    @Test func fileBackedPersistenceRoundTripsAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-pending-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("pending-system-restore.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PendingSystemRestoreStore(
            persistence: FilePendingSystemRestorePersistence(url: url))
        store.update { $0.outputMute = .init(deviceUID: "out-uid", previousMute: 1) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.load().outputMute?.previousMute == 1)

        store.update { $0.outputMute = nil }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
