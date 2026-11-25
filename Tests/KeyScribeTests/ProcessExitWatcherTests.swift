import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct ProcessExitWatcherTests {
    final class Exits { var count = 0 }

    @Test func aWatchedProcessThatEndsIsReportedOnce() async throws {
        let exits = Exits()
        let watcher = ProcessExitWatcher { exits.count += 1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        try process.run()
        watcher.watch([Int(process.processIdentifier)])
        #expect(exits.count == 0)
        for _ in 0..<300 where exits.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(exits.count == 1)
        watcher.watch([Int(process.processIdentifier)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(exits.count == 1)
    }

    @Test func aProcessAlreadyGoneWhenWatchedIsReportedAtOnce() throws {
        let exits = Exits()
        let watcher = ProcessExitWatcher { exits.count += 1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        watcher.watch([Int(process.processIdentifier)])
        #expect(exits.count == 1)
    }
}
