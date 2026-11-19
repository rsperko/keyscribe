import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct UltimateHostTests {
    @MainActor final class Front {
        var app: AgentHostApp?
        var activated: [Int] = []
        var shown: [(Int, Int)] = []
        var retitled: [(Int, Int, String)] = []
        var showWorks = true
    }

    static let home = "/u/.ultimate/projects/app-1234"
    static let browser = AgentHostApp(bundle: "com.google.Chrome.app.x", pid: 40, name: "Ultimate")
    static let terminal = AgentHostApp(bundle: "com.apple.Terminal", pid: 41, name: "Terminal")

    private func host(
        _ front: Front, projects: [UltimateHost.Running] = [UltimateHost.Running(home: home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))],
        conversations: @escaping @Sendable (String) -> [UltimateProjects.Conversation]? = { _ in
            [.init(id: "53", handle: "@ultimate", folder: "/w/app"), .init(id: "61", folder: "/h/wt/61")]
        }
    ) -> UltimateHost {
        UltimateHost(
            home: "/u", enrolled: { ["/u/.ultimate"] }, readProjects: { _ in projects }, readConversations: { conversations($0) },
            show: { [front] port, id in
                await MainActor.run { front.shown.append((port, id)) }
                return await MainActor.run { front.showWorks }
            },
            retitle: { [front] port, id, title in
                await MainActor.run { front.retitled.append((port, id, title)) }
                return await MainActor.run { front.showWorks }
            },
            frontApp: { front.app }, activate: { front.activated.append($0); return true })
    }

    private func session(_ id: String, _ home: String = home) -> String {
        AgentSessionID.make(agent: "ultimate", native: AgentHostLocation(host: "ultimate", instance: home, native: id).conversationKey)
    }

    private func location(_ id: String) -> AgentHostLocation { AgentHostLocation(host: "ultimate", instance: Self.home, native: id) }

    @Test func aRunningProjectListsItsConversationsUnderItsHomeWithStandingHandlesAsTitles() async {
        let ultimate = host(Front())
        guard case .found(let sessions, let titles, _, _, _, _) = await ultimate.scan() else {
            Issue.record("a readable project must list")
            return
        }
        #expect(sessions.map(\.id) == ["53", "61"])
        #expect(sessions.allSatisfy { $0.host?.instance == Self.home && $0.pid == 9 })
        #expect(titles == [location("53").conversationKey: "@ultimate"])
    }

    @Test func everyConversationsDictationIsDeliveredByTheExtension() async {
        let ultimate = host(Front())
        _ = await ultimate.scan()
        #expect(ultimate.deliveryRoute(at: location("53")) == .connector)
        #expect(ultimate.deliveryRoute(at: location("61")) == .connector)
    }

    @Test func eachConversationIsPlacedInTheProjectThatHoldsIt() async {
        let other = "/u/.ultimate/projects/web-5678"
        let ultimate = host(Front(), projects: [
            UltimateHost.Running(home: Self.home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747)),
            UltimateHost.Running(home: other, project: .init(root: "/w/web", name: "web"), lock: .init(pid: 10, port: 4748)),
            UltimateHost.Running(home: "/u/.ultimate/projects/bare", project: nil, lock: .init(pid: 11, port: 4749)),
        ], conversations: { _ in [.init(id: "53", handle: "@ultimate", folder: "/w")] })
        guard case .found(_, _, _, _, _, let workspaces) = await ultimate.scan() else {
            Issue.record("running projects must list")
            return
        }
        #expect(workspaces == [
            location("53").conversationKey: "app",
            AgentHostLocation(host: "ultimate", instance: other, native: "53").conversationKey: "web",
        ])
    }

    @Test func renamingABranchRetitlesItInUltimate() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.rename(location("61"), to: "release notes"))
        #expect(front.retitled.map { [String($0.0), String($0.1), $0.2] } == [["4747", "61", "release notes"]])
    }

    @Test func renamingAStandingAgentLeavesItsFixedHandleInUltimateAlone() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(!(await ultimate.rename(location("53"), to: "boss")))
        #expect(front.retitled.isEmpty)
    }

    @Test func aRenameUltimateRefusesOrCannotPlaceIsReportedAsNotDone() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(!(await ultimate.rename(location("99"), to: "x")))
        #expect(!(await ultimate.rename(AgentHostLocation(host: "ultimate", instance: "/elsewhere", native: "61"), to: "x")))
        #expect(front.retitled.isEmpty)
        front.showWorks = false
        #expect(!(await ultimate.rename(location("61"), to: "x")))
    }

    @Test func aListingThatFailsKeepsTheLastOneAndSaysSo() async {
        let failing = Flag()
        let ultimate = host(Front(), conversations: { _ in failing.on ? nil : [.init(id: "53", handle: "@ultimate", folder: "/w/app")] })
        _ = await ultimate.scan()
        failing.on = true
        guard case .found(let sessions, _, _, let carried, let problem, _) = await ultimate.scan() else {
            Issue.record("a failed read must not empty the list")
            return
        }
        #expect(sessions.map(\.id) == ["53"])
        #expect(carried == [location("53")])
        #expect(problem != nil)
    }

    @Test func theConnectorsSessionKeyNamesTheSameConversationTheScanLists() {
        #expect(UltimateHost.location(of: session("53")) == location("53"))
        #expect(UltimateHost.location(of: AgentSessionID.make(agent: "bb", native: "53@x")) == nil)
    }

    @Test func aConversationIsInFrontOnlyWhileTheAppItsPageReportedFromIsStillFrontmost() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: session("61"), on: true))
        let app = ultimate.focusedWindow()
        #expect(app?.instance == Self.home)
        #expect(await ultimate.front(among: [location("53"), location("61")], reported: location("61"), in: app) == .shown(location("61"), in: app!))
        front.app = Self.terminal
        #expect(ultimate.focusedWindow() == nil)
        #expect(await ultimate.front(among: [location("61")], reported: location("61"), in: Self.terminal) == .unknown)
    }

    @Test func aPageThatStopsShowingAConversationLeavesNothingInFront() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: session("61"), on: true))
        ultimate.observe(.shown(session: session("61"), on: false))
        #expect(ultimate.focusedWindow() == nil)
    }

    @Test func aReportForAnotherConversationThanTheHubExpectsIsUnknown() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: session("61"), on: true))
        let app = ultimate.focusedWindow()
        #expect(await ultimate.front(among: [location("53"), location("61")], reported: location("53"), in: app) == .unknown)
    }

    @Test func openingShowsTheConversationThroughUltimateAndBringsItsPageForward() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: session("53"), on: true))
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .opened)
        #expect(front.shown.map(\.0) == [4747])
        #expect(front.shown.map(\.1) == [61])
        #expect(front.activated == [40])
    }

    @Test func openingWithNoPageSeenYetSwitchesButOnlyRequests() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.activated.isEmpty)
    }

    @Test func anOpenNoLongerWantedTouchesNothing() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { false }) == .failed)
        #expect(front.shown.isEmpty)
    }

    @Test func anOpenUltimateRefusesFails() async {
        let front = Front()
        front.showWorks = false
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .failed)
        #expect(front.activated.isEmpty)
    }

    @Test func aProjectThatIsNotRunningIsNotOpened() async {
        let front = Front()
        let ultimate = host(front, projects: [])
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .failed)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
