import AppKit
import Foundation
import KeyScribeKit

enum AgentFocusResult: Equatable, Sendable {
    case exact
    case requested(String)
    case app(String)
    case pane(app: String, multiplexer: String, uncertain: Bool)
    case unsupported(String)
    case connectorOutdated(String)
    case notAllowed(String)
    case none

    func hudState(handle: String, detail: String, agent: AgentKind? = nil) -> HUDState {
        let recipient = "Your recipient is \(handle)"
        return switch self {
        case .exact: .commandDone(summary: "Opened \(handle)", detail: detail)
        case .requested(let app): .commandDone(summary: "Asked \(app) to show \(handle)", detail: detail)
        case .app(let app): .advisory(message: "Brought \(app) forward. Couldn\u{2019}t find \(handle)\u{2019}s tab. \(recipient)")
        case .pane(let app, let multiplexer, let uncertain):
            .advisory(message: "Brought \(app) forward. Couldn\u{2019}t \(uncertain ? "confirm" : "select") \(handle)\u{2019}s \(multiplexer) pane. \(recipient)")
        case .unsupported(let app):
            .advisory(message: "Brought \(app) forward. Select \(handle)\u{2019}s terminal yourself. \(recipient)")
        case .notAllowed(let app):
            .error(
                message: "Brought \(app) forward. Couldn\u{2019}t select \(handle)\u{2019}s tab without access to \(app). \(recipient)",
                action: .openAutomationSettings)
        case .connectorOutdated(let app):
            .advisory(message: "Brought \(app) forward. Update the \(agent?.connectorName ?? "connector") in Settings, then \(Self.reload(agent, in: handle)) to open its tab. \(recipient)")
        case .none: .advisory(message: "Nothing showing \(handle) could be brought forward. \(recipient)")
        }
    }

    func historySummary(handle: String, agent: AgentKind? = nil) -> String {
        let forward = { (app: String, rest: String) in "Brought \(app) forward; \(rest)" }
        return switch self {
        case .exact: "Opened \(handle)"
        case .requested(let app): "Asked \(app) to show \(handle)"
        case .app(let app): forward(app, "\(handle)\u{2019}s tab not found")
        case .pane(let app, let multiplexer, let uncertain):
            forward(app, "\(handle)\u{2019}s \(multiplexer) pane not \(uncertain ? "confirmed" : "selected")")
        case .unsupported(let app): forward(app, "\(handle)\u{2019}s terminal not selected")
        case .notAllowed(let app): forward(app, "no access to select \(handle)\u{2019}s tab")
        case .connectorOutdated(let app): forward(app, "the \(agent?.connectorName ?? "connector") needs an update")
        case .none: "Nothing showing \(handle) was brought forward"
        }
    }

    private static func reload(_ agent: AgentKind?, in handle: String) -> String {
        agent?.reloadCommand.map { "run \($0) in \(handle)" } ?? "restart \(handle)"
    }
}

enum TerminalSelection: Equatable, Sendable {
    case selected, notFound, notAllowed, unsupported, outdated
}

protocol AgentTerminalFocusing: Sendable {
    func focus(
        session: String, pid: Int, environment: [String: String], stillWanted: @escaping @MainActor @Sendable () -> Bool,
        asking: @escaping @MainActor @Sendable (String) -> Void
    ) async -> AgentFocusResult
}

extension AgentTerminalFocusing {
    func focus(
        session: String, pid: Int, environment: [String: String], asking: @escaping @MainActor @Sendable (String) -> Void
    ) async -> AgentFocusResult {
        await focus(session: session, pid: pid, environment: environment, stillWanted: { true }, asking: asking)
    }
}

struct AgentTerminalFocus: AgentTerminalFocusing {
    typealias Script = @Sendable (
        _ app: String, _ pid: Int, _ body: String, _ asking: @escaping @Sendable () async -> Void,
        _ wanted: @escaping @Sendable () async -> Bool
    ) async -> TerminalSelection

    var plan: @Sendable (Int, [String: String]) -> [OpenAction]
    var run: @Sendable ([String]) -> (Int32, String) = { ToolCLI.run($0, timeout: 3) }
    var script: Script = TerminalScripting.select
    var openURL: @MainActor @Sendable (String) -> Bool = { URL(string: $0).map(NSWorkspace.shared.open) ?? false }
    var connector: @MainActor @Sendable (_ session: String) async -> TerminalSelection = { _ in .unsupported }
    var running: @MainActor @Sendable (_ app: String, _ near: Int) -> (pid: Int, name: String)? = AgentTerminalFocus.running
    var activate: @MainActor @Sendable (Int) -> String? = AppActivation.bringForwardApp(pid:)

    static func plan(
        _ surfaces: ResolvedSurfaces,
        facts: (@Sendable () -> TerminalFacts)? = nil
    ) -> @Sendable (Int, [String: String]) -> [OpenAction] {
        let facts = facts ?? { SystemTerminalFacts(environmentKeys: surfaces.environmentKeys) }
        return { pid, environment in
            let facts = facts()
            return TerminalRoutes.plan(
                agent: pid, facts: facts.reporting(environment, for: pid, keeping: surfaces.environmentKeys), routes: surfaces.routes)
        }
    }

    private enum Terminal {
        case selected, requested, notFound, notAllowed, unsupported, outdated
    }

    func focus(
        session: String, pid: Int, environment: [String: String], stillWanted: @escaping @MainActor @Sendable () -> Bool,
        asking: @escaping @MainActor @Sendable (String) -> Void
    ) async -> AgentFocusResult {
        let (plan, run) = (plan, run)
        let wanted: @Sendable () async -> Bool = {
            guard !Task.isCancelled else { return false }
            return await stillWanted()
        }
        let actions = await Task.detached { plan(pid, environment) }.value
        var unselectedLayer: (multiplexer: String, uncertain: Bool)?
        var terminal = Terminal.unsupported
        var shown: String?
        for action in actions {
            guard await wanted() else { return .none }
            switch action {
            case .layer(let layer):
                var failed = false
                for command in layer.commands {
                    guard await wanted() else { return .none }
                    let succeeded = if let walk = command.until {
                        await Self.step(command.arguments, until: walk, run: run, wanted: wanted)
                    } else {
                        await Task.detached { command.accepting.contains(run(command.arguments).0) }.value
                    }
                    guard succeeded else {
                        failed = true
                        break
                    }
                }
                if unselectedLayer == nil, failed || !layer.confirmed {
                    unselectedLayer = (layer.multiplexer, uncertain: !failed && !layer.commands.isEmpty)
                }
            case .select(.script(let app, let near, let body)):
                guard let (appPid, name) = await running(app, near), await wanted() else { return .none }
                switch await script(app, appPid, body, { await asking(name) }, wanted) {
                case .selected: terminal = .selected
                case .notFound: terminal = .notFound
                case .notAllowed: terminal = .notAllowed
                case .unsupported, .outdated: terminal = .unsupported
                }
            case .select(.connector):
                switch await connector(session) {
                case .selected: terminal = .selected
                case .notFound, .notAllowed: terminal = .notFound
                case .unsupported: terminal = .unsupported
                case .outdated: terminal = .outdated
                }
            case .select(.url(let url)):
                terminal = await openURL(url) ? .requested : .notFound
            case .activate(let app, let near), .unsupported(let app, let near):
                guard let (appPid, _) = await running(app, near), await wanted(), let name = await activate(appPid) else { return .none }
                shown = name
            }
        }
        guard let shown else { return .none }
        if let layer = unselectedLayer, terminal == .selected || terminal == .requested {
            return .pane(app: shown, multiplexer: layer.multiplexer, uncertain: layer.uncertain)
        }
        switch terminal {
        case .selected: return .exact
        case .requested: return .requested(shown)
        case .notFound: return .app(shown)
        case .notAllowed: return .notAllowed(shown)
        case .unsupported: return .unsupported(shown)
        case .outdated: return .connectorOutdated(shown)
        }
    }

    private static func step(
        _ arguments: [String], until walk: FocusWalk, run: @escaping @Sendable ([String]) -> (Int32, String),
        wanted: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for taken in 0...max(walk.steps, 0) {
            guard await wanted() else { return false }
            let check = await Task.detached { run(walk.check) }.value
            guard let reached = walk.reached(check) else { return false }
            if reached { return true }
            guard taken < walk.steps, await wanted() else { return false }
            guard await Task.detached(operation: { run(arguments).0 == 0 }).value else { return false }
        }
        return false
    }

    @MainActor
    static func running(_ app: String, near pid: Int) -> (pid: Int, name: String)? {
        let near = NSRunningApplication(processIdentifier: pid_t(pid))
        let process = near.flatMap { $0.bundleIdentifier == app && !$0.isTerminated ? $0 : nil }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: app).first { !$0.isTerminated }
        guard let process else { return nil }
        return (Int(process.processIdentifier), process.localizedName ?? app)
    }
}

enum TerminalScripting {
    static let replyTimeout = 3
    private static let queue = DeadlineQueue(label: "com.keyscribe.agents.terminal-scripts", backlog: TimeInterval(replyTimeout))
    private static let passiveQueue = DeadlineQueue(label: "com.keyscribe.agents.passive-terminal-reads", backlog: TimeInterval(replyTimeout))

    static func select(
        _ app: String, pid: Int, body: String, asking: @escaping @Sendable () async -> Void,
        wanted: @escaping @Sendable () async -> Bool = { true }
    ) async -> TerminalSelection {
        let consent = await AutomationConsent.settle([app], willAsk: { _ in await asking() })
        guard consent.readable == [app] else { return consent.refused.isEmpty ? .notFound : .notAllowed }
        guard await wanted() else { return .notFound }
        let source = PinnedAppleScript.pinned(to: app, timeout: replyTimeout, body)
        let gate = StopGate.watching(wanted)
        let answer = await queue.run(within: TimeInterval(replyTimeout)) { isCurrent -> TerminalSelection in
            switch PinnedAppleScript.run(source, pid: pid_t(pid), isCurrent: { isCurrent() && gate.isOpen }) {
            case .value(let result): result.booleanValue ? .selected : .notFound
            case .refused: .notAllowed
            case .gone, .failed: .notFound
            }
        }
        let open = gate.isOpen
        await gate.finish()
        guard case .finished(let selection) = answer, open else { return .notFound }
        return selection
    }

    static func read(
        _ app: String, pid: Int, body: String, asking: @escaping @Sendable () async -> Void, mayAsk: Bool = true
    ) async -> TerminalRead {
        let consent = await AutomationConsent.settle([app], mayAsk: mayAsk, willAsk: { _ in await asking() })
        guard consent.readable == [app] else { return consent.refused.isEmpty ? .failed : .notAllowed }
        let source = PinnedAppleScript.pinned(to: app, timeout: replyTimeout, body)
        let answer = await (mayAsk ? queue : passiveQueue).run(within: TimeInterval(replyTimeout)) { isCurrent -> TerminalRead in
            switch PinnedAppleScript.run(source, pid: pid_t(pid), prompting: mayAsk, isCurrent: isCurrent) {
            case .value(let result): result.stringValue.map(TerminalRead.value) ?? .failed
            case .refused: .notAllowed
            case .gone, .failed: .failed
            }
        }
        guard case .finished(let read) = answer else { return .failed }
        return read
    }
}
