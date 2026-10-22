import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
@Suite(.serialized)
struct ConfigWatcherReloadTests {
    private final class Reloads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct Harness {
        let dir: URL
        let cache: ConfigCache
        let reloads: Reloads
        let watcher: ConfigWatcher
    }

    private func makeHarness() throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-watch-\(UUID().uuidString)", isDirectory: true)
        let modes = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modes, withIntermediateDirectories: true)
        try ModeStore.write(rule(heard: "alpha", replace: "one"), to: modes)
        try ReplacementsStore.write(ReplacementsSet(), to: dir)
        let cache = ConfigCache(supportDir: dir)
        _ = cache.modes
        let gate = ConfigSelfWriteGate(baseline: ConfigTreeSnapshot.capture(supportDir: dir))
        let reloads = Reloads()
        let onChange: @Sendable () -> Void = { [gate] in
            guard gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) else { return }
            Task { @MainActor in
                gate.adopt(ConfigTreeSnapshot.capture(supportDir: dir))
                cache.invalidate()
                reloads.bump()
            }
        }
        let made: ConfigWatcher? = ConfigWatcher(path: dir.path, onChange: onChange)
        let watcher = try #require(made)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return Harness(dir: dir, cache: cache, reloads: reloads, watcher: watcher)
    }

    private func rule(heard: String, replace: String) -> Mode {
        var mode = Mode(id: "notes", name: "Notes")
        mode.replacements.rules = [.init(heard: heard, replace: replace, regex: false)]
        return mode
    }

    private func liveHeard(_ h: Harness) -> [String] {
        h.cache.modes.first { $0.id == "notes" }?.replacements.rules.map(\.heard) ?? []
    }

    private func eventually(_ h: Harness, heard expected: [String]) async -> Bool {
        for _ in 0..<60 {
            if liveHeard(h) == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func inPlaceWriteReloads() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let url = h.dir.appendingPathComponent("modes/notes.toml")
        let toml = try ModeStore.encode(rule(heard: "beta", replace: "two"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        handle.write(Data(toml.utf8))
        try handle.close()
        #expect(await eventually(h, heard: ["beta"]))
    }

    @Test func editorStyleAtomicSaveReloads() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let url = h.dir.appendingPathComponent("modes/notes.toml")
        let temp = h.dir.appendingPathComponent("modes/.notes.toml.swp")
        try ModeStore.encode(rule(heard: "gamma", replace: "three")).write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        #expect(await eventually(h, heard: ["gamma"]))
    }

    @Test func twoFilesChangedInTheSameInstantBothReload() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try ModeStore.write(rule(heard: "delta", replace: "four"), to: h.dir.appendingPathComponent("modes"))
        try ReplacementsStore.write(
            ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: h.dir)
        #expect(await eventually(h, heard: ["delta"]))
        #expect(h.cache.replacements.rules.map(\.heard) == ["teh"])
    }

    @Test func rapidSuccessiveEditsSettleOnTheLastOne() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let modes = h.dir.appendingPathComponent("modes")
        for (i, word) in ["e1", "e2", "e3", "e4"].enumerated() {
            try ModeStore.write(rule(heard: word, replace: "\(i)"), to: modes)
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(await eventually(h, heard: ["e4"]))
    }

    @Test func appendingWithShellRedirectReloads() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let url = h.dir.appendingPathComponent("modes/notes.toml")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("[[replacements.rules]]\nheard = \"zeta\"\nreplace = \"six\"\n".utf8))
        try handle.close()
        #expect(await eventually(h, heard: ["alpha", "zeta"]))
    }
}
