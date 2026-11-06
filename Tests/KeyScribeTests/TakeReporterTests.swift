import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct TakeReporterTests {
    private func store() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-reporter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (HistoryStore(supportDir: dir), dir)
    }

    private func entry(_ heard: String) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(), modeName: "Notes", heard: heard, result: heard, outcome: .inserted,
            cloudInvolved: false, redaction: false, contextCategories: [])
    }

    @Test func aConfirmedAppendIsWrittenBeforeItReturns() {
        let (history, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reporter = TakeReporter(history: history, replacementUsage: nil)
        #expect(reporter.append(entry("one"), retentionDays: 7, confirm: true))
        #expect(history.entries().map(\.heard) == ["one"])
    }

    @Test func aReplaceQueuedAfterAnAppendLandsOnItAndAnnouncesTheUpdate() async {
        let (history, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reporter = TakeReporter(history: history, replacementUsage: nil)
        var announced = 0
        let updated = Signal()
        reporter.onHistoryUpdated = { announced += 1; updated.fire() }
        let first = entry("one")
        reporter.append(first, retentionDays: 7, confirm: false)
        var changed = first
        changed.outcome = .commandCancelled
        reporter.replace(first, with: changed)
        await updated.wait()
        #expect(history.entries().map(\.outcome) == [.commandCancelled])
        #expect(announced == 1)
    }

    @Test func withoutAStoreNothingIsKept() {
        let reporter = TakeReporter(history: nil, replacementUsage: nil)
        #expect(!reporter.keepsHistory)
        #expect(!reporter.append(entry("one"), retentionDays: 7, confirm: true))
    }
}
