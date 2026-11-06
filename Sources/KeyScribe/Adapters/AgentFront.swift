import AppKit
import Foundation
import KeyScribeKit

struct FrontApp: Equatable, Sendable {
    var bundle: String
    var pid: Int
    var name: String
}

enum TerminalRead: Equatable, Sendable {
    case value(String)
    case notAllowed
    case failed
}

struct AgentFront: Sendable {
    typealias Read = @Sendable (_ app: String, _ pid: Int, _ body: String, _ asking: @escaping @Sendable () async -> Void) async -> TerminalRead

    var frontmost: @MainActor @Sendable () -> FrontApp? = AgentFront.frontmost
    var read: Read = TerminalScripting.read
    var facts: @Sendable () -> TerminalFacts = { SystemTerminalFacts() }

    func reading(asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> FrontReading {
        switch await confirmed(asking: asking, { _ in () }) {
        case .success(let confirmed): .pane(confirmed.pane)
        case .failure(let why): .unknown(why)
        }
    }

    func check(
        agent pid: Int, environment: [String: String] = [:], asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> FrontCheck {
        let facts = facts
        let result = await confirmed(asking: asking) { reading in
            await Task.detached { reading.check(agent: pid, facts: facts().reporting(environment, for: pid)) }.value
        }
        switch result {
        case .success(let confirmed): return confirmed.value
        case .failure(let why): return .unknown(why)
        }
    }

    private struct Confirmed<Value: Sendable>: Sendable {
        var pane: FrontPane
        var value: Value
    }

    private func confirmed<Value: Sendable>(
        asking: @escaping @MainActor @Sendable (String) -> Void, _ evaluate: @escaping @Sendable (FrontReading) async -> Value
    ) async -> Result<Confirmed<Value>, FrontUnknown> {
        guard let app = await frontmost() else { return .failure(.noTerminal) }
        guard let route = TerminalRoutes.terminal(app.bundle), let script = route.frontScript else { return .failure(.unsupported(app.bundle)) }
        let first = await surface(app, route, script, asking: { await asking(app.name) })
        guard case .pane(let pane) = first else { return .failure(Self.reason(first)) }
        let value = await evaluate(first)
        let second = await surface(app, route, script, asking: {})
        guard case .pane = second else { return .failure(Self.reason(second)) }
        guard second == first, await frontmost() == app else { return .failure(.changed) }
        return .success(Confirmed(pane: pane, value: value))
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
        let facts = facts
        return await Task.detached { FrontPanes.read(answer: answer, from: route, appPid: app.pid, facts: facts()) }.value
    }

    private static func reason(_ reading: FrontReading) -> FrontUnknown {
        if case .unknown(let why) = reading { return why }
        return .changed
    }

    @MainActor
    static func frontmost() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        return FrontApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle)
    }
}
