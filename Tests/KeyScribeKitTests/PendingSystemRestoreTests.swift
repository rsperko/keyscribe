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
    @Test func isEmptyOnlyWhenInputUIDNil() {
        #expect(PendingSystemRestore().isEmpty)
        #expect(!PendingSystemRestore(defaultInputUID: "uid").isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let state = PendingSystemRestore(defaultInputUID: "BuiltInMicrophoneDevice")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PendingSystemRestore.self, from: data)
        #expect(decoded == state)
    }

    // An older (pre-duck) build wrote an `outputMute` object; decoding such a marker must keep the input
    // restore AND surface the muted device UID so launch reconcile can unmute the pre-upgrade strand.
    @Test func decodingCapturesLegacyOutputMuteForRecovery() throws {
        let legacy = #"{"defaultInputUID":"mic","outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try JSONDecoder().decode(PendingSystemRestore.self, from: Data(legacy.utf8))
        #expect(decoded.defaultInputUID == "mic")
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    // An output-only legacy marker (the common shape — no input override) must not decode as empty, or
    // reconcile would skip it and leave the user stranded muted.
    @Test func outputOnlyLegacyMarkerIsNotEmpty() throws {
        let legacy = #"{"outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try JSONDecoder().decode(PendingSystemRestore.self, from: Data(legacy.utf8))
        #expect(!decoded.isEmpty)
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    // The legacy field is never written back: a current run silences via ducking and must leave a clean
    // marker, so re-encoding a state must not resurrect an `outputMute` key.
    @Test func legacyOutputMuteIsNeverReEncoded() throws {
        var state = PendingSystemRestore(defaultInputUID: "mic")
        state.legacyMutedOutputUID = "out"
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!json.contains("outputMute"))
        #expect(!json.contains("out"))
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

    // A clean run must leave NO marker behind, or launch reconcile would restore stale state every time.
    @Test func clearingTheFieldDeletesTheFile() {
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
        store.update { $0.defaultInputUID = "headset-uid" }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.load().defaultInputUID == "headset-uid")

        store.update { $0.defaultInputUID = nil }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
