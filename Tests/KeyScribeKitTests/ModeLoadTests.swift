import Foundation
import Testing
@testable import KeyScribeKit

struct ModeLoadTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-modeload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsValidModesWithNoFailures() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(makeMode(id: "alpha"), to: dir)
        let result = ModeStore.load(in: dir, previous: [])
        #expect(result.modes.map(\.id) == ["alpha"])
        #expect(result.failures.isEmpty)
    }

    @Test func malformedFileFallsBackToLastKnownGood() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = makeMode(id: "alpha")
        try ModeStore.write(good, to: dir)
        let first = ModeStore.load(in: dir, previous: [])

        try "this is not = valid [toml".write(
            to: dir.appendingPathComponent("alpha.toml"), atomically: true, encoding: .utf8)
        let second = ModeStore.load(in: dir, previous: first.modes)

        #expect(second.modes.map(\.id) == ["alpha"])
        #expect(second.modes.first?.name == good.name)
        #expect(second.failures.count == 1)
        #expect(second.failures.first?.usedLastKnownGood == true)
    }

    @Test func malformedFileWithNoPriorIsReportedAndSkipped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(makeMode(id: "good"), to: dir)
        try "garbage = [".write(
            to: dir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)

        let result = ModeStore.load(in: dir, previous: [])
        #expect(result.modes.map(\.id) == ["good"])
        #expect(result.failures.map(\.id) == ["broken"])
        #expect(result.failures.first?.usedLastKnownGood == false)
    }

    @Test func diskLKGRecoversWhenFileMalformedAtLaunchWithNoMemory() throws {
        let dir = try tempDir()
        let lkg = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: lkg) }
        let good = makeMode(id: "alpha")
        try ModeStore.write(good, to: dir)

        // A clean load with an lkgDir stashes the good copy to disk...
        let first = ModeStore.load(in: dir, previous: [], lkgDir: lkg)
        #expect(first.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: lkg.appendingPathComponent("alpha.toml").path))

        // ...so a malformed file with NO in-memory prior (the launch case) recovers from disk.
        try "broken = [".write(
            to: dir.appendingPathComponent("alpha.toml"), atomically: true, encoding: .utf8)
        let second = ModeStore.load(in: dir, previous: [], lkgDir: lkg)
        #expect(second.modes.map(\.id) == ["alpha"])
        #expect(second.modes.first?.name == good.name)
        #expect(second.failures.first?.usedLastKnownGood == true)
    }

    @Test func diskLKGTracksLatestGoodAndIsNotWrittenForMalformed() throws {
        let dir = try tempDir()
        let lkg = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: lkg) }
        var renamed = makeMode(id: "alpha")
        renamed.name = "First"
        try ModeStore.write(renamed, to: dir)
        _ = ModeStore.load(in: dir, previous: [], lkgDir: lkg)

        renamed.name = "Second"
        try ModeStore.write(renamed, to: dir)
        _ = ModeStore.load(in: dir, previous: [], lkgDir: lkg)

        // A malformed file must not overwrite the disk LKG, and recovery yields the latest good copy.
        try "broken = [".write(
            to: dir.appendingPathComponent("alpha.toml"), atomically: true, encoding: .utf8)
        let recovered = ModeStore.load(in: dir, previous: [], lkgDir: lkg)
        #expect(recovered.modes.first?.name == "Second")
    }

    @Test func noDiskLKGWhenLkgDirOmitted() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(makeMode(id: "alpha"), to: dir)
        _ = ModeStore.load(in: dir, previous: [])
        try "broken = [".write(
            to: dir.appendingPathComponent("alpha.toml"), atomically: true, encoding: .utf8)
        let result = ModeStore.load(in: dir, previous: [])
        #expect(result.modes.isEmpty)
        #expect(result.failures.first?.usedLastKnownGood == false)
    }

    private func makeMode(id: String) -> Mode {
        var mode = Mode(id: id, name: "Mode \(id)")
        mode.commands.liveEdits = true
        return mode
    }
}
