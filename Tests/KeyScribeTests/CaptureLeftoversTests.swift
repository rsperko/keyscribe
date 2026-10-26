import Foundation
import Testing
@testable import KeyScribeApp

struct CaptureLeftoversTests {
    private let dead: Int32 = 4242
    private let live: Int32 = 5151

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-leftovers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, age: TimeInterval = 1) throws -> URL {
        try Data("wav".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func sweep(_ dir: URL) -> Int {
        CaptureLeftovers.sweep(in: dir, isAlive: { $0 == live })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aRecordingWhoseWriterIsGoneIsDeletedAtOnce() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let abandoned = try write(CaptureLeftovers.newURL(in: dir, pid: dead))

        #expect(sweep(dir) == 1)
        #expect(!exists(abandoned))
    }

    @Test func aRecordingWhoseWriterIsRunningIsKeptHoweverOld() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = try write(CaptureLeftovers.newURL(in: dir, pid: live), age: CaptureLeftovers.legacyMinimumAge * 10)

        #expect(sweep(dir) == 0)
        #expect(exists(active))
    }

    @Test func aRecordingFromAnOlderBuildIsDeletedOnlyOnceItIsStale() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try write(dir.appendingPathComponent("\(CaptureLeftovers.prefix)\(UUID().uuidString).wav"))
        let stale = try write(
            dir.appendingPathComponent("\(CaptureLeftovers.prefix)\(UUID().uuidString).wav"),
            age: CaptureLeftovers.legacyMinimumAge * 2)

        #expect(sweep(dir) == 1)
        #expect(exists(fresh))
        #expect(!exists(stale))
    }

    @Test func onlyCaptureRecordingsAreDeleted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = CaptureLeftovers.newURL(in: dir, pid: dead)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let others = try [
            "\(CaptureLeftovers.prefix)lost-\(UUID().uuidString)",
            "\(CaptureLeftovers.prefix)\(dead)-\(UUID().uuidString).txt",
            "\(CaptureLeftovers.prefix)\(dead)-notes.wav",
            "someone-else.wav",
        ].map { try write(dir.appendingPathComponent($0), age: CaptureLeftovers.legacyMinimumAge * 2) }

        #expect(sweep(dir) == 0)
        #expect(exists(folder))
        #expect(others.allSatisfy(exists))
    }
}
