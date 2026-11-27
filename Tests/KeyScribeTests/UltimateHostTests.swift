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
        var showRefusal: String?
        var now = Date()
        var pages: [String: String] = ["cg:400": "http://ultimate.localhost:4747/?conversation=61"]
        var frontReads = 0
        var pageReads = 0
        var openedPages: [String] = []
        var activationLags = false
    }

    final class Box: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    static let home = "/u/.ultimate/projects/app-1234"
    static let browser = AgentHostApp(bundle: "com.google.Chrome.app.x", pid: 40, name: "Ultimate", window: "cg:400")
    static let terminal = AgentHostApp(bundle: "com.apple.Terminal", pid: 41, name: "Terminal", window: "cg:410")

    private func host(
        _ front: Front, projects: [UltimateHost.Running] = [UltimateHost.Running(home: home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))],
        conversations: @escaping @Sendable (String) -> [UltimateProjects.Conversation]? = { _ in
            [.init(id: "53", handle: "@ultimate", folder: "/w/app"), .init(id: "61", folder: "/h/wt/61")]
        },
        listing: (@Sendable (String) -> UltimateHost.Listing)? = nil,
        documentURL: (@Sendable (AgentHostApp) async -> URL?)? = nil
    ) -> UltimateHost {
        UltimateHost(
            home: "/u", enrolled: { [UltimateNamingTests.setup] }, readProjects: { _ in projects },
            readConversations: { home, _ in listing?(home) ?? conversations(home).map { .connector($0) } ?? .file(nil, connectorFailed: false) },
            show: { [front] port, id in
                await MainActor.run { front.shown.append((port, id)) }
                return await MainActor.run { front.showRefusal.map { .refused($0) } ?? (front.showWorks ? .changed : .unanswered) }
            },
            retitle: { [front] port, id, title in
                await MainActor.run { front.retitled.append((port, id, title)) }
                return await MainActor.run { front.showWorks }
            },
            frontApp: {
                front.frontReads += 1
                return front.app
            }, documentURL: documentURL ?? { [front] app in
                await MainActor.run {
                    front.pageReads += 1
                    return app.window.flatMap { front.pages[$0] }.flatMap(URL.init(string:))
                }
            }, activate: { app, stillWanted in
                guard stillWanted() else { return false }
                front.activated.append(app.pid)
                if !front.activationLags { front.app = app }
                return true
            }, openPage: { url in
                front.openedPages.append(url.absoluteString)
                return true
            }, now: { front.now })
    }

    private func session(_ id: String, _ home: String = home) -> String {
        AgentSessionID.make(agent: "ultimate", native: AgentHostLocation(host: "ultimate", instance: home, native: id).conversationKey)
    }

    private func location(_ id: String) -> AgentHostLocation { AgentHostLocation(host: "ultimate", instance: Self.home, native: id) }

    @Test func aSymlinkedSetupListsTheSameInstancePathTheConnectorReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-ultimate-path-\(UUID().uuidString)")
        let project = root.appendingPathComponent("actual/projects/kestrel")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"pid\":\(getpid()),\"port\":4747}".utf8).write(to: project.appendingPathComponent("ultimate.lock"))
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("actual"))
        let canonical = try #require(realpath(project.path, nil))
        defer { free(canonical) }
        for setup in [root.appendingPathComponent("actual").path, link.path] {
            #expect(await UltimateHost.readProjects([setup]).map(\.home) == [String(cString: canonical)])
        }
    }

    private func projectFolder(_ file: String) throws -> (root: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-ultimate-roster-\(UUID().uuidString)")
        let project = root.appendingPathComponent(".ultimate/projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(file.utf8).write(to: project.appendingPathComponent("conversations.json"))
        try Data("{\"pid\":\(getpid()),\"port\":4747}".utf8).write(to: project.appendingPathComponent("ultimate.lock"))
        let plugin = root.appendingPathComponent(".ultimate/extensions/\(KeyScribePaths.variant.connectorSlug)")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: plugin.appendingPathComponent("keyscribe.json"))
        return (root, project)
    }

    @Test func theConnectorsListIsTheListWhileItAnswers() async throws {
        let (root, project) = try projectFolder("[]")
        defer { try? FileManager.default.removeItem(at: root) }
        let found = await UltimateHost.readConversations(project.path, port: 5151, list: { port in
            #expect(port == 5151)
            return Data(#"{"result":[{"id":70,"handle":"feather","cwd":"/w/child"}]}"#.utf8)
        })
        #expect(found == .connector([.init(id: "70", handle: "feather", folder: "/w/child")]))
    }

    @Test(arguments: [Optional<String>.none, "{}", #"{"ok":false,"error":"The Ultimate connector is not ready."}"#])
    func aConnectorThatIsOffOrNotOpenYetLeavesTheProjectListedFromItsFile(answer: String?) async throws {
        let (root, project) = try projectFolder(#"[{"id":53,"label":"agent","title":"@ultimate","cwd":"/w"}]"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let found = await UltimateHost.readConversations(project.path, port: 4747, list: { _ in answer.map { Data($0.utf8) } })
        #expect(found == .file([.init(id: "53", handle: "@ultimate", sidebarTitle: "@ultimate", folder: "/w")], connectorFailed: true))
    }

    @Test func withoutTheConnectorTheFileIsReadAndTheConnectorIsNotAsked() async throws {
        let (root, project) = try projectFolder(#"[{"id":53,"label":"agent","title":"@ultimate","cwd":"/w"}]"#)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".ultimate/extensions"))
        let asked = Flag()
        let found = await UltimateHost.readConversations(project.path, port: 4747, list: { _ in asked.on = true; return nil })
        #expect(found == .file([.init(id: "53", handle: "@ultimate", sidebarTitle: "@ultimate", folder: "/w")], connectorFailed: false))
        #expect(!asked.on)
    }

    @Test func projectsAreListedAtTheSameTimeNotOneAfterAnother() async {
        let reading = Counter()
        let ultimate = UltimateHost(
            home: "/u", enrolled: { [UltimateNamingTests.setup] },
            readProjects: { _ in [
                UltimateHost.Running(home: "/u/.ultimate/projects/a", project: nil, lock: .init(pid: 9, port: 4747)),
                UltimateHost.Running(home: "/u/.ultimate/projects/b", project: nil, lock: .init(pid: 10, port: 4748)),
            ] },
            readConversations: { _, _ in
                reading.enter()
                try? await Task.sleep(for: .milliseconds(100))
                reading.leave()
                return .connector([])
            })
        _ = await ultimate.scan()
        #expect(reading.most == 2)
    }

    @Test func aRunningProjectListsItsConversationsUnderItsHomeWithStandingHandlesAsTitles() async {
        let ultimate = host(Front())
        guard case .found(let sessions, let titles, _, _, _, _) = await ultimate.scan() else {
            Issue.record("a readable project must list")
            return
        }
        #expect(sessions.map(\.id) == ["53", "61"])
        #expect(sessions.allSatisfy { $0.host?.instance == Self.home && $0.pid == nil })
        #expect(titles == [location("53").conversationKey: "@ultimate"])
    }

    @Test func aBrowserConversationNeverReadsNamesFromTheServersLaunchingTerminal() async {
        let ultimate = host(Front())
        let reader = AgentPlaceTrackerTests.Reader()
        let hub = AgentHub(transport: AgentHubTests.FakeTransport(), discovery: [], names: nil, focus: nil, front: nil,
                           receiptTimeout: .milliseconds(50), scanDeadline: .seconds(3), places: reader,
                           hosts: [AgentHostIntegration(kind: UltimateHost.kind, make: { ultimate })], hostAllowed: { _ in true })
        await hub.rescan()
        while let reading = hub.placeTracker?.reading { await reading.value }
        #expect(reader.asked.flatMap { $0 }.isEmpty)
        #expect(hub.directory.conversations.allSatisfy { $0.pid == nil })
        #expect(!hub.placesUnread(hub.directory.conversations.map(\.id)))
        hub.stop()
    }

    @Test func aNewConversationTheConnectorGreetsIsInFrontAsSoonAsItsListHasIt() async {
        let front = Front()
        front.app = Self.browser
        front.pages["cg:400"] = "http://ultimate.localhost:4747/?conversation=70"
        let greeted = Flag()
        let ultimate = host(front, conversations: { _ in greeted.on ? [.init(id: "70", folder: "/w/app")] : [] })
        let transport = AgentHubTests.FakeTransport()
        let hub = AgentHub(transport: transport, discovery: [], names: nil, focus: nil, front: nil,
                           receiptTimeout: .milliseconds(50), scanDeadline: .seconds(60), places: nil,
                           hosts: [AgentHostIntegration(kind: UltimateHost.kind, make: { ultimate })], hostAllowed: { _ in true },
                           hostDeadline: .seconds(60))
        await hub.rescan()
        let id = session("70")
        transport.live.insert(id)
        var hello = AgentHostTests.hello(id)
        hello.agent = "ultimate"
        hello.cwd = "/w/app"
        greeted.on = true
        hub.handle(.hello(hello))
        hub.handle(.shown(session: id, on: true))
        await hub.refreshHostsForPress()
        #expect(await hub.sessionInFrontWithoutAsking()?.id == id)
        #expect(await hub.hostShows(id) == true)
        hub.stop()
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

    @Test func aConnectorListThatFailsKeepsTheLastConnectorListUntilTheConnectorAnswersOrIsTurnedOff() async {
        let state = Box("connector")
        let ultimate = host(Front(), listing: { _ in
            switch state.value {
            case "connector": .connector([.init(id: "53", handle: "@ultimate", folder: "/w/app"), .init(id: "61", handle: "feather", folder: "/w")])
            case "failed": .file([.init(id: "53", handle: "@ultimate", folder: "/w/app"), .init(id: "61", folder: "/w")], connectorFailed: true)
            default: .file([.init(id: "53", handle: "@ultimate", folder: "/w/app"), .init(id: "61", folder: "/w")], connectorFailed: false)
            }
        })
        _ = await ultimate.scan()
        state.value = "failed"
        guard case .found(let sessions, let titles, _, let carried, let problem, _) = await ultimate.scan() else {
            Issue.record("a failed connector list must not empty the list")
            return
        }
        #expect(sessions.map(\.id) == ["53", "61"])
        #expect(titles[location("61").conversationKey] == "feather")
        #expect(carried == [location("53"), location("61")])
        #expect(problem != nil)
        state.value = "off"
        guard case .found(_, let fileTitles, _, let fileCarried, let fileProblem, _) = await ultimate.scan() else {
            Issue.record("a project without its connector lists from its file")
            return
        }
        #expect(fileTitles == [location("53").conversationKey: "@ultimate"])
        #expect(fileCarried.isEmpty)
        #expect(fileProblem == nil)
    }

    @Test func beforeAnyConnectorListAFailedOneListsFromTheFile() async {
        let ultimate = host(Front(), listing: { _ in .file([.init(id: "53", handle: "@ultimate", folder: "/w/app")], connectorFailed: true) })
        guard case .found(let sessions, _, _, let carried, let problem, _) = await ultimate.scan() else {
            Issue.record("a connector that has not opened yet leaves the project listed from its file")
            return
        }
        #expect(sessions.map(\.id) == ["53"])
        #expect(carried.isEmpty)
        #expect(problem == nil)
    }

    @Test func theConnectorsSessionKeyNamesTheSameConversationTheScanLists() {
        #expect(UltimateHost.location(of: AgentSessionID.native(session("53"))) == location("53"))
        #expect(UltimateHost.location(of: session("53")) == nil)
        #expect(UltimateHost.location(of: "x@" + Self.home) == nil)
    }

    @Test func aConversationIsInFrontOnlyWhileAWindowShowingItsProjectsPageIsFrontmost() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        let focus = await ultimate.focusInFront(requireClaim: true)
        #expect(focus?.app?.instance == Self.home)
        #expect(focus?.app?.window == "cg:400")
        #expect(focus?.conversation == location("61"))
        #expect(await ultimate.front(among: [location("53"), location("61")], reported: location("61"), in: focus?.app) == .shown(location("61"), in: focus!.app!))
        front.app = Self.terminal
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        #expect(await ultimate.front(among: [location("61")], reported: location("61"), in: Self.terminal) == .unknown)
    }

    @Test(arguments: [4747, 4848])
    func aProjectPageWhoseServerStoppedReadsAsNotAnsweringOnlyForAProjectSeenRunning(port: Int) async {
        @MainActor final class Server { var up = true }
        let server = Server()
        let project = UltimateHost.Running(home: Self.home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))
        let ultimate = UltimateHost(
            home: "/u", enrolled: { [UltimateNamingTests.setup] }, readProjects: { _ in await MainActor.run { server.up ? [project] : [] } },
            readConversations: { _, _ in .connector([.init(id: "61", folder: "/h/wt/61")]) },
            show: { _, _ in .unanswered }, retitle: { _, _, _ in false },
            frontApp: { Self.browser },
            documentURL: { _ in URL(string: "http://ultimate.localhost:\(port)/?conversation=61") },
            activate: { _, _ in false })
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        server.up = false
        _ = await ultimate.scan()

        let press = await ultimate.focusInFront(requireClaim: false)

        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        if port == 4747 {
            #expect(press?.copy?.answering == false)
            #expect(press?.copy?.name == "Ultimate for app")
            #expect(press?.conversation == nil)
            #expect(press?.addressed == location("61"))
        } else {
            #expect(press == nil)
        }
    }

    @Test func aLaterNewSideChatReportReplacesTheConversationAStoppedPageIsPinnedTo() async {
        @MainActor final class Server { var up = true }
        let server = Server()
        let project = UltimateHost.Running(home: Self.home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))
        let ultimate = UltimateHost(
            home: "/u", enrolled: { [UltimateNamingTests.setup] }, readProjects: { _ in await MainActor.run { server.up ? [project] : [] } },
            readConversations: { _, _ in .connector([.init(id: "61", folder: "/h/wt/61")]) },
            show: { _, _ in .unanswered }, retitle: { _, _, _ in false },
            frontApp: { Self.browser },
            documentURL: { _ in URL(string: "http://ultimate.localhost:4747/?conversation=61") },
            activate: { _, _ in false })
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false, newConversation: true, pageConversation: "61"))
        server.up = false
        _ = await ultimate.scan()

        let press = await ultimate.focusInFront(requireClaim: false)

        #expect(press?.copy?.answering == false)
        #expect(press?.addressed == nil)
    }

    @Test func aStoppedProjectIsRememberedOnlyLongEnoughForARestart() async {
        @MainActor final class Clock { var now = Date(timeIntervalSince1970: 1_000_000); var up = true }
        let clock = Clock()
        let project = UltimateHost.Running(home: Self.home, project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))
        let ultimate = UltimateHost(
            home: "/u", enrolled: { [UltimateNamingTests.setup] }, readProjects: { _ in await MainActor.run { clock.up ? [project] : [] } },
            readConversations: { _, _ in .connector([.init(id: "61", folder: "/h/wt/61")]) },
            show: { _, _ in .unanswered }, retitle: { _, _, _ in false },
            frontApp: { Self.browser },
            documentURL: { _ in URL(string: "http://ultimate.localhost:4747/?conversation=61") },
            activate: { _, _ in false }, now: { clock.now })
        _ = await ultimate.scan()
        clock.now += UltimateHost.restartWithin * 3
        clock.up = false
        _ = await ultimate.scan()
        #expect(await ultimate.focusInFront(requireClaim: false)?.copy?.answering == false)

        clock.now += UltimateHost.restartWithin + 1
        #expect(await ultimate.focusInFront(requireClaim: false) == nil)
    }

    @Test func replyChecksReadNoWindowUntilAPageClaimsFocusWhilePressChecksStillRecognizeTheProjectWindow() async {
        let front = Front()
        front.app = Self.browser
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        #expect(front.frontReads == 0)
        #expect(front.pageReads == 0)
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false))
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        #expect(front.frontReads == 0)
        #expect(front.pageReads == 0)
        let press = await ultimate.focusInFront(requireClaim: false)
        #expect(press?.copy?.instance == Self.home)
        #expect(press?.conversation == nil)
        #expect(press?.allowsNewConversation == false)
    }

    @Test func aProjectPageInFrontThatHasNotClaimedFocusLatelyIsSilentNotEmpty() async {
        let front = Front()
        front.app = Self.browser
        front.pages["cg:400"] = "http://127.0.0.1:4747/?conversation=61"
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.focusInFront(requireClaim: false)?.pageSilent == true)
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false))
        #expect(await ultimate.focusInFront(requireClaim: false)?.pageSilent == true)
        ultimate.observe(.shown(session: "53@\(Self.home)", on: true, pageConversation: "53"))
        let claimedElsewhere = await ultimate.focusInFront(requireClaim: false)
        #expect(claimedElsewhere?.conversation == nil)
        #expect(claimedElsewhere?.pageSilent == false)
        front.now = front.now.addingTimeInterval(UltimateHost.pageReportsWithin + 1)
        #expect(await ultimate.focusInFront(requireClaim: false)?.pageSilent == true)
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        let claimed = await ultimate.focusInFront(requireClaim: false)
        #expect(claimed?.conversation == location("61"))
        #expect(claimed?.pageSilent == false)
    }

    @Test func aPageComingToTheFrontIsRememberedSoOpenCanRaiseItWithoutAnyPress() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        #expect(await ultimate.open(location("53"), stillWanted: { true }) == .opened)
        #expect(front.activated == [40])
    }

    @Test func aSideChatAndTabSideModeMatchTheirParentsPageAddress() async {
        let front = Front()
        front.app = Self.browser
        front.pages["cg:400"] = "http://ultimate.localhost:4747/?conversation=53"
        let ultimate = host(front)
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "147@\(Self.home)", on: true, pageConversation: "53"))
        let side = await ultimate.focusInFront(requireClaim: true)
        #expect(side?.conversation == location("147"))
        #expect(side?.allowsNewConversation == false)
        ultimate.observe(.shown(session: "53@\(Self.home)", on: false, newConversation: true, pageConversation: "53"))
        let tab = await ultimate.focusInFront(requireClaim: true)
        #expect(tab?.conversation == nil)
        #expect(tab?.allowsNewConversation == true)
        front.pages["cg:400"] = "http://ultimate.localhost:4747/?conversation=61"
        let other = await ultimate.focusInFront(requireClaim: false)
        #expect(other?.copy?.instance == Self.home)
        #expect(other?.conversation == nil)
        #expect(other?.allowsNewConversation == false)
    }

    @Test func readingThePageAddressRevalidatesTheWindowWhenFocusChangesMidRead() async {
        let front = Front()
        front.app = Self.browser
        let ultimate = host(front, documentURL: { [front] _ in
            await MainActor.run { front.app = Self.terminal }
            return URL(string: "http://ultimate.localhost:4747/?conversation=61")
        })
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        #expect(await ultimate.focusInFront(requireClaim: false) == nil)
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.activated.isEmpty)
    }

    @Test func theLiveDocumentURLWalkDoesNotBlockTheMainActor() async {
        let front = Front()
        front.app = Self.browser
        let release = AgentHostTests.Gate()
        release.closed = true
        let entered = Flag()
        let ultimate = host(front, documentURL: { _ in
            entered.on = true
            await release.pass()
            return URL(string: "http://ultimate.localhost:4747/?conversation=61")
        })
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        let reading = Task { @MainActor in await ultimate.focusInFront(requireClaim: true) }
        while !entered.on { await Task.yield() }
        release.open()
        let focus = await reading.value
        #expect(focus?.conversation == location("61"))
    }

    @Test func aFocusReportArrivingWhileAnotherAppIsInFrontCannotClaimThatAppOrActivateIt() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.terminal
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.activated.isEmpty)
    }

    @Test(arguments: ["http://127.0.0.1:5050/?conversation=61", "https://example.com/", "file:///w/app/index.html"])
    func aWindowShowingAnythingButThisProjectsPageIsNotItsPage(address: String) async {
        let front = Front()
        front.app = Self.browser
        front.pages["cg:400"] = address
        let ultimate = host(front)
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        #expect(await ultimate.focusInFront(requireClaim: false) == nil)
    }

    @Test func switchingTabsInTheSameWindowImmediatelyClearsFocus() async {
        let front = Front()
        front.app = Self.browser
        let ultimate = host(front)
        let transport = AgentHubTests.FakeTransport()
        let hub = AgentHub(
            transport: transport, discovery: [], names: nil, focus: nil, front: nil,
            receiptTimeout: .milliseconds(50), handOffLimit: .seconds(30), scanDeadline: .seconds(30), places: nil,
            hosts: [AgentHostIntegration(kind: UltimateHost.kind, make: { ultimate })], hostAllowed: { _ in true },
            hostDeadline: .seconds(2), hostConfirmDelay: .seconds(3), heldLimit: .milliseconds(100),
            processEnvironment: { _, _ in [:] }, processParent: { _ in nil }, now: Date.init,
            makeId: { "r1" }, accessibilityTrusted: { true })
        let id = session("61")
        transport.live.insert(id)
        var hello = AgentHostTests.hello(id)
        hello.agent = "ultimate"
        hello.features = ["shown", "readiness"]
        await hub.rescan()
        hub.handle(.hello(hello))
        hub.handle(.shown(session: id, on: true))
        #expect(await hub.hostShows(id) == true)
        front.pages["cg:400"] = "https://example.com/"
        #expect(await hub.hostShows(id) == false)
        #expect(await hub.sessionInFrontWithoutAsking() == nil)
        hub.stop()
    }

    @Test func anotherWindowShowingADifferentConversationNeverPairsWithARetainedReport() async {
        let front = Front()
        front.app = Self.browser
        front.pages["cg:401"] = "http://ultimate.localhost:4747/?conversation=53"
        let ultimate = host(front)
        let transport = AgentHubTests.FakeTransport()
        let hub = AgentHub(
            transport: transport, discovery: [], names: nil, focus: nil, front: nil,
            receiptTimeout: .milliseconds(50), handOffLimit: .seconds(30), scanDeadline: .seconds(30), places: nil,
            hosts: [AgentHostIntegration(kind: UltimateHost.kind, make: { ultimate })], hostAllowed: { _ in true },
            hostDeadline: .seconds(2), hostConfirmDelay: .seconds(3), heldLimit: .milliseconds(100),
            processEnvironment: { _, _ in [:] }, processParent: { _ in nil }, now: Date.init,
            makeId: { "r1" }, accessibilityTrusted: { true })
        let id61 = session("61")
        let id53 = session("53")
        transport.live.formUnion([id61, id53])
        for id in [id61, id53] {
            var hello = AgentHostTests.hello(id)
            hello.agent = "ultimate"
            hello.features = ["shown", "readiness"]
            hub.handle(.hello(hello))
        }
        await hub.rescan()
        hub.handle(.shown(session: id61, on: true))
        #expect(await hub.hostShows(id61) == true)
        front.app = AgentHostApp(bundle: Self.browser.bundle, pid: Self.browser.pid, name: Self.browser.name, window: "cg:401")
        #expect(await hub.hostShows(id61) == false)
        #expect(await hub.sessionInFrontWithoutAsking() == nil)
        hub.stop()
    }

    @Test func switchingWindowsInOneBrowserDoesNotKeepThePreviousConversationInFront() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        #expect(await ultimate.focusInFront(requireClaim: true)?.app?.window == "cg:400")
        front.app?.window = "cg:401"
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
    }

    @Test(arguments: [["scan", "hello", "shown"], ["scan", "shown", "hello"],
                      ["hello", "scan", "shown"], ["hello", "shown", "scan"],
                      ["shown", "scan", "hello"], ["shown", "hello", "scan"]])
    func aPageReportThroughTheHubFindsTheConversationAndKeepsItsNativeWindow(order: [String]) async {
        let front = Front()
        front.app = Self.browser
        let ultimate = host(front)
        let transport = AgentHubTests.FakeTransport()
        let hub = AgentHub(
            transport: transport, discovery: [], names: nil, focus: nil, front: nil,
            receiptTimeout: .milliseconds(50), handOffLimit: .seconds(30), scanDeadline: .seconds(30), places: nil,
            hosts: [AgentHostIntegration(kind: UltimateHost.kind, make: { ultimate })], hostAllowed: { _ in true },
            hostDeadline: .seconds(2), hostConfirmDelay: .seconds(3), heldLimit: .milliseconds(100),
            processEnvironment: { _, _ in [:] }, processParent: { _ in nil }, now: Date.init,
            makeId: { "r1" }, accessibilityTrusted: { true })
        let id = session("61")
        transport.live.insert(id)
        var hello = AgentHostTests.hello(id)
        hello.agent = "ultimate"
        hello.features = ["shown", "readiness"]
        for event in order {
            switch event {
            case "scan": await hub.rescan()
            case "hello": hub.handle(.hello(hello))
            default: hub.handle(.shown(session: id, on: true))
            }
        }
        await hub.rescan()
        let shown = await hub.sessionInFrontWithoutAsking()
        #expect(shown?.id == id)
        #expect(shown?.app.window == "cg:400")
        #expect(await hub.hostShows(id) == true)
        hub.stop()
    }

    @Test func aHoldReasonFromThePageIsGivenOnlyWhileItsWindowIsInFront() async {
        let front = Front()
        front.app = Self.browser
        let ultimate = host(front)
        _ = await ultimate.scan()
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false, problem: "Ultimate shows conversation 999, but it is not listed.", pageConversation: "61"))
        let first = await ultimate.focusInFront(requireClaim: true)
        #expect(first?.problem == "Ultimate shows conversation 999, but it is not listed.")
        #expect(first?.copy?.instance == Self.home)
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false, problem: "A dialog covers Ultimate’s composer.", pageConversation: "61"))
        #expect(await ultimate.focusInFront(requireClaim: true)?.problem == "A dialog covers Ultimate’s composer.")
        front.app = Self.terminal
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
    }

    @Test func aPageThatStopsShowingAConversationLeavesNothingInFront() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        let app = await ultimate.focusInFront(requireClaim: true)?.app
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false))
        #expect(await ultimate.focusInFront(requireClaim: true) == nil)
        #expect(await ultimate.front(among: [location("61")], reported: location("61"), in: app) == .unknown)
    }

    @Test func aReportForAnotherConversationThanTheHubExpectsIsUnknown() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        let app = await ultimate.focusInFront(requireClaim: true)?.app
        #expect(await ultimate.front(among: [location("53"), location("61")], reported: location("53"), in: app) == .unknown)
    }

    @Test func openingShowsTheConversationThroughUltimateAndBringsForwardTheWindowLastSeenShowingIt() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "53@\(Self.home)", on: true, pageConversation: "61"))
        _ = await ultimate.focusInFront(requireClaim: true)
        front.app = Self.terminal
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .opened)
        #expect(front.shown.map(\.0) == [4747])
        #expect(front.shown.map(\.1) == [61])
        #expect(front.activated == [40])
        #expect(front.openedPages.isEmpty)
    }

    @Test func openingWithNoPageSeenYetOpensTheConversationsPage() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.activated.isEmpty)
        #expect(front.openedPages == ["http://ultimate.localhost:4747/?conversation=61"])
    }

    @Test func aWindowLastSeenShowingThePageThatNoLongerShowsItIsNotOpenedButThePageIs() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "53@\(Self.home)", on: true, pageConversation: "53"))
        _ = await ultimate.focusInFront(requireClaim: true)
        front.pages["cg:400"] = "https://example.com/"
        front.app = Self.terminal
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.openedPages == ["http://ultimate.localhost:4747/?conversation=61"])
    }

    @Test(arguments: [true, false])
    func aWindowWhosePageCannotBeReadOrIsNotInFrontYetIsRaisedWithoutOpeningAnotherTab(unreadable: Bool) async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "53@\(Self.home)", on: true, pageConversation: "53"))
        _ = await ultimate.focusInFront(requireClaim: true)
        front.app = Self.terminal
        if unreadable { front.pages["cg:400"] = nil } else { front.activationLags = true }
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        #expect(front.activated == [40])
        #expect(front.openedPages.isEmpty)
    }

    @Test func aPageOpenedForAConversationIsReusedByTheNextOpenOnceItReportsFromTheFront() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .requested)
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        for _ in 0..<50 { await Task.yield() }
        front.app = Self.terminal
        #expect(await ultimate.open(location("53"), stillWanted: { true }) == .opened)
        #expect(front.openedPages == ["http://ultimate.localhost:4747/?conversation=61"])
    }

    @Test func aPageFirstSeenOnASurfaceWithNoMessageBoxIsStillTheWindowAnOpenRaises() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        front.app = Self.browser
        ultimate.observe(.shown(session: "61@\(Self.home)", on: false, problem: "What Ultimate shows has no message box. Open a conversation, or say its name."))
        for _ in 0..<50 { await Task.yield() }
        ultimate.observe(.shown(session: "61@\(Self.home)", on: true, pageConversation: "61"))
        for _ in 0..<50 { await Task.yield() }
        front.app = Self.terminal
        #expect(await ultimate.open(location("53"), stillWanted: { true }) == .opened)
        #expect(front.activated == [Self.browser.pid])
        #expect(front.openedPages.isEmpty)
    }

    @Test func theReaderKeepsAnotherPagesAddressSoAClosedTabReadsAsShowingSomethingElse() {
        let local = URL(string: "http://ultimate.localhost:4747/?conversation=61")!
        let other = URL(string: "https://example.com/news")!
        let link = URL(string: "https://example.com/about")!
        #expect(UltimateHost.pageURL(in: [("AXURL", link), ("AXDocument", other)]) == other)
        #expect(UltimateHost.pageURL(in: [("AXDocument", other), ("AXURL", local)]) == local)
        #expect(UltimateHost.pageURL(in: [("AXURL", link)]) == nil)
        #expect(UltimateHost.pageURL(in: []) == nil)
    }

    @Test func anOpenNoLongerWantedOpensNoPage() async {
        let front = Front()
        let ultimate = host(front)
        _ = await ultimate.scan()
        var wanted = true
        let open = await ultimate.open(location("61"), stillWanted: { defer { wanted = false }; return wanted })
        #expect(open == .failed)
        #expect(front.openedPages.isEmpty)
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

    @Test func anOpenUltimateRefusesSaysWhatItSaid() async {
        let front = Front()
        front.showRefusal = "Invalid UI update"
        let ultimate = host(front)
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .refused("Ultimate refused the page change: Invalid UI update"))
        #expect(front.activated.isEmpty)
        #expect(front.openedPages.isEmpty)
    }

    @Test func aProjectThatIsNotRunningIsNotOpened() async {
        let front = Front()
        let ultimate = host(front, projects: [])
        _ = await ultimate.scan()
        #expect(await ultimate.open(location("61"), stillWanted: { true }) == .failed)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private var peak = 0
        var most: Int { lock.withLock { peak } }
        func enter() { lock.withLock { now += 1; peak = max(peak, now) } }
        func leave() { lock.withLock { now -= 1 } }
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
