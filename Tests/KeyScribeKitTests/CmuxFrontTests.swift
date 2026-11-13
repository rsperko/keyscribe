import Foundation
import Testing
@testable import KeyScribeKit

struct CmuxFrontTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let cmux = "com.cmuxterm.app"
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let surface = "CMUX_SURFACE_ID"

    private static func twoSurfaces() -> Facts {
        Facts()
            .add(10, parent: 1, ["cmux"], app: cmux)
            .add(20, parent: 10, tty: "/dev/ttys021", ["/usr/bin/login"])
            .add(21, parent: 20, tty: "/dev/ttys021", ["-zsh"])
            .add(30, parent: 21, tty: "/dev/ttys021", ["claude"], environment: [surface: "A"])
            .add(40, parent: 10, tty: "/dev/ttys022", ["/usr/bin/login"])
            .add(41, parent: 40, tty: "/dev/ttys022", ["-zsh"])
            .add(50, parent: 41, tty: "/dev/ttys022", ["pi"], environment: [surface: "B"])
    }

    private static func reading(_ answer: String, _ facts: Facts) -> FrontReading? {
        ResolvedSurfaces.builtIn.terminal(cmux).map { FrontPanes.read(answer: answer, from: $0, appPid: 10, facts: facts) }
    }

    @Test func theFocusedCmuxTerminalIsTheSurfaceWhoseProcessesCarryItsId() {
        let facts = Self.twoSurfaces()
        let reading = Self.reading("A\n", facts)
        #expect(reading == .pane(FrontPane(app: Self.cmux, tty: "/dev/ttys021", multiplexers: [])))
        #expect(reading?.check(agent: 30, facts: facts) == .shown)
        #expect(reading?.check(agent: 50, facts: facts) == .elsewhere)
        #expect(Self.reading("B", facts)?.check(agent: 50, facts: facts) == .shown)
    }

    @Test func aMultiplexerInACmuxSurfaceIsWalkedLikeAnyTerminalTab() {
        let facts = Self.twoSurfaces()
            .add(60, parent: 41, tty: "/dev/ttys022", ["tmux", "attach"], executable: Self.tmux, environment: [Self.surface: "B"])
            .add(70, parent: 1, ["tmux", "new-session"], executable: Self.tmux, environment: [Self.surface: "A"])
            .add(71, parent: 70, tty: "/dev/ttys040", ["-zsh"], environment: [Self.surface: "A"])
            .add(72, parent: 71, tty: "/dev/ttys040", ["codex"], environment: [Self.surface: "A"])
        facts.table[50]?.foreground = false
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys022\t/dev/ttys040\n"
        let reading = Self.reading("B", facts)
        #expect(reading == .pane(FrontPane(app: Self.cmux, tty: "/dev/ttys040", multiplexers: ["tmux"])))
        #expect(reading?.check(agent: 72, facts: facts) == .shown)
        #expect(Self.reading("A", facts)?.check(agent: 72, facts: facts) == .elsewhere)
    }

    @Test func anAgentInAnotherSurfaceIsElsewhereThoughNothingInTheFrontSurfaceShowsItsId() {
        let facts = Self.twoSurfaces()
            .add(60, parent: 10, tty: "/dev/ttys023", ["/usr/bin/login"])
            .add(61, parent: 60, tty: "/dev/ttys023", ["-zsh"])
        let reading = Self.reading("C", facts)
        #expect(reading?.check(agent: 30, facts: facts) == .elsewhere)
        #expect(reading?.check(agent: 50, facts: facts) == .elsewhere)
    }

    @Test func anAgentWhoseOwnSurfaceIsInFrontIsShownThoughItsEnvironmentWasUnreadableToTheRead() {
        let facts = Self.twoSurfaces()
        facts.table[30]?.environment = [:]
        let reading = Self.reading("A", facts)
        #expect(reading?.check(agent: 30, facts: facts.reporting([Self.surface: "A"], for: 30)) == .shown)
        #expect(reading?.check(agent: 30, facts: facts.reporting([Self.surface: "B"], for: 30)) == .elsewhere)
        #expect(reading?.check(agent: 30, facts: facts) == .unknown(.unreported("cmux")))
    }

    @Test func aSuspendedAgentInTheFrontSurfaceIsNotShown() {
        let facts = Self.twoSurfaces()
        facts.table[30]?.environment = [:]
        facts.table[30]?.foreground = false
        #expect(Self.reading("A", facts)?.check(agent: 30, facts: facts.reporting([Self.surface: "A"], for: 30)) == .elsewhere)
    }

    @Test func anAgentReachedThroughAMultiplexerCannotBeRuledOutBySurfaceId() {
        let facts = Self.twoSurfaces()
            .add(70, parent: 1, ["tmux", "new-session"], executable: Self.tmux, environment: [Self.surface: "A"])
            .add(71, parent: 70, tty: "/dev/ttys040", ["-zsh"], environment: [Self.surface: "A"])
            .add(72, parent: 71, tty: "/dev/ttys040", ["codex"], environment: [Self.surface: "A"])
        #expect(Self.reading("C", facts)?.check(agent: 72, facts: facts) == .unknown(.unreported("cmux")))
    }

    @Test func twoSurfacesClaimingTheSameIdAreAmbiguous() {
        let facts = Self.twoSurfaces()
        facts.table[50]?.environment = [Self.surface: "A"]
        #expect(Self.reading("A", facts) == .unknown(.ambiguous))
    }

    @Test func surfacesThatCannotBeListedOrReadAreUnknown() {
        let facts = Self.twoSurfaces()
        facts.childrenUnreadable = true
        #expect(Self.reading("A", facts) == .unknown(.processesUnreadable))
        let unreadable = Self.twoSurfaces()
        unreadable.unreadableTTYs = ["/dev/ttys022"]
        #expect(Self.reading("B", unreadable) == .unknown(.processesUnreadable))
        #expect(Self.reading("A", unreadable) == .pane(FrontPane(app: Self.cmux, tty: "/dev/ttys021", multiplexers: [])))
    }

    @Test func anEmptyAnswerHasNoTerminal() {
        #expect(Self.reading(" \n", Self.twoSurfaces()) == .unknown(.noTerminal))
    }

    @Test func ttyAnsweringTerminalsReadTheirTabDirectly() throws {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: "com.mitchellh.ghostty")
            .add(30, parent: 10, tty: "/dev/ttys004", ["claude"])
        let ghostty = try #require(ResolvedSurfaces.builtIn.terminal("com.mitchellh.ghostty"))
        #expect(ghostty.frontScript == ScriptedTerminalRoute.ghostty.frontScript)
        #expect(FrontPanes.read(answer: "/dev/ttys004\n", from: ghostty, appPid: 10, facts: facts)
            == .pane(FrontPane(app: "com.mitchellh.ghostty", tty: "/dev/ttys004", multiplexers: [])))
        #expect(ResolvedSurfaces.builtIn.terminal("com.apple.Safari") == nil)
        #expect(ResolvedSurfaces.builtIn.terminal("dev.warp.Warp-Stable")?.frontScript == nil)
    }
}
