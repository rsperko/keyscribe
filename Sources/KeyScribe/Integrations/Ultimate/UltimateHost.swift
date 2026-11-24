import AppKit
import ApplicationServices
import Foundation
import KeyScribeKit

@MainActor
final class UltimateHost: AgentHost {
    nonisolated static let kind = AgentKind(id: "ultimate", displayName: "Ultimate", connectorName: "Ultimate extension")
    nonisolated static let integration: AgentHostIntegration = {
        var integration = AgentHostIntegration(kind: kind, make: { UltimateHost() })
        integration.connector = { UltimateConnector(agentsDir: $0, pluginName: $1) }
        integration.addresses = UltimateAddress.reader(for: kind)
        integration.withSetups = { setups in UltimateHost(enrolled: { setups.setups?.enrolled(agent: kind.id).map(\.folder) ?? [] }) }
        return integration
    }()

    struct Running: Equatable, Sendable {
        var home: String
        var project: UltimateProjects.Project?
        var lock: UltimateProjects.Lock
    }

    struct Report: Equatable {
        var conversation: String?
        var pageConversation: String?
        var on: Bool
        var newConversation: Bool
        var problem: String?

        var claimsFocus: Bool { on || newConversation || problem != nil }
    }

    enum Listing: Equatable, Sendable {
        case connector([UltimateProjects.Conversation])
        case file([UltimateProjects.Conversation]?, connectorFailed: Bool)
    }

    typealias ReadProjects = @Sendable (_ setups: [String]) async -> [Running]
    typealias ReadConversations = @Sendable (_ home: String, _ port: Int) async -> Listing
    typealias ShowConversation = @Sendable (_ port: Int, _ conversation: Int) async -> Bool
    typealias Retitle = @Sendable (_ port: Int, _ conversation: Int, _ title: String) async -> Bool

    private let home: String
    private let enrolled: @MainActor () -> [String]
    private let readProjects: ReadProjects
    private let readConversations: ReadConversations
    private let show: ShowConversation
    private let retitle: Retitle
    private let frontApp: @MainActor () -> AgentHostApp?
    private let documentURL: @Sendable (AgentHostApp) async -> URL?
    private let activate: @MainActor (AgentHostApp, @escaping @MainActor () -> Bool) async -> Bool
    private let openPage: @MainActor (URL) -> Bool
    private var running: [String: Running] = [:]
    private var listed: [String: [UltimateProjects.Conversation]] = [:]
    private var listedByConnector: Set<String> = []
    private var reports: [String: Report] = [:]
    private var lastClaim: [String: Date] = [:]
    private let now: @MainActor () -> Date
    static let pageReportsWithin: TimeInterval = 15
    private var lastWindow: [String: AgentHostApp] = [:]
    private var rememberTasks: [String: Task<Void, Never>] = [:]

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        enrolled: (@MainActor () -> [String])? = nil,
        readProjects: @escaping ReadProjects = UltimateHost.readProjects,
        readConversations: @escaping ReadConversations = { await UltimateHost.readConversations($0, port: $1) },
        show: @escaping ShowConversation = UltimateHost.show,
        retitle: @escaping Retitle = UltimateHost.retitle,
        frontApp: @escaping @MainActor () -> AgentHostApp? = UltimateHost.frontApp,
        documentURL: @escaping @Sendable (AgentHostApp) async -> URL? = UltimateHost.documentURL,
        activate: @escaping @MainActor (AgentHostApp, @escaping @MainActor () -> Bool) async -> Bool = UltimateHost.activate,
        openPage: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.now = now
        self.home = home
        let usual = (home as NSString).appendingPathComponent(UltimateProjects.setupFolderName)
        self.enrolled = enrolled ?? { [usual] }
        self.readProjects = readProjects
        self.readConversations = readConversations
        self.show = show
        self.retitle = retitle
        self.frontApp = frontApp
        self.documentURL = documentURL
        self.activate = activate
        self.openPage = openPage
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
        var sidebarTitles: [String: String] = [:]
        var workspaces: [String: String] = [:]
        var carried: Set<AgentHostLocation> = []
        var problem: String?
        let read = readConversations
        let lists = await withTaskGroup(of: (String, Listing).self) { group in
            for project in found { group.addTask { (project.home, await read(project.home, project.lock.port)) } }
            var lists: [String: Listing] = [:]
            for await (home, listing) in group { lists[home] = listing }
            return lists
        }
        for project in found {
            var conversations: [UltimateProjects.Conversation]?
            switch lists[project.home] {
            case .connector(let rows)?:
                conversations = rows
                listedByConnector.insert(project.home)
            case .file(let rows, let connectorFailed)? where !(connectorFailed && listedByConnector.contains(project.home)):
                conversations = rows
                if rows != nil { listedByConnector.remove(project.home) }
            default:
                conversations = nil
            }
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
                    agent: Self.kind.id, id: conversation.id, pid: nil, cwd: conversation.folder,
                    explicitName: "\(Self.kind.displayName) \(conversation.id)", state: .idle,
                    startedAt: conversation.activeAt, host: location, alias: "\(Self.kind.displayName) \(conversation.id)"))
                if let title = conversation.sidebarTitle { sidebarTitles[location.conversationKey] = title }
                if let handle = conversation.handle { titles[location.conversationKey] = handle }
                if let name = project.project?.name { workspaces[location.conversationKey] = name }
            }
        }
        listed = listed.filter { running[$0.key] != nil }
        listedByConnector = listedByConnector.filter { running[$0] != nil }
        reports = reports.filter { running[$0.key] != nil }
        lastClaim = lastClaim.filter { running[$0.key] != nil }
        lastWindow = lastWindow.filter { running[$0.key] != nil }
        for (instance, task) in rememberTasks where running[instance] == nil {
            task.cancel()
            rememberTasks[instance] = nil
        }
        return .found(sessions, titles: titles, shownInstead: sidebarTitles, carried: carried, problem: problem, workspaces: workspaces)
    }

    private func name(_ project: Running) -> String {
        project.project.map { "Ultimate for \($0.name)" } ?? "An Ultimate project"
    }

    private func location(_ home: String, _ id: String) -> AgentHostLocation {
        AgentHostLocation(host: Self.kind.id, instance: home, native: id)
    }

    func observe(_ event: AgentEvent) {
        guard case .shown(let session, let on, _, let newConversation, let problem, let pageConversation) = event else { return }
        guard let location = Self.location(of: session) else {
            Log.agents.info("\(Self.kind.displayName, privacy: .public) page report was not recorded: invalid conversation identity")
            return
        }
        let wasClaiming = reports[location.instance]?.claimsFocus == true
        let report = Report(
            conversation: on ? location.native : nil, pageConversation: pageConversation,
            on: on, newConversation: newConversation, problem: problem)
        reports[location.instance] = report.claimsFocus ? report : nil
        if report.claimsFocus { lastClaim[location.instance] = now() }
        if !wasClaiming, report.on || report.newConversation {
            let instance = location.instance
            rememberTasks[instance]?.cancel()
            rememberTasks[instance] = Task { @MainActor [weak self] in
                _ = await self?.verifiedPage(requireClaim: true)
                self?.rememberTasks[instance] = nil
            }
        }
        if let problem { Log.agents.info("\(Self.kind.displayName, privacy: .public) page: \(problem, privacy: .public)") }
    }

    nonisolated static func location(of native: String) -> AgentHostLocation? {
        guard let at = native.firstIndex(of: "@"), Int(native[..<at]) != nil else { return nil }
        return AgentHostLocation(host: kind.id, instance: String(native[native.index(after: at)...]), native: String(native[..<at]))
    }

    nonisolated static func isLocalPage(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost", "ultimate.localhost", "[::1]"].contains(url.host) && url.port != nil
    }

    nonisolated static func conversation(in url: URL) -> String? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "conversation" })?.value,
              !value.isEmpty, value.allSatisfy(\.isNumber)
        else { return nil }
        return value
    }

    private static func matches(_ report: Report, urlConversation: String?) -> Bool {
        guard report.claimsFocus else { return false }
        guard let urlConversation else { return report.pageConversation == nil }
        return (report.pageConversation ?? report.conversation) == urlConversation
    }

    private func verifiedPage(requireClaim: Bool) async -> (app: AgentHostApp, project: Running, urlConversation: String?)? {
        guard !running.isEmpty else { return nil }
        if requireClaim, !reports.contains(where: { running[$0.key] != nil && $0.value.claimsFocus }) { return nil }
        guard let app = frontApp(), let window = app.window else { return nil }
        let url = await documentURL(app)
        guard !Task.isCancelled, let after = frontApp(), after.pid == app.pid, after.window == window else { return nil }
        guard let url, Self.isLocalPage(url), let project = running.values.first(where: { $0.lock.port == url.port }) else { return nil }
        var found = after
        found.instance = project.home
        lastWindow[project.home] = found
        return (found, project, Self.conversation(in: url))
    }

    func focusInFront(requireClaim: Bool) async -> AgentHostFocus? {
        guard let page = await verifiedPage(requireClaim: requireClaim) else { return nil }
        let copy = AgentHostCopy(name: name(page.project), instance: page.project.home, enrolled: true)
        guard let report = reports[page.project.home], Self.matches(report, urlConversation: page.urlConversation) else {
            let silent = lastClaim[page.project.home].map { now().timeIntervalSince($0) > Self.pageReportsWithin } ?? true
            return AgentHostFocus(app: page.app, copy: copy, resolvesConversation: true, allowsNewConversation: false, pageSilent: silent)
        }
        return AgentHostFocus(
            app: page.app, copy: copy, problem: report.problem,
            conversation: report.on ? report.conversation.map { location(page.project.home, $0) } : nil,
            resolvesConversation: true, allowsNewConversation: report.newConversation)
    }

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        guard let focus = await focusInFront(requireClaim: true), let shown = focus.conversation, let app = focus.app,
              let reported, reported == shown, locations.contains(shown)
        else { return .unknown }
        return .shown(shown, in: app)
    }

    func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen {
        guard location.host == Self.kind.id, let project = running[location.instance], let conversation = Int(location.native) else { return .failed }
        guard stillWanted() else { return .failed }
        guard await show(project.lock.port, conversation), !Task.isCancelled, stillWanted() else { return .failed }
        if let task = rememberTasks[location.instance] {
            await task.value
            guard !Task.isCancelled, stillWanted() else { return .failed }
        }
        if stillWanted(), let window = lastWindow[location.instance], await activate(window, stillWanted) {
            switch await view(of: project, in: window) {
            case .page: return .opened
            case .unknown: return !Task.isCancelled && stillWanted() ? .requested : .failed
            case .elsewhere: break
            }
        }
        guard !Task.isCancelled, stillWanted(), let page = Self.page(port: project.lock.port, conversation: conversation) else { return .failed }
        Log.agents.info("\(Self.kind.displayName, privacy: .public) open found no window showing the project's page; opening it")
        return openPage(page) ? .requested : .refused("No browser opened \(name(project))\u{2019}s page.")
    }

    nonisolated static func page(port: Int, conversation: Int) -> URL? {
        URL(string: "http://ultimate.localhost:\(port)/?conversation=\(conversation)")
    }

    private enum WindowView { case page, elsewhere, unknown }

    private func view(of project: Running, in window: AgentHostApp) async -> WindowView {
        guard let front = frontApp(), front.pid == window.pid, front.window == window.window, let url = await documentURL(front) else { return .unknown }
        return Self.isLocalPage(url) && url.port == project.lock.port ? .page : .elsewhere
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
                    let path = (folder as NSString).appendingPathComponent(name)
                    guard let resolved = realpath(path, nil) else { continue }
                    let home = String(cString: resolved)
                    free(resolved)
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

    nonisolated static func readConversations(
        _ home: String, port: Int, list: @escaping @Sendable (Int) async -> Data? = UltimateHost.list
    ) async -> Listing {
        let slug = KeyScribePaths.variant.connectorSlug
        let installed = await Task.detached {
            let config = URL(fileURLWithPath: home).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("extensions").appendingPathComponent(slug).appendingPathComponent("keyscribe.json")
            return FileManager.default.fileExists(atPath: config.path)
        }.value
        if installed, let answer = await list(port), let found = UltimateProjects.listed(answer) { return .connector(found) }
        let file = await Task.detached {
            FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(UltimateProjects.conversationsFile))
                .flatMap(UltimateProjects.conversations)
        }.value
        return .file(file, connectorFailed: installed)
    }

    nonisolated static let startupGrace: TimeInterval = 30

    nonisolated static func silentProject(setup: String) async -> String? {
        for project in await readProjects([setup]) {
            let lock = (project.home as NSString).appendingPathComponent(UltimateProjects.lockFile)
            guard let started = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(started) > startupGrace
            else { continue }
            if let answer = await list(port: project.lock.port), UltimateProjects.listed(answer) != nil { continue }
            return project.project?.name ?? (project.home as NSString).lastPathComponent
        }
        return nil
    }

    private nonisolated static func list(port: Int) async -> Data? {
        await post(port: port, path: "/api/extensions/\(KeyScribePaths.variant.connectorSlug)/actions/list", body: ["args": [:]])
    }

    nonisolated static func alive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    nonisolated static let requestTimeout: TimeInterval = 2

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    nonisolated static func show(port: Int, conversation: Int) async -> Bool {
        await post(port: port, path: "/api/ui", body: ["set": ["shell.surface": "agent", "shell.conversation": conversation]]) != nil
    }

    nonisolated static func retitle(port: Int, conversation: Int, title: String) async -> Bool {
        await post(port: port, path: "/api/extensions/conversations/actions/rename", body: ["args": ["id": conversation, "title": title]]) != nil
    }

    private nonisolated static func post(port: Int, path: String, body: [String: Any]) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.httpBody = data
        guard let (answer, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        guard (200..<300).contains(status) else {
            Log.agents.info("Ultimate answered \(status, privacy: .public) to \(path, privacy: .public)")
            return nil
        }
        return answer
    }

    static func frontApp() -> AgentHostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        let process = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(process, 0.05)
        var focused: CFTypeRef?
        let window = AXUIElementCopyAttributeValue(process, kAXFocusedWindowAttribute as CFString, &focused) == .success
            && focused.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
            ? AXWindowID.of(focused as! AXUIElement).map { "cg:\($0)" } : nil
        return AgentHostApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle, window: window, path: app.bundleURL?.path)
    }

    nonisolated static func pageURL(in seen: [(attribute: String, url: URL)]) -> URL? {
        seen.first { isLocalPage($0.url) }?.url ?? seen.first { $0.attribute == kAXDocumentAttribute as String }?.url
    }

    nonisolated static func documentURL(_ app: AgentHostApp) async -> URL? {
        await Task.detached {
            let process = AXUIElementCreateApplication(pid_t(app.pid))
            AXUIElementSetMessagingTimeout(process, 0.05)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(process, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let window = focused as! AXUIElement
            guard AXWindowID.of(window).map({ "cg:\($0)" }) == app.window else { return nil }
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            let deadline = Date().addingTimeInterval(0.3)
            var visited = 0
            var seen: [(attribute: String, url: URL)] = []
            while !queue.isEmpty, visited < 100, Date() < deadline {
                guard !Task.isCancelled else { return nil }
                let (element, depth) = queue.removeFirst()
                visited += 1
                AXUIElementSetMessagingTimeout(element, 0.02)
                for attribute in [kAXDocumentAttribute as String, "AXURL"] {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                          let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { continue }
                    seen.append((attribute, url))
                    if Self.isLocalPage(url) { return url }
                }
                guard depth < 6 else { continue }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                    queue.append(contentsOf: ((children as? [AXUIElement]) ?? []).prefix(100 - visited).map { ($0, depth + 1) })
                }
            }
            return Self.pageURL(in: seen)
        }.value
    }

    static func activate(_ app: AgentHostApp, stillWanted: @escaping @MainActor () -> Bool) async -> Bool {
        guard let window = app.window else { return false }
        let target = VoiceCommandCatalog.Window(bundleId: app.bundle, appName: app.name, pid: Int32(app.pid), id: window, title: "")
        let result = await LiveVoiceCommandSystem().focusWindow(target, stillWanted: stillWanted)
        return result == .focused || result == .alreadyFrontmost
    }
}
