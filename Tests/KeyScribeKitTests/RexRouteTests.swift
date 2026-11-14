import Foundation
import Testing
@testable import KeyScribeKit

struct RexRouteTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let app = "com.superlogical.rex"
    private static let rex = "/Users/me/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    private static let server = "unix:///Users/me/Library/Application%20Support/rex/server.sock"
    private static let session = "session:01a1d831-b348-79db-973e-25979abf81e3"
    private static let otherSession = "session:01a1d81d-b3d3-7432-9574-f6ab3d25bad2"
    private static let block = "block:01a1d831-b349-7a7d-8e83-0b7f28690c7b"
    private static let window = "window:01a1d831-b35f-7c4e-a4f8-38d3b26195bf"
    private static let appClient = "client:01a1d820-36d7-7c19-9e61-e42e72d01b39"
    private static let cli = [rex, "--autostart=false", "-S", server]

    private static func client(
        _ id: String, kind: String, pid: Int, transport: String = "unix", state: String = "connected", sessions: [String]
    ) -> String {
        let ids = sessions.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"client_id":"\(id)","info":{"kind":"\(kind)","platform":"macos","name":"Rex Beta","version":"0.1.0 (1973)"},\
            "principal":{"kind":"peer","transport":"\(transport)","display":"uid 501","uid":501,"gid":20,"pid":\(pid)},\
            "connection_state":"\(state)","session_ids":[\(ids)]}
            """
    }

    private static func clients(_ rows: [String]) -> String { "{\"clients\":[\(rows.joined(separator: ","))]}" }

    private static func inspect(active: String = window, focused: String = block) -> String {
        """
        {"revision":3,"session_id":"\(session)","label":"docs","active_window_id":"\(active)","windows":[\
        {"window_id":"\(window)","label":"Window b26195bf","focused_block_id":"\(focused)","layers":[]},\
        {"window_id":"window:01a1d831-c001-7000-8000-000057722a15","label":"Window 57722a15",\
        "focused_block_id":"block:01a1d831-c002-7000-8000-0000dd7d59de","layers":[]}],"clients":[]}
        """
    }

    private static let bare: [String: String] = [:]
    private static let reported = ["REX_SERVER": server, "REX_SESSION": session, "REX_BLOCK": block]

    private static func facts(
        environment: [String: String]? = nil, server serverArguments: [String]? = nil, sessions: [String] = [otherSession, session]
    ) -> Facts {
        let env = environment ?? reported.merging(["TERM_PROGRAM": "rex"]) { own, _ in own }
        let facts = Facts()
            .add(3626, parent: 1, serverArguments ?? [rex, "server", "run", "--listen", server, "--log-format", "text"], app: "com.superlogical.rex.server")
            .add(53015, parent: 1, ["/Applications/Rex Beta.app/Contents/MacOS/Rex"], app: app)
            .add(40, parent: 3626, tty: "/dev/ttys036", ["-zsh"], environment: env)
            .add(41, parent: 40, tty: "/dev/ttys036", ["claude"], environment: env)
        facts.outputs[cli + ["client", "ls", "--json"]] = clients([
            client(appClient, kind: "app", pid: 53015, sessions: sessions),
            client("client:cli", kind: "cli", pid: 77, sessions: [session]),
        ])
        facts.outputs[cli + ["session", "inspect", session, "--json"]] = inspect()
        return facts
    }

    private static func plan(_ facts: TerminalFacts) throws -> [OpenAction] {
        TerminalRoutes.plan(agent: 41, facts: facts, routes: try AgentSurfaces.builtIn.resolve().routes)
    }

    private static let focusArguments = cli + ["focus", "-s", session, block]
    private static let focus = OpenAction.layer(PaneLayer("Rex", commands: [PaneCommand(focusArguments)]))
    private static let unresolved = OpenAction.layer(.unresolved("Rex"))
    private static let activate = OpenAction.activate(app: app, pid: 53015)
    private static let show = OpenAction.select(.script(app: app, pid: 53015, body: """
        set found to (every session whose remote is false and id ends with "/\(session)")
        if (count of found) is not 1 then return false
        show (item 1 of found)
        return true
        """))

    @Test func theAppListsEverySessionItHasSoTheBlocksSessionIsShownAfterTheBlockIsFocused() throws {
        #expect(try Self.plan(Self.facts()) == [Self.focus, Self.show, Self.activate])
    }

    @Test func anAppWhoseOnlyLocalSessionIsTheBlocksIsStillAskedToShowItBecauseItMayShowARemoteOne() throws {
        #expect(try Self.plan(Self.facts(sessions: [Self.session])) == [Self.focus, Self.show, Self.activate])
    }

    @Test func theConnectorsReportIsEnoughWhenTheBlocksEnvironmentCannotBeRead() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let facts = Self.facts(environment: Self.bare).reporting(Self.reported, for: 41, keeping: resolved.environmentKeys)
        #expect(try Self.plan(facts) == [Self.focus, Self.show, Self.activate])
    }

    @Test func theOneConnectedAppComesForwardWhenNoAppHasTheSession() throws {
        let facts = Self.facts()
        facts.outputs[Self.cli + ["client", "ls", "--json"]] = Self.clients([
            Self.client("client:remote", kind: "app", pid: 53015, transport: "tailscale", sessions: [Self.session]),
            Self.client(Self.appClient, kind: "app", pid: 53015, sessions: [Self.otherSession]),
            Self.client("client:lost", kind: "app", pid: 53015, state: "lost", sessions: [Self.session]),
            "{\"client_id\":\"client:bare\",\"principal\":{\"transport\":\"unix\",\"pid\":53015},\"connection_state\":\"connected\"}",
        ])
        #expect(try Self.plan(facts) == [Self.focus, Self.activate])
    }

    @Test func twoAppsAreNotGuessedBetween() throws {
        for sessions in [[Self.session], [Self.otherSession]] {
            let facts = Self.facts()
            facts.add(53016, parent: 1, ["/Applications/Rex.app/Contents/MacOS/Rex"], app: Self.app)
            facts.outputs[Self.cli + ["client", "ls", "--json"]] = Self.clients([
                Self.client(Self.appClient, kind: "app", pid: 53015, sessions: sessions),
                Self.client("client:second", kind: "app", pid: 53016, sessions: sessions),
            ])
            #expect(try Self.plan(facts) == [Self.focus])
        }
    }

    @Test func theAppWithTheSessionWinsOverAnotherApp() throws {
        let facts = Self.facts()
        facts.add(53016, parent: 1, ["/Applications/Rex.app/Contents/MacOS/Rex"], app: Self.app)
        facts.outputs[Self.cli + ["client", "ls", "--json"]] = Self.clients([
            Self.client(Self.appClient, kind: "app", pid: 53015, sessions: [Self.otherSession, Self.session]),
            Self.client("client:second", kind: "app", pid: 53016, sessions: [Self.otherSession]),
        ])
        #expect(try Self.plan(facts) == [Self.focus, Self.show, Self.activate])
    }

    @Test func anUnreadableClientListStillFocusesTheBlock() throws {
        let facts = Self.facts()
        facts.outputs[Self.cli + ["client", "ls", "--json"]] = nil
        #expect(try Self.plan(facts) == [Self.focus])
    }

    @Test func anAppClientWhoseProcessIsNotAnAppIsNotActivated() throws {
        let facts = Self.facts()
        facts.add(53015, parent: 1, ["/usr/local/bin/rex-viewer"])
        #expect(try Self.plan(facts) == [Self.focus])
    }

    @Test func aBlockReportingAnotherServerIsNotFocusedThroughThisOneButRexStillComesForward() throws {
        var env = Self.reported
        env["REX_SERVER"] = "unix:///tmp/other.sock"
        #expect(try Self.plan(Self.facts(environment: env)) == [Self.unresolved, Self.activate])
    }

    @Test func aServerWithoutAListenAddressStillBringsRexForward() throws {
        #expect(try Self.plan(Self.facts(server: [Self.rex, "server", "run"])) == [Self.unresolved, .activate(app: Self.app, pid: 3626)])
    }

    @Test func aProcessThatIsNotARexServerIsNotClaimed() throws {
        #expect(try Self.plan(Self.facts(server: [Self.rex, "ls"])) == [.unsupported(app: "com.superlogical.rex.server", pid: 3626)])
    }

    @Test func missingOrMalformedIdsLeaveTheBlockUnresolvedButStillShowTheOneApp() throws {
        for env in [
            Self.bare,
            ["REX_SERVER": Self.server, "REX_SESSION": Self.session],
            ["REX_SERVER": Self.server, "REX_SESSION": Self.session, "REX_BLOCK": "--help"],
            ["REX_SERVER": Self.server, "REX_SESSION": "-x", "REX_BLOCK": Self.block],
            ["REX_SERVER": Self.server, "REX_SESSION": "session:\u{0661}\u{0662}", "REX_BLOCK": Self.block],
        ] {
            #expect(try Self.plan(Self.facts(environment: env)) == [Self.unresolved, Self.activate])
        }
    }

    @Test func withoutTheSessionTwoAppsAreNotGuessedBetween() throws {
        let facts = Self.facts(environment: Self.bare)
        facts.add(53016, parent: 1, ["/Applications/Rex.app/Contents/MacOS/Rex"], app: Self.app)
        facts.outputs[Self.cli + ["client", "ls", "--json"]] = Self.clients([
            Self.client(Self.appClient, kind: "app", pid: 53015, sessions: [Self.otherSession]),
            Self.client("client:second", kind: "app", pid: 53016, sessions: []),
        ])
        #expect(try Self.plan(facts) == [Self.unresolved])
    }

    @Test func theRexAppReadsTheLocalSessionItShowsAndCallsItsPlacesSessions() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let terminal = try #require(resolved.terminal(Self.app))
        #expect(terminal.noun == "session")
        #expect(terminal.frontScript == """
            set shown to current session
            if shown is missing value then return ""
            if remote of shown then return ""
            return id of shown
            """)
        #expect(terminal.front(answer: "A4D68E7A-8A6E-4C39-9D9D-CFFEA559A42C/\(Self.session)", appPid: 53015, facts: Self.facts())
            == .view(FrontView(host: "Rex", server: 53015, pane: Self.session)))
        for answer in ["", Self.session, "A4D68E7A/block:1", "A4D68E7A/session:-x"] {
            guard case .unknown = terminal.front(answer: answer, appPid: 53015, facts: Self.facts()) else {
                Issue.record("read a front from \(answer)")
                continue
            }
        }
    }

    private static func check(_ facts: TerminalFacts, view: String = session) throws -> FrontCheck {
        let route = try #require(try AgentSurfaces.builtIn.resolve().route(named: "Rex"))
        return route.check(agent: 41, view: FrontView(host: "Rex", server: 53015, pane: view), facts: facts, multiplexerProcesses: [])
    }

    @Test func theAgentIsInFrontOnlyWhenItsBlockIsFocusedInTheActiveWindowOfTheShownSession() throws {
        #expect(try Self.check(Self.facts()) == .shown)
        #expect(try Self.check(Self.facts(), view: Self.otherSession) == .elsewhere)

        let otherBlock = Self.facts()
        otherBlock.outputs[Self.cli + ["session", "inspect", Self.session, "--json"]] = Self.inspect(focused: "block:01a1d831-0000-7000-8000-000000000001")
        #expect(try Self.check(otherBlock) == .elsewhere)

        let otherWindow = Self.facts()
        otherWindow.outputs[Self.cli + ["session", "inspect", Self.session, "--json"]] = Self.inspect(active: "window:01a1d831-c001-7000-8000-000057722a15")
        #expect(try Self.check(otherWindow) == .elsewhere)

        let resolved = try AgentSurfaces.builtIn.resolve()
        #expect(try Self.check(Self.facts(environment: Self.bare).reporting(Self.reported, for: 41, keeping: resolved.environmentKeys)) == .shown)
    }

    @Test func anUnreadableSessionOrUnreportedBlockIsUnknownNeverInFront() throws {
        let unreadable = Self.facts()
        unreadable.outputs[Self.cli + ["session", "inspect", Self.session, "--json"]] = nil
        #expect(try Self.check(unreadable) == .unknown(.unreadable("Rex")))
        #expect(try Self.check(Self.facts(environment: Self.bare)) == .unknown(.unreported("Rex")))
        var elsewhere = Self.reported
        elsewhere["REX_SERVER"] = "unix:///tmp/other.sock"
        #expect(try Self.check(Self.facts(environment: elsewhere)) == .unknown(.unreported("Rex")))
    }

    @Test func rexPassesTheRouteConformanceCheck() throws {
        let route = try #require(try AgentSurfaces.builtIn.resolve().route(named: "Rex"))
        #expect(Set(route.environmentKeys) == ["REX_SERVER", "REX_SESSION", "REX_BLOCK"])
        #expect(RouteConformance.problems(.builtIn).isEmpty)
    }
}
