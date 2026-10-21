import Foundation
import Testing
@testable import KeyScribeKit

private func entry(_ heard: String, at seconds: TimeInterval = 0) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
        modeName: "Notes", heard: heard, result: heard, outcome: .inserted,
        cloudInvolved: false, redaction: false, contextCategories: [])
}

private func tempStore() -> HistoryStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return HistoryStore(supportDir: dir)
}

private func file(_ store: HistoryStore, _ day: String) -> URL {
    store.dir.appendingPathComponent("\(day).jsonl")
}

struct HistorySnapshotTests {
    @Test func aDayFileThatCannotBeReadIsCountedNotDropped() throws {
        let store = tempStore()
        try store.append(entry("kept"), today: "2026-10-01")
        try store.append(entry("locked"), today: "2026-10-02")
        let locked = file(store, "2026-10-02")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let snapshot = try store.snapshot()
        #expect(snapshot.items.map(\.entry.heard) == ["kept"])
        #expect(snapshot.unreadableFiles == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        #expect(store.fingerprint() != snapshot.fingerprint)
    }

    @Test func readsEveryEntryFromEveryDayOldestFirst() throws {
        let store = tempStore()
        try store.append(entry("first"), today: "2026-10-01")
        try store.append(entry("second"), today: "2026-10-01")
        try store.append(entry("third"), today: "2026-10-20")
        let snapshot = try store.snapshot()
        #expect(snapshot.items.map(\.entry.heard) == ["first", "second", "third"])
        #expect(snapshot.items.map(\.reference) == [
            .init(dayFile: "2026-10-01.jsonl", line: 0),
            .init(dayFile: "2026-10-01.jsonl", line: 1),
            .init(dayFile: "2026-10-20.jsonl", line: 0),
        ])
    }

    @Test func identicalDictationsStayDistinct() throws {
        let store = tempStore()
        try store.append(entry("same words"), today: "2026-10-01")
        try store.append(entry("same words"), today: "2026-10-01")
        let snapshot = try store.snapshot()
        #expect(snapshot.items.count == 2)
        #expect(Set(snapshot.items.map(\.reference)).count == 2)
    }

    @Test func countsUnreadableLinesWithoutShiftingReferences() throws {
        let store = tempStore()
        try store.append(entry("before"), today: "2026-10-01")
        let handle = try FileHandle(forWritingTo: file(store, "2026-10-01"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try store.append(entry("after"), today: "2026-10-01")
        let snapshot = try store.snapshot()
        #expect(snapshot.items.map(\.entry.heard) == ["before", "after"])
        #expect(snapshot.items.last?.reference.line == 2)
        #expect(snapshot.unreadableLines == 1)
    }

    @Test func anEmptyHistoryIsAnEmptySnapshot() throws {
        let snapshot = try tempStore().snapshot()
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.unreadableLines == 0)
    }

    @Test func theFingerprintHoldsWhileNothingChanges() throws {
        let store = tempStore()
        try store.append(entry("one"), today: "2026-10-01")
        #expect(try store.snapshot().fingerprint == store.fingerprint())
    }

    @Test func theFingerprintSeesASameSizeEditToAnOlderDay() throws {
        let store = tempStore()
        try store.append(entry("alpha"), today: "2026-10-01")
        try store.append(entry("newest"), today: "2026-10-20")
        let before = try store.snapshot().fingerprint
        let older = file(store, "2026-10-01")
        let edited = try String(contentsOf: older, encoding: .utf8).replacingOccurrences(of: "alpha", with: "omega")
        try Data(edited.utf8).write(to: older)
        #expect(store.fingerprint() != before)
    }

    @Test func theFingerprintSeesRetentionRemovingADay() throws {
        let store = tempStore()
        try store.append(entry("old"), today: "2026-09-01")
        try store.append(entry("new"), today: "2026-10-20")
        let before = try store.snapshot().fingerprint
        store.applyRetention(today: "2026-10-20", retentionDays: 7)
        #expect(store.fingerprint() != before)
    }

    @Test func theFingerprintSeesAnAppend() throws {
        let store = tempStore()
        try store.append(entry("one"), today: "2026-10-20")
        let before = try store.snapshot().fingerprint
        try store.append(entry("two"), today: "2026-10-20")
        #expect(store.fingerprint() != before)
    }

    @Test func aCancelledReadStops() async throws {
        let store = tempStore()
        try store.append(entry("one"), today: "2026-10-20")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.snapshot()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
