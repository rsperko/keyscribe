import Foundation
import Testing
@testable import KeyScribeKit

struct DiscoveryReportTests {
    private func report(shell: ShellProbeState, sightings: [DiscoveryReport.Sighting] = []) -> String {
        DiscoveryReport(
            app: "KeyScribeDev", agent: "Claude Code", folder: "/Users/a/.claude",
            search: ToolSearch.Result(
                tool: nil,
                searched: [
                    ToolSearch.Place(path: "/Users/a/.local/bin/claude", source: .shell),
                    ToolSearch.Place(path: "/usr/bin/claude", source: .app),
                ]),
            check: nil, shell: shell,
            folders: [DiscoveryReport.Folder(path: "/Users/a/.claude", sources: ["default"])],
            sightings: sightings
        ).text
    }

    @Test func listsWhereItLookedAndWhatItFound() {
        let text = report(shell: .notRun)
        #expect(text.contains("Claude Code"))
        #expect(text.contains("/Users/a/.local/bin/claude (login shell PATH): not found"))
        #expect(text.contains("/usr/bin/claude (app PATH): not found"))
        #expect(text.contains("/Users/a/.claude (default)"))
        #expect(text.contains("Login shell: not run yet"))
        #expect(text.contains("never looked at"))
    }

    @Test func showsOnlyTheAllowlistedShellValues() {
        let shell = ShellEnvironment(values: ["PATH": "/Users/a/.local/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/a/.claude-work"])
        let text = report(shell: .read(shell, at: Date(timeIntervalSince1970: 0), failure: nil))
        #expect(text.contains("PATH=/Users/a/.local/bin:/usr/bin"))
        #expect(text.contains("CLAUDE_CONFIG_DIR=/Users/a/.claude-work"))
        #expect(!text.contains("PI_CODING_AGENT_DIR="))
    }

    @Test func aFailedRefreshSaysSoAndKeepsTheLastAnswer() {
        let shell = ShellEnvironment(values: ["PATH": "/usr/bin"])
        let text = report(shell: .read(shell, at: Date(timeIntervalSince1970: 0), failure: "zsh -ilc did not finish within 5 seconds"))
        #expect(text.contains("did not finish within 5 seconds"))
        #expect(text.contains("PATH=/usr/bin"))
    }

    @Test func listsProcessesByPathAndNameOnly() {
        let text = report(shell: .failed("no answer"), sightings: [
            DiscoveryReport.Sighting(pid: 4, name: ".claude-wrapped", paths: ["/nix/store/x/bin/.claude-wrapped"], matched: true, setup: "/Users/a/.claude"),
            DiscoveryReport.Sighting(pid: 5, name: "claude-helper", paths: ["/usr/local/bin/node", "/x/claude-helper.js"], matched: false, setup: nil),
        ])
        #expect(text.contains("4 .claude-wrapped: session, folder /Users/a/.claude"))
        #expect(text.contains("    /nix/store/x/bin/.claude-wrapped"))
        #expect(text.contains("5 claude-helper: not a session"))
        #expect(text.contains("Login shell: no answer"))
    }

    @Test func aFoundToolSaysWhyItWasChosenAndWhetherItWorks() {
        let text = DiscoveryReport(
            app: "KeyScribeDev", agent: "Pi", folder: "/Users/a/.pi/agent",
            search: ToolSearch.Result(tool: ToolSearch.Place(path: "/Users/a/bin/pi", source: .session), searched: [ToolSearch.Place(path: "/Users/a/bin/pi", source: .session)]),
            check: .timedOut(10), shell: .notRun, folders: [], sightings: []
        ).text
        #expect(text.contains("Using /Users/a/bin/pi (a running conversation)"))
        #expect(text.contains("--version: did not finish within 10 seconds"))
    }
}
