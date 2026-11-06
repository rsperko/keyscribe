import Foundation
import Testing
@testable import KeyScribeApp

struct InFlightWorkTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private static func waitForCancellation(_ cancelled: Flag) async throws -> Int {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled.set()
            throw error
        }
        return 1
    }

    @Test func cancellingTheCallerCancelsItsWork() async {
        let work = InFlightWork<Int>()
        let cancelled = Flag()
        let caller = Task { try await work.run { try await Self.waitForCancellation(cancelled) } }
        try? await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        _ = try? await caller.value
        #expect(cancelled.value)
    }

    @Test func cancelAndWaitStopsEveryRunAndReturnsOnceTheyEnd() async {
        let work = InFlightWork<Int>()
        let first = Flag()
        let second = Flag()
        let a = Task { try await work.run { try await Self.waitForCancellation(first) } }
        let b = Task { try await work.run { try await Self.waitForCancellation(second) } }
        try? await Task.sleep(for: .milliseconds(50))
        await work.cancelAndWait()
        #expect(first.value)
        #expect(second.value)
        _ = try? await a.value
        _ = try? await b.value
    }
}
