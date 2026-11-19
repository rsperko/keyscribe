import AppKit
import Foundation
import KeyScribeKit

@MainActor
final class UltimateHost: AgentHost {
    nonisolated static let kind = AgentKind(id: "ultimate", displayName: "Ultimate", connectorName: "Ultimate extension")
    nonisolated static let integration: AgentHostIntegration = {
        var integration = AgentHostIntegration(kind: kind, make: { UltimateHost() })
        integration.connector = { UltimateConnector(agentsDir: $0, pluginName: $1) }
        integration.withSetups = { setups in UltimateHost(enrolled: { setups.setups?.enrolled(agent: kind.id).map(\.folder) ?? [] }) }
        return integration
    }()

    struct Running: Equatable, Sendable {
        var home: String
        var project: UltimateProjects.Project?
        var lock: UltimateProjects.Lock
    }

    struct Page: Equatable {
        var location: AgentHostLocation
        var app: AgentHostApp
    }

    typealias ReadProjects = @Sendable (_ setups: [String]) async -> [Running]
    typealias ReadConversations = @Sendable (_ home: String) async -> [UltimateProjects.Conversation]?
    typealias ShowConversation = @Sendable (_ port: Int, _ conversation: Int) async -> Bool
    typealias Retitle = @Sendable (_ port: Int, _ conversation: Int, _ title: String) async -> Bool

    private let home: String
    private let enrolled: @MainActor () -> [String]
    private let readProjects: ReadProjects
    private let readConversations: ReadConversations
    private let show: ShowConversation
    private let retitle: Retitle
    private let frontApp: @MainActor () -> AgentHostApp?
    private let activate: @MainActor (Int) -> Bool
    private var running: [String: Running] = [:]
    private var listed: [String: [UltimateProjects.Conversation]] = [:]
    private var shown: [String: Page] = [:]
    private var lastPid: [String: Int] = [:]

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        enrolled: (@MainActor () -> [String])? = nil,
        readProjects: @escaping ReadProjects = UltimateHost.readProjects,
        readConversations: @escaping ReadConversations = UltimateHost.readConversations,
        show: @escaping ShowConversation = UltimateHost.show,
        retitle: @escaping Retitle = UltimateHost.retitle,
        frontApp: @escaping @MainActor () -> AgentHostApp? = UltimateHost.frontApp,
        activate: @escaping @MainActor (Int) -> Bool = UltimateHost.activate
    ) {
        self.home = home
        let usual = (home as NSString).appendingPathComponent(UltimateProjects.setupFolderName)
        self.enrolled = enrolled ?? { [usual] }
        self.readProjects = readProjects
        self.readConversations = readConversations
        self.show = show
        self.retitle = retitle
        self.frontApp = frontApp
        self.activate = activate
    }

    private var setups: [String] {
        var seen: Set<String> = []
        return enrolled().map { ConnectorFolders.canonical(URL(fileURLWithPath: $0)).path }.filter { seen.insert($0).inserted }
    }

    var isEnabled: Bool { setups.contains { FileManager.default.fileExists(atPath: $0) } }

    var takesImages: Bool { true }

    func deliveryRoute(at location: AgentHostLocation) -> AgentHostDeliveryRoute { .connector }

    func scan() async -> AgentHostScan {
        let found = await readProjects(setups)
        running = Dictionary(found.map { ($0.home, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [AgentSession] = []
        var titles: [String: String] = [:]
        var workspaces: [String: String] = [:]
        var carried: Set<AgentHostLocation> = []
        var problem: String?
        for project in found {
            var conversations = await readConversations(project.home)
            if conversations == nil, let kept = listed[project.home] {
                conversations = kept
                carried.formUnion(kept.map { location(project.home, $0.id) })
                problem = problem ?? "\(name(project)) didn\u{2019}t list its conversations. Try again in a moment."
            }
            guard let conversations else { continue }
            listed[project.home] = conversations
            for conversation in conversations {
                let location = location(project.home, conversation.id)
                sessions.append(AgentSession(
                    agent: Self.kind.id, id: conversation.id, pid: project.lock.pid, cwd: conversation.folder,
                    explicitName: conversation.handle == nil ? "\(Self.kind.displayName) \(conversation.id)" : nil, state: .idle,
                    startedAt: conversation.activeAt, host: location))
                if let handle = conversation.handle { titles[location.conversationKey] = handle }
                if let name = project.project?.name { workspaces[location.conversationKey] = name }
            }
        }
        listed = listed.filter { running[$0.key] != nil }
        shown = shown.filter { running[$0.key] != nil }
        return .found(sessions, titles: titles, carried: carried, problem: problem, workspaces: workspaces)
    }

    private func name(_ project: Running) -> String {
        project.project.map { "Ultimate for \($0.name)" } ?? "An Ultimate project"
    }

    private func location(_ home: String, _ id: String) -> AgentHostLocation {
        AgentHostLocation(host: Self.kind.id, instance: home, native: id)
    }

    func observe(_ event: AgentEvent) {
        guard case .shown(let session, let on, _, _) = event, let location = Self.location(of: session) else { return }
        guard on else {
            shown[location.instance] = nil
            return
        }
        guard let app = frontApp() else { return }
        shown[location.instance] = Page(location: location, app: app)
        lastPid[location.instance] = app.pid
    }

    nonisolated static func location(of session: String) -> AgentHostLocation? {
        guard let (agent, native) = AgentSessionID.split(session), agent == kind.id, let at = native.firstIndex(of: "@") else { return nil }
        let conversation = native[..<at].replacingOccurrences(of: "%40", with: "@").replacingOccurrences(of: "%25", with: "%")
        return AgentHostLocation(host: kind.id, instance: String(native[native.index(after: at)...]), native: conversation)
    }

    func focusedWindow() -> AgentHostApp? {
        guard let front = frontApp() else { return nil }
        let pages = shown.values.filter { $0.app.pid == front.pid }
        guard pages.count == 1, let page = pages.first else { return nil }
        var app = front
        app.window = running[page.location.instance]?.project?.name ?? page.location.instance
        app.instance = page.location.instance
        return app
    }

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        guard let app, let instance = app.instance, let page = shown[instance], page.app.pid == app.pid,
              let reported, reported == page.location, locations.contains(reported)
        else { return .unknown }
        return .shown(reported, in: app)
    }

    func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen {
        guard location.host == Self.kind.id, let project = running[location.instance], let conversation = Int(location.native) else { return .failed }
        guard stillWanted() else { return .failed }
        guard await show(project.lock.port, conversation), !Task.isCancelled, stillWanted() else { return .failed }
        guard let pid = lastPid[location.instance], activate(pid) else { return .requested }
        return .opened
    }

    func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
        guard location.host == Self.kind.id, let project = running[location.instance], let id = Int(location.native),
              let conversation = listed[location.instance]?.first(where: { $0.id == location.native }), conversation.handle == nil
        else { return false }
        return await retitle(project.lock.port, id, name)
    }

    nonisolated static func readProjects(_ setups: [String]) async -> [Running] {
        await Task.detached {
            var found: [Running] = []
            for setup in setups {
                let folder = (setup as NSString).appendingPathComponent(UltimateProjects.projectsFolder)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names.sorted() where !name.hasPrefix(".") {
                    let home = (folder as NSString).appendingPathComponent(name)
                    guard let data = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(UltimateProjects.lockFile)),
                          let lock = UltimateProjects.lock(data), alive(lock.pid)
                    else { continue }
                    let project = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(UltimateProjects.projectFile))
                        .flatMap(UltimateProjects.project)
                    found.append(Running(home: home, project: project, lock: lock))
                }
            }
            return found
        }.value
    }

    nonisolated static func readConversations(_ home: String) async -> [UltimateProjects.Conversation]? {
        await Task.detached {
            FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(UltimateProjects.conversationsFile))
                .flatMap(UltimateProjects.conversations)
        }.value
    }

    nonisolated static func alive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    nonisolated static let requestTimeout: TimeInterval = 2

    nonisolated static func show(port: Int, conversation: Int) async -> Bool {
        await post(port: port, path: "/api/ui", body: ["set": ["shell.surface": "agent", "shell.conversation": conversation]])
    }

    nonisolated static func retitle(port: Int, conversation: Int, title: String) async -> Bool {
        await post(port: port, path: "/api/extensions/conversations/actions/rename", body: ["args": ["id": conversation, "title": title]])
    }

    private nonisolated static func post(port: Int, path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"), let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.httpBody = data
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return false }
        return (200..<300).contains(status)
    }

    static func frontApp() -> AgentHostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        return AgentHostApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle, path: app.bundleURL?.path)
    }

    static func activate(pid: Int) -> Bool {
        NSRunningApplication(processIdentifier: pid_t(pid))?.activate() ?? false
    }
}
