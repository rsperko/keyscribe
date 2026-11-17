import Foundation
import Testing
@testable import KeyScribeKit

struct ToolSearchTests {
    let home = "/Users/a"
    let bareMacPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private func find(
        chosen: String? = nil, sessions: [String] = [], shell: [String]? = nil, app: [String]? = nil, extra: [String] = [],
        existing: Set<String>
    ) -> ToolSearch.Result {
        let places = ToolSearch.places(
            program: "claude", chosen: chosen, sessions: sessions, shellPath: shell, appPath: app ?? bareMacPath, home: home, extra: extra)
        return ToolSearch.find(places, isExecutable: existing.contains)
    }

    @Test func aBareMacPathStillReachesTheUsualInstallFolders() {
        let found = find(existing: ["/Users/a/.local/bin/claude"])
        #expect(found.tool == ToolSearch.Place(path: "/Users/a/.local/bin/claude", source: .usual))
    }

    @Test func theShellsCopyWinsOverAnOlderOneTheAppWouldFindFirst() {
        let found = find(
            shell: ["/Users/a/.local/bin", "/opt/homebrew/bin"], app: ["/opt/homebrew/bin", "/usr/bin"],
            existing: ["/opt/homebrew/bin/claude", "/Users/a/.local/bin/claude"])
        #expect(found.tool == ToolSearch.Place(path: "/Users/a/.local/bin/claude", source: .shell))
    }

    @Test func withoutAShellAnswerTheAppsPathComesBeforeTheUsualFolders() {
        let found = find(app: ["/opt/homebrew/bin", "/usr/bin"], existing: ["/opt/homebrew/bin/claude", "/Users/a/.local/bin/claude"])
        #expect(found.tool?.source == .app)
        #expect(found.tool?.path == "/opt/homebrew/bin/claude")
    }

    @Test func aRunningSessionsCommandWinsOverEveryPath() {
        let found = find(
            sessions: ["/nix/store/abc-claude/bin/claude"], shell: ["/Users/a/.local/bin"],
            existing: ["/nix/store/abc-claude/bin/claude", "/Users/a/.local/bin/claude"])
        #expect(found.tool == ToolSearch.Place(path: "/nix/store/abc-claude/bin/claude", source: .session))
    }

    @Test func aChosenCommandWinsAndIsTheOnlyPlaceLooked() {
        let found = find(
            chosen: "/Users/a/tools/claude", sessions: ["/nix/store/abc-claude/bin/claude"], shell: ["/Users/a/.local/bin"],
            existing: ["/Users/a/tools/claude", "/nix/store/abc-claude/bin/claude"])
        #expect(found.tool == ToolSearch.Place(path: "/Users/a/tools/claude", source: .chosen))
        #expect(found.searched == [ToolSearch.Place(path: "/Users/a/tools/claude", source: .chosen)])
    }

    @Test func aChosenCommandThatIsGoneIsNotQuietlyReplaced() {
        let found = find(chosen: "/Users/a/tools/claude", shell: ["/Users/a/.local/bin"], existing: ["/Users/a/.local/bin/claude"])
        #expect(found.tool == nil)
        #expect(found.searched.map(\.path) == ["/Users/a/tools/claude"])
    }

    @Test func notFoundListsEveryPlaceLookedInOrderOnce() {
        let found = find(
            shell: ["/Users/a/.local/bin", "/opt/homebrew/bin"], app: ["/opt/homebrew/bin", "/usr/bin"], extra: ["/Users/a/.claude/local"],
            existing: [])
        #expect(found.tool == nil)
        #expect(found.searched.map(\.path) == [
            "/Users/a/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/bin/claude", "/usr/local/bin/claude",
            "/Users/a/.local/share/mise/shims/claude", "/Users/a/.asdf/shims/claude", "/Users/a/.volta/bin/claude", "/Users/a/.claude/local/claude",
        ])
        #expect(found.searched.map(\.source) == [.shell, .shell, .app, .usual, .usual, .usual, .usual, .usual])
    }

    @Test func versionManagerShimsAreUsualFolders() {
        #expect(find(existing: ["/Users/a/.local/share/mise/shims/claude"]).tool?.source == .usual)
        #expect(find(existing: ["/Users/a/.asdf/shims/claude"]).tool?.source == .usual)
    }

    @Test func relativePathEntriesAreSkipped() {
        let found = find(shell: [".", "bin", "/opt/homebrew/bin"], existing: ["./claude", "bin/claude", "/opt/homebrew/bin/claude"])
        #expect(found.tool?.path == "/opt/homebrew/bin/claude")
        #expect(!found.searched.contains { !$0.path.hasPrefix("/") })
    }

    @Test func aWrappedBinaryIsRunThroughItsWrapper() {
        let existing: Set<String> = ["/nix/store/abc-claude/bin/.claude-wrapped", "/nix/store/abc-claude/bin/claude"]
        #expect(ToolSearch.launcher(for: "/nix/store/abc-claude/bin/.claude-wrapped", isExecutable: existing.contains) == "/nix/store/abc-claude/bin/claude")
        #expect(ToolSearch.launcher(for: "/nix/store/abc-pi/bin/.pi-wrapped", isExecutable: existing.contains) == "/nix/store/abc-pi/bin/.pi-wrapped")
        #expect(ToolSearch.launcher(for: "/Users/a/.local/bin/claude", isExecutable: existing.contains) == "/Users/a/.local/bin/claude")
    }

    @Test func runPathPutsTheToolsOwnFoldersFirstThenTheShellThenTheApp() {
        let path = ToolSearch.runPath(
            tool: "/Users/a/.nvm/versions/node/v24/bin/pi", runtime: "/Users/a/.nvm/versions/node/v24/bin/node",
            shellPath: ["/Users/a/.local/bin", "/usr/bin"], appPath: ["/usr/bin", "/bin"])
        #expect(path == "/Users/a/.nvm/versions/node/v24/bin:/Users/a/.local/bin:/usr/bin:/bin")
    }
}
