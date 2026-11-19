import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct TitleProbeTests {
    private func candidate(_ agent: String, _ pid: Int, tty: String? = "ttys020", setup: String? = "/Users/me/.agent") -> AgentCandidate {
        AgentCandidate(agent: agent, pid: pid, startedAt: 1, cwd: "/Users/me/app", setup: setup, tty: tty)
    }

    @Test func eachRunningAgentIsListedWithThePaneTitleReadForIt() async {
        let lines = await TitleProbe.lines(
            candidates: [candidate("alpha", 11), candidate("beta", 22, tty: nil, setup: nil)],
            titles: { pids in
                #expect(pids == [11, 22])
                return [11: "app | 019a8b2c-1111-7abc-8def-01234..."]
            })
        #expect(lines == [
            "alpha  pid 11  tty ttys020  setup /Users/me/.agent  folder app",
            "  title: app | 019a8b2c-1111-7abc-8def-01234...",
            "beta  pid 22  tty -  setup -  folder app",
            "  title: none read (no title route for this terminal, Automation not granted, or the read failed)",
        ])
    }

    @Test func withNoAgentRunningItSaysSo() async {
        #expect(await TitleProbe.lines(candidates: [], titles: { _ in [:] }) == ["No running agent processes found."])
    }
}
