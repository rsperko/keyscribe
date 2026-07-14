import Foundation
import Testing
@testable import KeyScribe

@MainActor
struct ModelInstallStoreActivityTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-active-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backdate(_ url: URL, minutes: Int) {
        let old = Date().addingTimeInterval(TimeInterval(-minutes * 60))
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    // A download bumps only the FILE's mtime as bytes stream in, not the parent dir's; a top-level-
    // mtime-only check would see the dir as idle and let the other variant delete it mid-download.
    // directoryActive must recurse and treat the recent nested file as activity.
    @Test func nestedFileWriteKeepsADirActiveEvenWhenTheDirMtimeIsStale() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("model.bin")
        try Data("streaming".utf8).write(to: file)

        backdate(root, minutes: 30)
        backdate(sub, minutes: 30)

        let cutoff = Date().addingTimeInterval(-5 * 60)
        #expect(ModelInstallStore.directoryActive(root, since: cutoff))
    }

    @Test func aFullyStaleDirIsNotActive() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("model.bin")
        try Data("done".utf8).write(to: file)

        backdate(file, minutes: 30)
        backdate(sub, minutes: 30)
        backdate(root, minutes: 30)

        let cutoff = Date().addingTimeInterval(-5 * 60)
        #expect(!ModelInstallStore.directoryActive(root, since: cutoff))
    }
}
