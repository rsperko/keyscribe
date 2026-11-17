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
    }

    private let home: String
    private let enrolled: @MainActor () -> [String]
    private let describe: @Sendable (String) -> BBBuild?
    private let installed: (String) -> Bool
    private let isOpen: @MainActor (BBBuild) -> Bool
    private let run: Run
    private let activate: @MainActor (BBBuild) -> Void
    private let frontmost: @MainActor (Set<String>) -> AgentHostApp?
    private var known: [String: BBBuild] = [:]
    private var listed: [String: [BBThreads.Thread]] = [:]

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        enrolled: (@MainActor () -> [String])? = nil,
        describe: @escaping @Sendable (String) -> BBBuild? = BBBuildFinder.describe(folder:),
        installed: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isOpen: @escaping @MainActor (BBBuild) -> Bool = BBBuildFinder.isOpen,
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3) },
        activate: @escaping @MainActor (BBBuild) -> Void = BBBuildFinder.bringForward,
        frontmost: @escaping @MainActor (Set<String>) -> AgentHostApp? = BBBuildFinder.frontmost(among:)
    ) {
        self.home = home
        let usual = (home as NSString).appendingPathComponent(BBBuilds.usualFolder)
        self.enrolled = enrolled ?? { [usual] }
        self.describe = describe
        self.installed = installed
        self.isOpen = isOpen
        self.run = run
        self.activate = activate
        self.frontmost = frontmost
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
        return builds
    }

    private func environment(_ build: BBBuild) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin", "BB_TELEMETRY": "false", BBBuilds.dataFolderKey: build.folder]
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
        var problems: [String] = []
        for build in builds {
            let threads: [BBThreads.Thread]
            switch await list(build) {
            case .threads(let found):
                threads = found
                listed[build.folder] = found
            case .problem(let problem):
                problems.append(problem)
                guard let kept = listed[build.folder] else { continue }
                threads = kept
                carried.formUnion(kept.map { AgentHostLocation(host: Self.kind.id, instance: build.folder, native: $0.id) })
            }
            for thread in threads {
                let location = AgentHostLocation(host: Self.kind.id, instance: build.folder, native: thread.id)
                sessions.append(AgentSession(
                    agent: Self.kind.id, id: thread.id, pid: nil, cwd: thread.folder, state: thread.state, startedAt: thread.createdAt, host: location))
                titles[location.conversationKey] = thread.title
                shownInstead[location.conversationKey] = thread.shownInstead
            }
        }
        if !problems.isEmpty, problems.count == builds.count { return .unreadable(problems[0]) }
        return .found(sessions, titles: titles, shownInstead: shownInstead, carried: carried, problem: problems.first)
    }

    private func list(_ build: BBBuild) async -> Listing {
        guard isOpen(build) else { return .problem("\(build.name) isn\u{2019}t open. Open \(build.name) to reach its threads.") }
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

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?) async -> AgentHostFront {
        if folders.contains(where: { known[$0] == nil }) { await refreshBuilds() }
        let builds = self.builds
        guard let front = frontmost(Set(builds.compactMap(\.bundle))) else { return .unknown }
        guard let build = builds.first(where: { $0.bundle == front.bundle }) else { return .elsewhere }
        guard front.window != nil else { return .unknown }
        guard let reported, locations.contains(reported), reported.instance == build.folder, thread(at: reported) != nil else { return .unknown }
        return .shown(reported, in: front)
    }

    func focusedWindow() -> AgentHostApp? {
        for folder in folders where known[folder] == nil { known[folder] = describe(folder) ?? BBBuild(folder: folder, name: BBBuilds.fallbackName) }
        let bundles = Set(builds.compactMap(\.bundle))
        guard let front = frontmost(bundles), bundles.contains(front.bundle), front.window != nil else { return nil }
        return front
    }

    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        guard let (build, thread) = await target(location) else { return .refused("bb no longer lists this thread.") }
        guard isOpen(build) else { return .refused("\(build.name) isn\u{2019}t open.") }
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
        guard let (build, thread) = await target(location), isOpen(build),
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
