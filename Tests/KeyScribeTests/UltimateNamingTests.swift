import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct UltimateNamingTests {
    enum Layout: Sendable, CaseIterable { case standing, titled, oneUntitled, twoUntitled, threeUntitled }
    enum Company: Sendable, CaseIterable { case alone, besideAnother }
    enum Projects: Sendable, CaseIterable { case one, twoNamedApart, twoNamedAlike }
    final class Order: @unchecked Sendable { var reversed = false }

    nonisolated static let grid: [(Layout, Company, Projects)] = Layout.allCases.flatMap { layout in
        Company.allCases.flatMap { company in Projects.allCases.map { (layout, company, $0) } }
    }

    static let setup: String = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-ultimate-naming/.ultimate", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }()

    nonisolated static func ids(_ layout: Layout, _ company: Company) -> [String] {
        let own: [String] = switch layout {
        case .standing: ["53"]
        case .titled: ["75"]
        case .oneUntitled: ["61"]
        case .twoUntitled: ["61", "70"]
        case .threeUntitled: ["61", "70", "82"]
        }
        guard company == .besideAnother else { return own }
        return layout == .standing ? own + ["61"] : ["53"] + own
    }

    nonisolated static func conversations(_ ids: [String], home: String, root: String) -> [UltimateProjects.Conversation] {
        ids.map { id in
            id == "53"
                ? .init(id: id, handle: "@ultimate", folder: root)
                : .init(id: id, folder: (home as NSString).appendingPathComponent("worktrees/\(id)"))
        }
    }

    nonisolated static func projects(_ projects: Projects) -> [UltimateHost.Running] {
        let app = UltimateHost.Running(home: "/u/.ultimate/projects/app-1", project: .init(root: "/w/app", name: "app"), lock: .init(pid: 9, port: 4747))
        let web = UltimateHost.Running(home: "/u/.ultimate/projects/web-2", project: .init(root: "/w/web", name: "web"), lock: .init(pid: 10, port: 4748))
        let twin = UltimateHost.Running(home: "/u/.ultimate/projects/app-3", project: .init(root: "/x/app", name: "app"), lock: .init(pid: 11, port: 4749))
        return switch projects {
        case .one: [app]
        case .twoNamedApart: [app, web]
        case .twoNamedAlike: [app, twin]
        }
    }

    nonisolated static func baseName(_ id: String) -> String {
        switch id {
        case "53": "ultimate"
        case "75": "release notes"
        default: "ultimate \(id)"
        }
    }

    nonisolated static func expected(_ layout: Layout, _ company: Company, _ projects: Projects) -> [String] {
        let running = Self.projects(projects)
        return running.enumerated().flatMap { index, project in
            ids(layout, company).map { id in
                let base = baseName(id)
                let name = switch projects {
                case .one: base
                case .twoNamedApart: "\(project.project!.name) \(base)"
                case .twoNamedAlike: index == 0 ? base : "\(base) blue"
                }
                return "\(project.home.split(separator: "/").last!)/\(id)=\(name)"
            }
        }.sorted()
    }

    func integration(_ host: UltimateHost) -> AgentHostIntegration {
        var integration = AgentHostIntegration(kind: UltimateHost.kind, make: { host })
        integration.addresses = UltimateHost.integration.addresses
        return integration
    }

    func resolve(_ text: String, through hub: AgentHub) -> AgentRecipient.Resolution {
        let snapshot = AgentSnapshot(
            names: hub.names, conversations: hub.recordingOrder, former: hub.formerNames, shared: hub.sharedNames, natives: hub.nativeRoster)
        let address = AgentAddress.parse(text, names: snapshot.spokenNames, afterVerb: snapshot.afterVerbNames, natives: snapshot.natives)
        return AgentRecipient.resolve(address, focused: nil, rows: snapshot.rows, names: snapshot.addressable, shared: snapshot.sharedNames)
    }

    func id(_ native: String, in project: Projects = .one, at index: Int = 0) -> String {
        AgentSessionID.make(agent: "ultimate", native: AgentHostLocation(
            host: "ultimate", instance: Self.projects(project)[index].home, native: native).conversationKey)
    }

    func hub(_ layout: Layout, _ company: Company, _ projects: Projects, _ order: Order = Order()) async -> (AgentHub, () async -> Void) {
        let listed = Self.projects(projects)
        let roots = Dictionary(uniqueKeysWithValues: listed.map { ($0.home, $0.project!.root) })
        let ids = Self.ids(layout, company)
        let host = UltimateHost(
            home: "/u", enrolled: { [Self.setup] }, readProjects: { _ in order.reversed ? listed.reversed() : listed },
            readConversations: { home, _ in
                let found = Self.conversations(ids, home: home, root: roots[home]!)
                return .connector(order.reversed ? found.reversed() : found)
            },
            show: { _, _ in false }, retitle: { _, _, _ in false }, frontApp: { nil }, activate: { _, _ in false })
        let transport = AgentHubTests.FakeTransport()
        let hub = AgentHub(
            transport: transport, discovery: [AgentHubTests.FakeDiscovery(kind: .claude)], names: nil, focus: nil, front: nil,
            receiptTimeout: .milliseconds(50), handOffLimit: .seconds(30), scanDeadline: .seconds(30), places: nil,
            hosts: [integration(host)], hostAllowed: { _ in true }, hostDeadline: .milliseconds(200),
            hostConfirmDelay: .seconds(3), heldLimit: .milliseconds(100),
            processEnvironment: { _, _ in [:] }, processParent: { _ in nil }, now: Date.init,
            makeId: { "r1" }, accessibilityTrusted: { true })
        let greet = {
            guard ids.contains("75") else { return }
            for project in order.reversed ? listed.reversed() : listed {
                let session = AgentSessionID.make(agent: "ultimate", native: AgentHostLocation(host: "ultimate", instance: project.home, native: "75").conversationKey)
                var hello = AgentHostTests.hello(session)
                hello.agent = "ultimate"
                hello.title = "release notes"
                transport.live.insert(session)
                hub.handle(.hello(hello))
            }
        }
        await hub.rescan()
        greet()
        await hub.rescan()
        return (hub, {
            order.reversed = true
            greet()
            await hub.rescan()
        })
    }

    @Test(arguments: grid)
    func eachConversationIsNamedByWhatUltimateShowsAndQualifiedByItsProjectOnlyWhenThatTellsItApart(
        layout: Layout, company: Company, projects: Projects
    ) async {
        let (hub, reorder) = await hub(layout, company, projects)
        let handles = { hub.directory.conversations.map { "\($0.host!.instance.split(separator: "/").last!)/\($0.host!.native)=\($0.handle)" }.sorted() }
        #expect(handles() == Self.expected(layout, company, projects))
        #expect(hub.sharedNames.keys.allSatisfy { !["app", "web"].contains($0) })
        await reorder()
        #expect(handles() == Self.expected(layout, company, projects), "names stay when Ultimate lists and greets in the other order")
    }

    @Test func theStandingAgentAndAnUntitledBranchAreEachReachedByTheirOwnName() async {
        let (hub, _) = await hub(.twoUntitled, .besideAnother, .one)
        let names = hub.directory.conversations.map(\.handle)
        #expect(AgentAddress.parse("tell ultimate run the tests", names: names) == .name("ultimate", body: "run the tests"))
        #expect(AgentAddress.parse("tell ultimate 61 run the tests", names: names) == .name("ultimate 61", body: "run the tests"))
        #expect(AgentAddress.parse("tell ultimate 70 run the tests", names: names) == .name("ultimate 70", body: "run the tests"))
    }

    @Test func aBranchNamedSinceTheLastTakeIsStillReachedByItsNumberAndNeverByTheStandingAgent() async throws {
        let (hub, _) = await hub(.oneUntitled, .besideAnother, .one)
        let home = Self.projects(.one)[0].home
        let session = AgentSessionID.make(agent: "ultimate", native: AgentHostLocation(host: "ultimate", instance: home, native: "61").conversationKey)
        var hello = AgentHostTests.hello(session)
        hello.agent = "ultimate"
        hello.title = "release notes"
        hub.handle(.hello(hello))
        await hub.rescan()
        #expect(hub.directory.conversations.contains { $0.id == session && $0.handle == "release notes" })
        for said in ["tell ultimate 61 run the tests", "tell ultimate sixty one run the tests", "tell ultimate conversation 61 run the tests"] {
            #expect(resolve(said, through: hub) == .deliver(id: session, body: "run the tests", source: .spoken), "\(said)")
        }
        #expect(hub.directory.conversations.first { $0.id == session }?.otherNames == ["ultimate 61"])
    }

    @Test(arguments: [
        ("tell ultimate 61 tests are failing", "61", "tests are failing"),
        ("tell ultimate seventy, tests are failing", "70", "tests are failing"),
        ("tell ultimate there are 99 failing tests", "53", "there are 99 failing tests"),
        ("tell ultimate, 99 tests are failing", "53", "99 tests are failing"),
        ("tell ultimate 99 tests are failing", nil, ""),
        ("tell ultimate 99, tests are failing", nil, ""),
        ("tell ultimate six eight, tests are failing", nil, ""),
        ("ultimate 68 reply ready", nil, ""),
    ])
    func aNumberAfterTheStandingAgentsNameIsABranchNumberAndAnUnknownOneHolds(said: String, native: String?, body: String) async {
        let (hub, _) = await hub(.twoUntitled, .besideAnother, .one)
        let resolution = resolve(said, through: hub)
        if let native {
            #expect(resolution == .deliver(id: id(native), body: body, source: .spoken))
        } else if case .ask(_, .unknownName) = resolution {
        } else {
            Issue.record("expected a hold, got \(resolution)")
        }
    }

    @Test func twoProjectsWithTheSameBranchNumberAskUnlessTheProjectIsSaid() async {
        let (hub, _) = await hub(.oneUntitled, .alone, .twoNamedApart)
        let offered: [String]? = switch resolve("tell ultimate 61 run the tests", through: hub) {
        case .ask(_, .ambiguousName(_, let matches)), .ask(_, .sharedName(_, let matches, _)): matches.sorted()
        default: nil
        }
        #expect(offered == ["app ultimate 61", "web ultimate 61"])
        #expect(resolve("tell web ultimate sixty one run the tests", through: hub)
                == .deliver(id: id("61", in: .twoNamedApart, at: 1), body: "run the tests", source: .spoken))
        #expect(resolve("tell app ultimate 61 run the tests", through: hub)
                == .deliver(id: id("61", in: .twoNamedApart, at: 0), body: "run the tests", source: .spoken))
    }

    @Test func anUntitledBranchSharingItsNumberWithATitledOneInAnotherProjectIsNamedByItsProject() async {
        let (hub, _) = await hub(.oneUntitled, .alone, .twoNamedApart)
        let titled = id("61", in: .twoNamedApart, at: 0)
        let untitled = id("61", in: .twoNamedApart, at: 1)
        var hello = AgentHostTests.hello(titled)
        hello.agent = "ultimate"
        hello.title = "release notes"
        hub.handle(.hello(hello))
        await hub.rescan()
        #expect(hub.directory.conversations.first { $0.id == titled }?.handle == "release notes")
        #expect(hub.directory.conversations.first { $0.id == untitled }?.handle == "web ultimate 61")
        #expect(resolve("tell ultimate 61 run the tests", through: hub)
                == .ask(body: "run the tests", reason: .ambiguousName("ultimate 61", matches: ["release notes", "web ultimate 61"])))
        #expect(resolve("tell web ultimate 61 run the tests", through: hub) == .deliver(id: untitled, body: "run the tests", source: .spoken))
        #expect(resolve("tell release notes run the tests", through: hub) == .deliver(id: titled, body: "run the tests", source: .spoken))
    }
}
