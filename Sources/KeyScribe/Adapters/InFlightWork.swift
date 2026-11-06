import Foundation

actor InFlightWork<Value: Sendable> {
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

    func cancelAndWait() async {
        let running = Array(tasks.values)
        tasks = [:]
        for task in running { task.cancel() }
        for task in running { _ = try? await task.value }
    }
}
