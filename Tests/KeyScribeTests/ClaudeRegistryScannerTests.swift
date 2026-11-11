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

    @MainActor
    @Test func aScanWatchesEverySessionFolderThatExists() async throws {
        let present = try configDir()
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("ks-claude-\(UUID().uuidString)")
        let discovery = ClaudeDiscovery(enrolled: { [present, absent] }, defaultFolder: absent, processes: { AgentProcesses.Found() })
        #expect(discovery.watchedFolders.isEmpty)
        _ = await discovery.scan(rereadingTitles: false)
        #expect(discovery.watchedFolders.map(\.standardizedFileURL.path) == [present.appendingPathComponent("sessions").standardizedFileURL.path])
    }

    @Test func liveInteractiveSessionsAreListed() throws {
        let dir = try configDir()
        try write(dir, pid: getpid(), session: "alive")
        let entries = ClaudeRegistryScanner.scan(configDirs: [dir])
        #expect(entries?.map(\.sessionId) == ["alive"])
    }

    @Test func aTruncatedSessionFileMakesTheScanUnknownWhileOtherKindsAreStillIgnored() throws {
        let dir = try configDir()
        try write(dir, pid: getpid(), session: "alive")
        try write(dir, pid: getppid(), session: "sdk", kind: "sdk")
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir])?.map(\.sessionId) == ["alive"])
        try Data(#"{"pid":1,"sessionId":"cut","cwd":"/src/x","kind":"interactive","sta"#.utf8).write(to: dir.appendingPathComponent("sessions/1.json"))
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == nil)
        try Data(#"{"pid":1,"kind":"interactive"}"#.utf8).write(to: dir.appendingPathComponent("sessions/1.json"))
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == nil)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("sessions/1.json"))
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == nil)
    }

    @Test func aSessionFileThatCannotBeReadMakesTheScanUnknownRatherThanDroppingIt() throws {
        let dir = try configDir()
        try write(dir, pid: getpid(), session: "alive")
        let file = dir.appendingPathComponent("sessions/\(getpid()).json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == nil)
    }

    @Test func aMissingSessionsFolderIsEmptyButAnUnreadableOneIsUnknown() throws {
        let dir = try configDir()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sessions"))
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == [])
        try Data("not a folder".utf8).write(to: dir.appendingPathComponent("sessions"))
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == nil)
    }

    @Test func entriesForProcessesThatNoLongerExistAreDropped() throws {
        let dir = try configDir()
        try write(dir, pid: 999_999, session: "gone")
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == [])
    }

    @Test func keyFilesAndOtherKindsAreIgnored() throws {
        let dir = try configDir()
        try Data("secret".utf8).write(to: dir.appendingPathComponent("sessions/\(getpid()).abc.key"))
        try write(dir, pid: getpid(), session: "sdk", kind: "sdk")
        #expect(ClaudeRegistryScanner.scan(configDirs: [dir]) == [])
    }

    @Test func everyConfigDirIsScanned() throws {
        let a = try configDir()
        let b = try configDir()
        try write(a, pid: getpid(), session: "one")
        try write(b, pid: getppid(), session: "two")
        #expect(Set(ClaudeRegistryScanner.scan(configDirs: [a, b])?.map(\.sessionId) ?? []) == ["one", "two"])
    }

    @Test func eachEntryRemembersItsConfigFolderAndAnUnreadableFolderKeepsTheOthers() throws {
        let a = try configDir()
        let b = try configDir()
        try write(a, pid: getpid(), session: "one")
        try Data("not json".utf8).write(to: b.appendingPathComponent("sessions/bad.json"))
        let found = ClaudeRegistryScanner.scanEach(configDirs: [a, b])
        #expect(found.entries.map(\.sessionId) == ["one"])
        #expect(found.entries.map(\.configDir) == [a.path])
        #expect(found.entries.first?.session.setup == a.path)
        #expect(found.unreadable == [b.path])
        #expect(ClaudeRegistryScanner.scan(configDirs: [a, b]) == nil)
    }

    final class Scans: @unchecked Sendable {
        var next = ClaudeRegistryScanner.Scan(entries: [], unreadable: [])
    }

    private func entry(_ session: String, pid: Int, in folder: String) -> ClaudeRegistryEntry {
        var entry = ClaudeRegistryEntry(pid: pid, sessionId: session, cwd: "/src/\(session)", name: nil, status: "idle", waitingFor: nil)
        entry.configDir = folder
        return entry
    }

    @MainActor
    @Test func aFolderThatBecomesUnreadableKeepsItsConversationsAsLastSeenWhileTheOthersStayFresh() async {
        let scans = Scans()
        let discovery = ClaudeDiscovery(scanEach: { scans.next }, isRunning: { $0 != 99 })
        scans.next = ClaudeRegistryScanner.Scan(
            entries: [entry("one", pid: 10, in: "/a"), entry("two", pid: 20, in: "/b"), entry("gone", pid: 99, in: "/b")], unreadable: [])
        _ = await discovery.scan(rereadingTitles: false)
        scans.next = ClaudeRegistryScanner.Scan(entries: [entry("one", pid: 10, in: "/a")], unreadable: ["/b"])
        guard case .found(let sessions, let extras) = await discovery.scan(rereadingTitles: false) else { Issue.record("unreadable"); return }
        #expect(sessions.map(\.id) == ["one", "two"])
        #expect(extras.carried == ["two"])
        #expect(extras.problem == ClaudeDiscovery.partialProblem)
        scans.next = ClaudeRegistryScanner.Scan(entries: [entry("one", pid: 10, in: "/a")], unreadable: [])
        guard case .found(let after, let clear) = await discovery.scan(rereadingTitles: false) else { Issue.record("unreadable"); return }
        #expect(after.map(\.id) == ["one"])
        #expect(clear.carried.isEmpty)
        #expect(clear.problem == nil)
    }

    @MainActor
    @Test func processesThatCouldNotBeReadArePartialSetupDiscoveryNotAnUnreadableSessionList() async {
        var scan = ClaudeRegistryScanner.Scan(entries: [], unreadable: [])
        scan.processesUnreadable = true
        let fixed = scan
        let discovery = ClaudeDiscovery(scanEach: { fixed })
        #expect(await discovery.scan(rereadingTitles: false) == .found([], AgentScanExtras(problem: ClaudeDiscovery.partialProblem)))
    }
}
