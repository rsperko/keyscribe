import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ClaudeRegistryScannerTests {
    private func configDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return dir
    }

    private func write(_ dir: URL, pid: Int32, session: String, kind: String = "interactive") throws {
        let json = #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/src/keyscribe","kind":"\#(kind)","status":"idle"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("sessions/\(pid).json"))
    }

    @Test func liveInteractiveSessionsAreListed() throws {
        let dir = try configDir()
        try write(dir, pid: getpid(), session: "alive")
        let entries = ClaudeRegistryScanner.scan(configDirs: [dir])
        #expect(entries.map(\.sessionId) == ["alive"])
    }

    @Test func entriesForProcessesThatNoLongerExistAreDropped() throws {
        let dir = try configDir()
        try write(dir, pid: 999_999, session: "gone")
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]).isEmpty)
    }

    @Test func keyFilesAndOtherKindsAreIgnored() throws {
        let dir = try configDir()
        try Data("secret".utf8).write(to: dir.appendingPathComponent("sessions/\(getpid()).abc.key"))
        try write(dir, pid: getpid(), session: "sdk", kind: "sdk")
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]).isEmpty)
    }

    @Test func everyConfigDirIsScanned() throws {
        let a = try configDir()
        let b = try configDir()
        try write(a, pid: getpid(), session: "one")
        try write(b, pid: getppid(), session: "two")
        #expect(Set(ClaudeRegistryScanner.scan(configDirs: [a, b]).map(\.sessionId)) == ["one", "two"])
    }

    @Test func theDefaultConfigDirHonorsTheEnvironment() {
        #expect(ClaudeRegistryScanner.defaultConfigDir(environment: ["CLAUDE_CONFIG_DIR": "/x/claude"]).path == "/x/claude")
        #expect(ClaudeRegistryScanner.defaultConfigDir(environment: [:]).path.hasSuffix("/.claude"))
    }
}
