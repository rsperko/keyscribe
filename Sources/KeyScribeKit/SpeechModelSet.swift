import Foundation

public enum DeletionConsequence: Equatable, Sendable {
    case notDeletable
    case notInstalled
    case routine
    case confirmActive
    case confirmLeavesNoUsableEngine
}

public enum ModelSelectionError: Error, Equatable {
    case unknown(String)
    case notUsable(String)
}

public struct SpeechModelSet: Equatable, Sendable {
    public let catalog: [SpeechModelInfo]
    public private(set) var installed: Set<String>
    // Models that failed their self-test: kept on disk (still in `installed`) but quarantined — not usable
    // and not selectable until they pass a re-test. A durable overlay on `installed`, independent of it.
    public private(set) var failed: Set<String>
    public private(set) var activeId: String

    public init(catalog: [SpeechModelInfo], installed: Set<String>, activeId: String, failed: Set<String> = []) {
        self.catalog = catalog
        self.installed = installed
        self.failed = failed
        self.activeId = activeId
    }

    private func info(_ id: String) -> SpeechModelInfo? { catalog.first { $0.id == id } }

    public func isFailed(_ id: String) -> Bool { failed.contains(id) }

    public func isUsable(_ id: String) -> Bool {
        guard let info = info(id) else { return false }
        if failed.contains(id) { return false }
        return info.systemManaged || installed.contains(id)
    }

    public mutating func select(_ id: String) throws {
        guard info(id) != nil else { throw ModelSelectionError.unknown(id) }
        guard isUsable(id) else { throw ModelSelectionError.notUsable(id) }
        activeId = id
    }

    public mutating func markInstalled(_ id: String) {
        guard let info = info(id), !info.systemManaged else { return }
        installed.insert(id)
    }

    // Quarantine a model that failed its self-test. Mirrors delete()'s reassignment so a failing active
    // engine hands the active slot off to a usable one; if none remain, activeId stays on the now-unusable
    // id (the "no usable model" state).
    public mutating func markFailed(_ id: String) {
        guard info(id) != nil else { return }
        failed.insert(id)
        guard id == activeId else { return }
        let remaining = catalog.map(\.id).filter(isUsable)
        if let replacement = remaining.first(where: { info($0)?.isDefaultEnglish == true }) ?? remaining.first {
            activeId = replacement
        }
    }

    public mutating func clearFailed(_ id: String) {
        failed.remove(id)
    }

    public func deletionConsequence(_ id: String) -> DeletionConsequence {
        guard let info = info(id) else { return .notInstalled }
        if info.systemManaged { return .notDeletable }
        if !installed.contains(id) { return .notInstalled }
        let remaining = catalog.map(\.id).filter { $0 != id && isUsable($0) }
        if remaining.isEmpty { return .confirmLeavesNoUsableEngine }
        if id == activeId { return .confirmActive }
        return .routine
    }

    // Deleting the active last usable model leaves activeId pointing at an unusable id; callers surface
    // that as the explicit "no installed model" state until the user installs one.
    public mutating func delete(_ id: String) {
        guard let entry = info(id), !entry.systemManaged, installed.contains(id) else { return }
        installed.remove(id)
        failed.remove(id)
        guard id == activeId else { return }
        let remaining = catalog.map(\.id).filter(isUsable)
        if let replacement = remaining.first(where: { info($0)?.isDefaultEnglish == true }) ?? remaining.first {
            activeId = replacement
        }
    }
}
