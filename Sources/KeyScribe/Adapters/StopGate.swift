import Foundation

final class StopGate: @unchecked Sendable {
    private let lock = NSLock()
    private let registry: Registry
    private var closed = false
    private var watcher: Task<Void, Never>?

    private init(registry: Registry) {
        self.registry = registry
    }

    var isOpen: Bool { lock.withLock { !closed } }

    static func watching(
        _ wanted: @escaping @Sendable () async -> Bool, every interval: Duration = .milliseconds(50), in registry: Registry = .shared
    ) -> StopGate {
        let gate = StopGate(registry: registry)
        registry.add(gate)
        gate.watcher = Task {
            while !Task.isCancelled {
                guard await wanted() else {
                    gate.close()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
        return gate
    }

    static func closeAll(in registry: Registry = .shared) {
        for gate in registry.all { gate.close() }
    }

    func close() {
        lock.withLock { closed = true }
    }

    func finish() async {
        registry.remove(self)
        watcher?.cancel()
        await watcher?.value
        watcher = nil
    }

    final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var gates: [ObjectIdentifier: StopGate] = [:]
        var all: [StopGate] { lock.withLock { Array(gates.values) } }
        func add(_ gate: StopGate) { lock.withLock { gates[ObjectIdentifier(gate)] = gate } }
        func remove(_ gate: StopGate) { lock.withLock { gates[ObjectIdentifier(gate)] = nil } }
    }
}
