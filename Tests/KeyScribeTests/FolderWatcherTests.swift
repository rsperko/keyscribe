import Foundation
import Testing
@testable import KeyScribeApp

struct FolderWatcherTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func aFileAddedToAWatchedFolderIsReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let changes = Count()
        let watcher = try #require(FolderWatcher(folders: [dir]) { changes.bump() })
        try await Task.sleep(for: .milliseconds(300))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("1.json"))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, changes.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changes.value > 0)
        #expect(watcher.folders == [dir])
    }
}
