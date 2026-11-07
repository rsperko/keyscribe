import Foundation

final class AgentExclusions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    private var known: Bool

    init(_ ids: Set<String>? = []) {
        self.ids = ids ?? []
        known = ids != nil
    }

    func excludes(_ session: String) -> Bool {
        lock.withLock { !known || ids.contains(session) }
    }

    var excluded: Set<String> { lock.withLock { ids } }
    var isKnown: Bool { lock.withLock { known } }

    func adopt(_ loaded: Set<String>) {
        lock.withLock {
            ids = loaded
            known = true
        }
    }

    @discardableResult
    func insert(_ session: String) -> Bool { lock.withLock { ids.insert(session).inserted } }

    @discardableResult
    func remove(_ session: String) -> Bool { lock.withLock { ids.remove(session) != nil } }
}
