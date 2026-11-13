import Foundation

public enum RouteProbe {
    public static let skipped = "not read: terminal place scripts and place sources with their own reader"

    public enum Option: Equatable, Sendable {
        case absent, missing
        case value(String)
    }

    public static func option(_ flag: String, in arguments: [String]) -> Option {
        guard let index = arguments.firstIndex(of: flag) else { return .absent }
        guard index + 1 < arguments.count else { return .missing }
        let value = arguments[index + 1]
        return value.isEmpty || value.hasPrefix("--") ? .missing : .value(value)
    }

    public static func pid(_ argument: String) -> Int? {
        guard let pid = Int32(argument), pid > 0 else { return nil }
        return Int(pid)
    }

    public static func report(agent pid: Int, facts: TerminalFacts, surfaces: ResolvedSurfaces) -> [String]? {
        let facts = CachedTerminalFacts(facts)
        let chain = TerminalRoutes.ancestors(of: pid, facts: facts)
        guard !chain.isEmpty else { return nil }
        var lines = ["chain=" + chain.map(describe).joined(separator: " < ")]
        let plan = TerminalRoutes.plan(agent: pid, facts: facts, routes: surfaces.routes)
        lines += plan.isEmpty ? ["open=none"] : plan.map { "open " + describe($0) }
        if let walk = TerminalPlaces.walk(agent: pid, facts: facts, routes: surfaces.routes) {
            lines.append("places surface=\(walk.surface ?? "none")")
            for layer in walk.layers {
                let labels = layer.labels.map { "\($0.level):\($0.text)" }.joined(separator: ",")
                lines.append("place labels=\(labels.isEmpty ? "none" : labels) containers=\(layer.containers.joined(separator: ","))"
                    + (layer.unresolved ? " unresolved" : ""))
            }
            if let host = walk.host {
                lines.append("place host=\(host.route) app=\(host.app) pid=\(host.pid) ttys=\(host.ttys.joined(separator: ","))")
            }
        }
        lines.append(skipped)
        return lines
    }

    private static func describe(_ process: TerminalProcess) -> String {
        "\(process.pid):\(process.name.isEmpty ? "?" : process.name)" + (process.tty.map { "@\($0)" } ?? "") + (process.app.map { "[\($0)]" } ?? "")
    }

    private static func describe(_ action: OpenAction) -> String {
        switch action {
        case .layer(let layer):
            guard !layer.commands.isEmpty else { return "layer \(layer.multiplexer) unresolved" }
            let commands = layer.commands.map { command in
                command.arguments.joined(separator: " ")
                    + (command.until.map { " until \($0.column)=\($0.value) within \($0.steps)" } ?? "")
            }
            return "layer \(layer.multiplexer)\(layer.confirmed ? "" : " unconfirmed"): " + commands.joined(separator: " ; ")
        case .select(.script(let app, let pid, _)): return "select script app=\(app) pid=\(pid)"
        case .select(.url(let url)): return "select url=\(url)"
        case .select(.connector(let definition)): return "select connector definition=\(definition)"
        case .activate(let app, let pid): return "activate app=\(app) pid=\(pid)"
        case .unsupported(let app, let pid): return "unsupported app=\(app) pid=\(pid)"
        }
    }
}
