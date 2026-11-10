import Foundation

struct WorkBusy: Error {}

actor InFlightWork<Value: Sendable> {
    typealias Busy = WorkBusy

    private var tasks: [UUID: Task<Value, any Error>] = [:]

    func run(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        let task = Task { try await work() }
        tasks[id] = task
        defer { tasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func runAlone(
        waitingUpTo wait: Duration = .zero, _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while !tasks.isEmpty {
            guard clock.now < deadline else { throw Busy() }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        return try await run(work)
    }

    func cancelAndWait() async {
        let running = tasks
        for task in running.values { task.cancel() }
        for (id, task) in running {
            _ = try? await task.value
            tasks[id] = nil
        }
    }
}
