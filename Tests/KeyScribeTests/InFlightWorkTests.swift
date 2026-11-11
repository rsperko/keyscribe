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

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if !open { waiting.append(continuation) }
                    return open
                }
                if now { continuation.resume() }
            }
        }
        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                open = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in pending { continuation.resume() }
        }
    }

    @Test func aSecondRunWaitsForNoneAndIsTurnedAwayWhileOneIsUnfinished() async throws {
        let work = InFlightWork<Int>()
        let gate = Gate()
        let first = Task { try await work.runAlone { await gate.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: InFlightWork<Int>.Busy.self) { _ = try await work.runAlone { 2 } }
        gate.release()
        #expect(try await first.value == 1)
        #expect(try await work.runAlone { 3 } == 3)
    }

    @Test func aCancelledRunKeepsOthersOutUntilItsWorkTrulyReturns() async throws {
        let work = InFlightWork<Int>()
        let gate = Gate()
        let returned = Flag()
        let caller = Task { try await work.runAlone { await gate.wait(); returned.set(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!returned.value)
        await #expect(throws: InFlightWork<Int>.Busy.self) { _ = try await work.runAlone { 2 } }
        gate.release()
        _ = try? await caller.value
        #expect(try await work.runAlone { 3 } == 3)
    }

    @Test func aRunMayWaitBrieflyForTheOneBeforeItToSettle() async throws {
        let work = InFlightWork<Int>()
        let gate = Gate()
        let first = Task { try await work.runAlone { await gate.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await work.runAlone(waitingUpTo: .seconds(5)) { 2 } }
        try await Task.sleep(for: .milliseconds(50))
        gate.release()
        #expect(try await second.value == 2)
        _ = try await first.value
        let held = Gate()
        let third = Task { try await work.runAlone { await held.wait(); return 3 } }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: InFlightWork<Int>.Busy.self) { _ = try await work.runAlone(waitingUpTo: .milliseconds(60)) { 4 } }
        held.release()
        #expect(try await third.value == 3)
    }

    @Test func nothingStartsWhileCancelAndWaitIsWaitingForWorkToEnd() async throws {
        let work = InFlightWork<Int>()
        let gate = Gate()
        let first = Task { try await work.runAlone { await gate.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        let stopping = Task { await work.cancelAndWait() }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: InFlightWork<Int>.Busy.self) { _ = try await work.runAlone { 2 } }
        gate.release()
        await stopping.value
        _ = try? await first.value
        #expect(try await work.runAlone { 3 } == 3)
    }

    @Test func waitingForWorkToEndLetsItFinishUncancelled() async throws {
        let work = InFlightWork<Int>()
        let gate = Gate()
        let ended = Flag()
        let first = Task { try await work.run { await gate.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        let waiting = Task {
            await work.waitUntilFinished()
            ended.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ended.value)
        gate.release()
        await waiting.value
        #expect(ended.value)
        #expect(try await first.value == 1)
    }
}
