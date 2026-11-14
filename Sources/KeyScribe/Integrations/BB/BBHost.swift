import AppKit
import Foundation
import KeyScribeKit

@MainActor
final class BBHost: AgentHost {
    typealias Run = @Sendable (_ argv: [String], _ subcommand: String, _ input: Data?, _ environment: [String: String]) async throws -> HostCLI.Output

    nonisolated static let kind = AgentKind(id: "bb", displayName: "bb", connectorName: "bb")
    nonisolated static let app = "dev.bb.desktop"
    nonisolated static let integration = AgentHostIntegration(kind: kind, make: { BBHost() })

    private let home: String
    private let installed: (String) -> Bool
    private let running: @MainActor () -> Bool
    private let run: Run
    private let activate: @MainActor () -> Void

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        installed: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        running: @escaping @MainActor () -> Bool = { BBHost.runningApp != nil },
        run: @escaping Run = { try await HostCLI.run($0, subcommand: $1, input: $2, environment: $3) },
        activate: @escaping @MainActor () -> Void = BBHost.bringForward
    ) {
        self.home = home
        self.installed = installed
        self.running = running
        self.run = run
        self.activate = activate
    }

    private var dataDirectory: String { (home as NSString).appendingPathComponent(".bb") }
    private var cli: String { (dataDirectory as NSString).appendingPathComponent("bin/bb") }
    private var environment: [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin", "BB_TELEMETRY": "false", "BB_DATA_DIR": dataDirectory]
    }

    var isEnabled: Bool { installed(cli) }

    var takesImages: Bool { true }

    var identityKeys: [String] { [BBThreads.threadKey, BBThreads.storageKey] }

    func location(in environment: [String: String]) -> AgentHostLocation? {
        BBThreads.thread(in: environment, instance: dataDirectory).map { AgentHostLocation(host: Self.kind.id, instance: dataDirectory, native: $0) }
    }

    func scan() async -> AgentHostScan {
        guard running() else { return .unreadable("bb isn\u{2019}t open. Open bb to reach its threads.") }
        let unreadable = AgentHostScan.unreadable("bb could not list its threads. Try again in a moment.")
        guard let output = try? await call(["thread", "list", "--json"], subcommand: "thread list"), output.status == 0, !output.truncated,
              let threads = BBThreads.parse(output.stdout)
        else { return unreadable }
        let instance = dataDirectory
        return .found(threads.map { thread in
            AgentSession(
                agent: Self.kind.id, id: thread.id, pid: nil, cwd: thread.folder, state: thread.state, startedAt: thread.createdAt,
                host: AgentHostLocation(host: Self.kind.id, instance: instance, native: thread.id))
        })
    }

    func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen {
        guard running(), let thread = thread(at: location),
              let output = try? await call(["thread", "open", thread, "--json"], subcommand: "thread open"),
              let windows = BBThreads.openedWindows(status: output.status, stdout: output.stdout), windows > 0,
              !Task.isCancelled, stillWanted()
        else { return .failed }
        activate()
        return .requested
    }

    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        guard let thread = thread(at: location) else { return .refused("bb no longer lists this thread.") }
        guard running() else { return .refused("bb isn\u{2019}t open.") }
        let output: HostCLI.Output
        do {
            output = try await call(
                ["thread", "tell", thread, "--message-file", "-", "--mode", "queue", "--json"] + images.flatMap { ["--image", $0] },
                subcommand: "thread tell", input: Data(text.utf8))
        } catch HostCLI.Failure.couldNotStart {
            return .refused("bb could not start.")
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

    private func thread(at location: AgentHostLocation) -> String? {
        guard location.host == Self.kind.id, location.instance == dataDirectory, BBThreads.isThreadId(location.native) else { return nil }
        return location.native
    }

    private func call(_ arguments: [String], subcommand: String, input: Data? = nil) async throws -> HostCLI.Output {
        try await run([cli] + arguments, subcommand, input, environment)
    }

    private static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app).first
    }

    private static func bringForward() {
        guard let running = runningApp else { return }
        _ = AppActivation.bringForward(pid: running.processIdentifier)
    }
}
