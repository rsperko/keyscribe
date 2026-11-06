import Foundation
import KeyScribeKit
import os

@MainActor
final class TakeReporter {
    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")
    private let history: HistoryStore?
    private let replacementUsage: ReplacementUsageStore?
    private let queue = DispatchQueue(label: "com.keyscribe.history.write", qos: .utility)
    private var lastRetentionSweepDay: String?
    var onHistoryUpdated: (() -> Void)?

    init(history: HistoryStore?, replacementUsage: ReplacementUsageStore?) {
        self.history = history
        self.replacementUsage = replacementUsage
    }

    var keepsHistory: Bool { history != nil }

    func usageEpoch() -> Int? { replacementUsage?.renameEpoch() }

    func recordUsage(_ fired: [ReplacementRule], capturedAt epoch: Int?) {
        replacementUsage?.record(fired, capturedAt: epoch)
    }

    func recordUsage(effects: [ReplacementEffect], capturedAt epoch: Int?) {
        replacementUsage?.record(effects: effects, capturedAt: epoch)
    }

    @discardableResult
    func append(_ entry: HistoryEntry, retentionDays: Int, confirm: Bool) -> Bool {
        guard let history else { return false }
        let today = HistoryStore.todayString()
        let sweepRetention = lastRetentionSweepDay != today
        lastRetentionSweepDay = today
        let write = { [log] () -> Bool in
            do {
                try history.append(entry, today: today)
                if sweepRetention { history.applyRetention(today: today, retentionDays: retentionDays) }
                return true
            } catch {
                log.error("history append failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard confirm else {
            queue.async { _ = write() }
            return true
        }
        return queue.sync(execute: write)
    }

    func replace(_ entry: HistoryEntry, with updated: HistoryEntry) {
        guard let history else { return }
        queue.async { [weak self] in
            guard history.replace(entry, with: updated) else { return }
            Task { @MainActor in self?.onHistoryUpdated?() }
        }
    }

    func waitForWrites() { queue.sync {} }
}
