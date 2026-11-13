import AppKit
import Foundation
import KeyScribeKit

struct FrontApp: Equatable, Sendable {
    var bundle: String
    var pid: Int
    var name: String
    var window: String? = nil
}

enum TerminalRead: Equatable, Sendable {
    case value(String)
    case notAllowed
    case failed
}

struct AgentFrontCandidate: Equatable, Sendable {
    var id: String
    var pid: Int
    var environment: [String: String] = [:]
}

struct FrontSession: Equatable, Sendable {
    var id: String
    var app: FrontApp
}

protocol AgentFronting: Sendable {
    func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession?
}

struct AgentFront: AgentFronting, Sendable {
    typealias Read = @Sendable (_ app: String, _ pid: Int, _ body: String, _ asking: @escaping @Sendable () async -> Void) async -> TerminalRead

    static func withoutAsking(_ surfaces: ResolvedSurfaces) -> AgentFront {
        AgentFront(
            surfaces: surfaces, frontmost: { AgentFront.frontmost(withWindow: false) },
            read: { app, pid, body, _ in await TerminalScripting.read(app, pid: pid, body: body, asking: {}, mayAsk: false) },
            confirming: false)
    }

    static func confirmingWithoutAsking(_ surfaces: ResolvedSurfaces) -> AgentFront {
        AgentFront(
            surfaces: surfaces,
            read: { app, pid, body, _ in await TerminalScripting.read(app, pid: pid, body: body, asking: {}, mayAsk: false) })
    }

    let surfaces: ResolvedSurfaces
    var frontmost: @MainActor @Sendable () -> FrontApp?
    var read: Read
    var facts: @Sendable () -> TerminalFacts
    var confirming: Bool

    init(
        surfaces: ResolvedSurfaces, frontmost: @escaping @MainActor @Sendable () -> FrontApp? = { AgentFront.frontmost() },
        read: @escaping Read = { await TerminalScripting.read($0, pid: $1, body: $2, asking: $3) },
        facts: (@Sendable () -> TerminalFacts)? = nil, confirming: Bool = true
    ) {
        self.surfaces = surfaces
        self.frontmost = frontmost
        self.read = read
        self.facts = facts ?? { SystemTerminalFacts(environmentKeys: surfaces.environmentKeys) }
        self.confirming = confirming
    }

    func reading(asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> FrontReading {
        switch await confirmed(asking: asking, { _ in () }) {
        case .success(let confirmed): .pane(confirmed.pane)
        case .failure(let why): .unknown(why)
        }
    }

    func check(
        agent pid: Int, environment: [String: String] = [:], asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> FrontCheck {
        let (facts, surfaces) = (facts, surfaces)
        let result = await confirmed(asking: asking) { reading in
            await Task.detached {
                reading.check(agent: pid, facts: facts().reporting(environment, for: pid, keeping: surfaces.environmentKeys), surfaces: surfaces)
            }.value
        }
        switch result {
        case .success(let confirmed): return confirmed.value
        case .failure(let why): return .unknown(why)
        }
    }

    func shown(
        among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> FrontSession? {
        let (facts, surfaces) = (facts, surfaces)
        let result = await confirmed(asking: asking) { reading in
            await Task.detached {
                agents.filter {
                    reading.check(
                        agent: $0.pid, facts: facts().reporting($0.environment, for: $0.pid, keeping: surfaces.environmentKeys),
                        surfaces: surfaces) == .shown
                }.map(\.id)
            }.value
        }
        guard case .success(let confirmed) = result, confirmed.value.count == 1 else { return nil }
        return FrontSession(id: confirmed.value[0], app: confirmed.app)
    }

    private struct Confirmed<Value: Sendable>: Sendable {
        var app: FrontApp
        var pane: FrontPane
        var value: Value
    }

    private func confirmed<Value: Sendable>(
        asking: @escaping @MainActor @Sendable (String) -> Void, _ evaluate: @escaping @Sendable (FrontReading) async -> Value
    ) async -> Result<Confirmed<Value>, FrontUnknown> {
        guard let app = await frontmost() else { return .failure(.noTerminal) }
        guard let route = surfaces.terminal(app.bundle), let script = route.frontScript else { return .failure(.unsupported(app.bundle)) }
        let first = await surface(app, route, script, asking: { await asking(app.name) })
        guard case .pane(let pane) = first else { return .failure(Self.reason(first)) }
        let value = await evaluate(first)
        guard confirming else { return .success(Confirmed(app: app, pane: pane, value: value)) }
        let second = await surface(app, route, script, asking: {})
        guard case .pane = second else { return .failure(Self.reason(second)) }
        guard second == first, await frontmost() == app else { return .failure(.changed) }
        return .success(Confirmed(app: app, pane: pane, value: value))
    }

    private func surface(
        _ app: FrontApp, _ route: any TerminalRoute, _ script: String, asking: @escaping @Sendable () async -> Void
    ) async -> FrontReading {
        let answer: String
        switch await read(app.bundle, app.pid, script, asking) {
        case .value(let value): answer = value
        case .notAllowed: return .unknown(.notAllowed(app.bundle))
        case .failed: return .unknown(.unreadable(app.bundle))
        }
        let (facts, panes) = (facts, surfaces.multiplexers)
        return await Task.detached { FrontPanes.read(answer: answer, from: route, app: app.bundle, appPid: app.pid, facts: facts(), panes: panes) }.value
    }

    private static func reason(_ reading: FrontReading) -> FrontUnknown {
        if case .unknown(let why) = reading { return why }
        return .changed
    }

    @MainActor
    static func frontmost(withWindow: Bool = true) -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        let window = withWindow ? ContextProbe.focusedState(pid: app.processIdentifier).windowId : nil
        return FrontApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle, window: window)
    }
}
