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
    case wouldLeaveNoUsableEngine
}

public struct SpeechModelSet: Equatable, Sendable {
    public let catalog: [SpeechModelInfo]
    public private(set) var installed: Set<String>
    public private(set) var activeId: String

    public init(catalog: [SpeechModelInfo], installed: Set<String>, activeId: String) {
        self.catalog = catalog
        self.installed = installed
        self.activeId = activeId
    }

    private func info(_ id: String) -> SpeechModelInfo? { catalog.first { $0.id == id } }

    public func isUsable(_ id: String) -> Bool {
        guard let info = info(id) else { return false }
        return info.systemManaged || installed.contains(id)
    }

    public var usableIds: [String] { catalog.map(\.id).filter(isUsable) }

    public mutating func select(_ id: String) throws {
        guard info(id) != nil else { throw ModelSelectionError.unknown(id) }
        guard isUsable(id) else { throw ModelSelectionError.notUsable(id) }
        activeId = id
    }

    public mutating func markInstalled(_ id: String) {
        guard let info = info(id), !info.systemManaged else { return }
        installed.insert(id)
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

    public mutating func delete(_ id: String) throws {
        guard let entry = info(id), !entry.systemManaged, installed.contains(id) else { return }
        let remaining = catalog.map(\.id).filter { $0 != id && isUsable($0) }
        if remaining.isEmpty { throw ModelSelectionError.wouldLeaveNoUsableEngine }
        installed.remove(id)
        if id == activeId {
            activeId = remaining.first { info($0)?.isDefaultEnglish == true } ?? remaining[0]
        }
    }
}
