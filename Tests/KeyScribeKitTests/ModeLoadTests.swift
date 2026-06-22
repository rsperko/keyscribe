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

    private func makeMode(id: String) -> Mode {
        var mode = Mode(id: id, name: "Mode \(id)")
        mode.commands.liveEdits = true
        return mode
    }
}
