import AppKit
import Foundation
import KeyScribeKit

@MainActor
final class BBHost: AgentHost {
    typealias Run = @Sendable (_ argv: [String], _ subcommand: String, _ input: Data?, _ environment: [String: String]) async throws -> HostCLI.Output

    nonisolated static let kind = AgentKind(id: "bb", displayName: "bb", connectorName: "bb plugin")
    nonisolated static let integration: AgentHostIntegration = {
        var integration = AgentHostIntegration(kind: kind, make: { BBHost() })
        integration.connector = { BBPluginConnector(agentsDir: $0, pluginName: $1) }
        integration.folderVariable = BBBuilds.dataFolderKey
        integration.withSetups = { setups in BBHost(enrolled: { setups.setups?.enrolled(agent: kind.id).map(\.folder) ?? [] }) }
        return integration
    }()

    private enum Listing {
        case threads([BBThreads.Thread])
        case problem(String)
        case closed(String)
    }

    private let home: String
    private let enrolled: @MainActor () -> [String]
    private let describe: @Sendable (String) -> BBBuild?
    private let installed: (String) -> Bool
    private let isOpen: @MainActor (BBBuild) -> Bool
    private let serving: @MainActor (BBBuild) -> Bool
    private let run: Run
    private let activate: @MainActor (BBBuild) -> Void
    private let frontmost: @MainActor (Set<String>) -> AgentHostApp?
    private let dataFolder: @Sendable (String) -> String?
    private let frontApp: @MainActor () -> AgentHostApp?
    typealias StopWatching = @Sendable () -> Void
    private let appsChanging: @MainActor (@escaping @MainActor (_ app: String, _ launched: Bool) -> Void) -> StopWatching
    nonisolated(unsafe) private var stopWatching: StopWatching?
    private var listChanged: (@MainActor (AgentHostChange) -> Void)?
    private let launchRetries: Int
    private let launchRetryDelay: Duration
    private var launching: [String: Int] = [:]
    private var known: [String: BBBuild] = [:]
    private var copies: [String: BBBuild?] = [:]
    private var listed: [String: [BBThreads.Thread]] = [:]

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        enrolled: (@MainActor () -> [String])? = nil,
        describe: (@Sendable (String) -> BBBuild?)? = nil,
        installed: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isOpen: @escaping @MainActor (BBBuild) -> Bool = BBBuildFinder.isOpen,
        serving: @escaping @MainActor (BBBuild) -> Bool = { BBBuildFinder.serves(folder: $0.folder) },
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3) },
        activate: @escaping @MainActor (BBBuild) -> Void = BBBuildFinder.bringForward,
        frontmost: @escaping @MainActor (Set<String>) -> AgentHostApp? = BBBuildFinder.frontmost(among:),
        frontApp: @escaping @MainActor () -> AgentHostApp? = HostFront.app,
        dataFolder: (@Sendable (String) -> String?)? = nil,
        appsChanging: @escaping @MainActor (@escaping @MainActor (_ app: String, _ launched: Bool) -> Void) -> StopWatching
            = BBBuildFinder.watchLaunches,
        launchRetries: Int = 8, launchRetryDelay: Duration = .seconds(2)
    ) {
        self.appsChanging = appsChanging
        self.launchRetries = launchRetries
        self.launchRetryDelay = launchRetryDelay
        self.home = home
        let usual = (home as NSString).appendingPathComponent(BBBuilds.usualFolder)
        self.enrolled = enrolled ?? { [usual] }
        self.describe = describe ?? { BBBuildFinder.describe(folder: $0, home: home) }
        self.installed = installed
        self.isOpen = isOpen
        self.serving = serving
        self.run = run
        self.activate = activate
        self.frontmost = frontmost
        self.dataFolder = dataFolder ?? { BBBuildFinder.declaredFolder(app: $0, home: home) }
        self.frontApp = frontApp
    }

    private var folders: [String] {
        var seen: Set<String> = []
        return enrolled().filter { seen.insert($0).inserted }
    }

    private var builds: [BBBuild] { folders.map { known[$0] ?? BBBuild(folder: $0, name: BBBuilds.fallbackName) } }

    @discardableResult
    private func refreshBuilds(_ only: [String]? = nil) async -> [BBBuild] {
        let folders = only ?? self.folders
        let describe = self.describe
        let found = await Task.detached { folders.map { ($0, describe($0)) } }.value
        for (folder, build) in found { known[folder] = build ?? BBBuild(folder: folder, name: BBBuilds.fallbackName) }
        copies = [:]
        return builds
    }

    private func environment(_ build: BBBuild) -> [String: String] {
        BBBuildFinder.environment(folder: build.folder, home: home)
    }

    deinit { stopWatching?() }

    func watch(_ listChanged: @escaping @MainActor (AgentHostChange) -> Void) {
        unwatch()
        self.listChanged = listChanged
        stopWatching = appsChanging { [weak self] app, launched in
            guard let self else { return }
            let copies = self.folders(of: app)
            guard !copies.isEmpty else { return }
            if launched { for folder in copies { self.launching[folder] = self.launchRetries } }
            self.listChanged?(.listing)
        }
    }

    func unwatch() {
        stopWatching?()
        stopWatching = nil
        listChanged = nil
        launching = [:]
    }

    private func folders(of app: String) -> [String] {
        let running = describedBuilds.filter { $0.app == app }.map(\.folder)
        let declared = dataFolder(app).flatMap { folders.contains($0) ? [$0] : nil } ?? []
        return Array(Set(running + declared))
    }

    private func retryLaunched(_ results: [String: Bool]) {
        var again = false
        for (folder, listedNow) in results {
            guard let left = launching[folder] else { continue }
            if listedNow || left <= 1 {
                launching[folder] = nil
            } else {
                launching[folder] = left - 1
                again = true
            }
        }
        guard again else { return }
        let delay = launchRetryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.listChanged?(.listing)
        }
    }

    var isEnabled: Bool { folders.contains { installed((($0 as NSString).appendingPathComponent(BBBuilds.launcherPath))) } }

    var takesImages: Bool { true }

    var identityKeys: [String] { [BBThreads.threadKey, BBThreads.storageKey] }

    func location(in environment: [String: String]) -> AgentHostLocation? {
        for folder in folders {
            if let thread = BBThreads.thread(in: environment, instance: folder) {
                return AgentHostLocation(host: Self.kind.id, instance: folder, native: thread)
            }
        }
        return nil
    }

    func scan() async -> AgentHostScan {
        let builds = await refreshBuilds()
        var sessions: [AgentSession] = []
        var titles: [String: String] = [:]
        var shownInstead: [String: String] = [:]
        var carried: Set<AgentHostLocation> = []
        var listedNow: [String: Bool] = [:]
        var firstUnlisted: String?
        var problem: String?
        defer { retryLaunched(listedNow) }
        for build in builds {
            func lastSeen(_ said: String) -> [BBThreads.Thread] {
                listedNow[build.folder] = false
                firstUnlisted = firstUnlisted ?? said
                let kept = listed[build.folder] ?? []
                carried.formUnion(kept.map { AgentHostLocation(host: Self.kind.id, instance: build.folder, native: $0.id) })
                return kept
            }
            let threads: [BBThreads.Thread]
            switch await list(build) {
            case .threads(let found):
                threads = found
                listed[build.folder] = found
                listedNow[build.folder] = true
            case .closed(let said):
                threads = lastSeen(said)
            case .problem(let said):
                problem = problem ?? said
                threads = lastSeen(said)
            }
            for thread in threads {
                let location = AgentHostLocation(host: Self.kind.id, instance: build.folder, native: thread.id)
                sessions.append(AgentSession(
                    agent: Self.kind.id, id: thread.id, pid: nil, cwd: thread.folder, state: thread.state, startedAt: thread.createdAt, host: location))
                titles[location.conversationKey] = thread.title
                shownInstead[location.conversationKey] = thread.shownInstead
            }
        }
        if let unlisted = problem ?? firstUnlisted, !listedNow.values.contains(true) { return .unreadable(unlisted) }
        return .found(sessions, titles: titles, shownInstead: shownInstead, carried: carried, problem: problem)
    }

    private func reachable(_ build: BBBuild) -> Bool { isOpen(build) || serving(build) }

    private func list(_ build: BBBuild) async -> Listing {
        guard reachable(build) else {
            guard build.app == nil else { return .closed("\(build.name) isn\u{2019}t open. Open \(build.name) to reach its threads.") }
            return .closed(
                "Open the copy of bb that uses \(shown(build.folder)) to reach its threads. "
                    + "If it\u{2019}s already open, \(Branding.appName) can\u{2019}t tell that it uses this folder.")
        }
        guard let output = try? await call(build, ["thread", "list", "--json"], subcommand: "thread list"), output.status == 0, !output.truncated,
              let threads = BBThreads.parse(output.stdout)
        else { return .problem("\(build.name) could not list its threads. Try again in a moment.") }
        return .threads(threads)
    }

    func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen {
        guard let (build, thread) = await target(location), isOpen(build),
              let output = try? await call(build, ["thread", "open", thread, "--json"], subcommand: "thread open"),
              let windows = BBThreads.openedWindows(status: output.status, stdout: output.stdout), windows > 0,
              !Task.isCancelled, stillWanted()
        else { return .failed }
        activate(build)
        return .requested
    }

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        guard let app, app.window != nil, let instance = app.instance, folders.contains(instance) else { return .unknown }
        guard let reported, locations.contains(reported), reported.instance == instance, thread(at: reported) != nil else { return .unknown }
        return .shown(reported, in: app)
    }

    private var describedBuilds: [BBBuild] {
        for folder in folders where known[folder] == nil { known[folder] = describe(folder) ?? BBBuild(folder: folder, name: BBBuilds.fallbackName) }
        return builds
    }

    func focusedWindow() -> AgentHostApp? {
        let builds = describedBuilds
        guard let app = frontApp(), let build = build(runningAs: app, among: builds),
              var front = frontmost([app.bundle]), front.window != nil, front.pid == app.pid
        else { return nil }
        front.instance = build.folder
        return front
    }

    func copyInFront() -> AgentHostCopy? {
        let builds = describedBuilds
        guard let front = frontApp(), let path = front.path else { return nil }
        let name = BBBuilds.name(info: nil, app: path)
        if let copy = build(runningAs: front, among: builds) ?? copy(at: path, bundle: front.bundle) {
            return AgentHostCopy(name: name, instance: copy.folder, enrolled: folders.contains(copy.folder))
        }
        guard let declared = dataFolder(path) else { return nil }
        return AgentHostCopy(name: name, instance: declared, enrolled: folders.contains(declared), setUp: false)
    }

    private func build(runningAs front: AgentHostApp, among builds: [BBBuild]) -> BBBuild? {
        guard let path = front.path else {
            let sharing = builds.filter { $0.bundle != nil && $0.bundle == front.bundle }
            return sharing.count == 1 ? sharing[0] : nil
        }
        if let exact = builds.first(where: { $0.app == path }) { return exact }
        guard let copy = copy(at: path, bundle: front.bundle), builds.contains(where: { $0.folder == copy.folder }) else { return nil }
        return copy
    }

    private func shown(_ folder: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return folder.hasPrefix(prefix) ? "~/" + folder.dropFirst(prefix.count) : folder
    }

    private func copy(at path: String, bundle: String) -> BBBuild? {
        let key = path + "\n" + bundle
        if let cached = copies[key] { return cached }
        let usual = ConnectorFolders.canonical(URL(fileURLWithPath: (home as NSString).appendingPathComponent(BBBuilds.usualFolder))).path
        if let declared = dataFolder(path) {
            let found = known[declared].flatMap { $0.app == nil ? nil : $0 } ?? describe(declared)
            if let found, known[declared] != nil { known[declared] = found }
            if found != nil { copies[key] = .some(found) }
            return found
        }
        let runs = { (build: BBBuild) in build.app == path || (build.bundle != nil && build.bundle == bundle) }
        let notDescribed = known[usual] == nil
        let describedWithoutApp = known[usual].map { $0.app == nil } ?? false
        let found = known[usual].flatMap { runs($0) ? $0 : nil }
            ?? (notDescribed || describedWithoutApp ? describe(usual).flatMap { runs($0) ? $0 : nil } : nil)
        if let found, known[usual] != nil { known[usual] = found }
        copies[key] = .some(found)
        return found
    }

    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        guard let (build, thread) = await target(location) else { return .refused("bb no longer lists this thread.") }
        guard reachable(build) else { return .refused("\(build.name) isn\u{2019}t open.") }
        let output: HostCLI.Output
        do {
            output = try await call(
                build, ["thread", "tell", thread, "--message-file", "-", "--mode", "auto", "--json"] + images.flatMap { ["--image", $0] },
                subcommand: "thread tell", input: Data(text.utf8))
        } catch HostCLI.Failure.couldNotStart {
            return .refused("\(build.name) could not start.")
        } catch {
            return .uncertain
        }
        switch BBThreads.delivery(status: output.status, stdout: output.stdout) {
        case .sent: return .accepted
        case .queued: return .queued
        case .refused(let why, let code, let message):
            Log.agents.notice("bb refused a message: \(code ?? "no code", privacy: .public) \(message ?? "", privacy: .private)")
            return .refused(why)
        case .unclear: return .uncertain
        }
    }

    func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
        guard let (build, thread) = await target(location), reachable(build),
              let output = try? await call(build, ["thread", "update", thread, "--title=\(name)", "--json"], subcommand: "thread update")
        else { return false }
        return output.status == 0
    }

    private func thread(at location: AgentHostLocation) -> String? {
        guard location.host == Self.kind.id, folders.contains(location.instance), BBThreads.isThreadId(location.native) else { return nil }
        return location.native
    }

    private func target(_ location: AgentHostLocation) async -> (BBBuild, String)? {
        guard let thread = thread(at: location) else { return nil }
        await refreshBuilds([location.instance])
        guard let build = known[location.instance] else { return nil }
        return (build, thread)
    }

    private func call(_ build: BBBuild, _ arguments: [String], subcommand: String, input: Data? = nil) async throws -> HostCLI.Output {
        try await run([build.launcher] + arguments, subcommand, input, environment(build))
    }
}
