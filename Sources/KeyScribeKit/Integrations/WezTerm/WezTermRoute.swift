import Foundation

enum WezTermRoute {
    static let paneKey = "WEZTERM_PANE"
    static let socketKey = "WEZTERM_UNIX_SOCKET"
    static let app = "com.github.wez.wezterm"
    static let name = "WezTerm"

    static let route = KeyedSurfaceRoute(
        name: name, apps: [app], key: paneKey, socket: socketKey, noun: "pane",
        focus: .command { terminal, pane, socket in
            guard let socket, isPaneID(pane) else { return nil }
            let wezterm = cli(terminal, socket: socket)
            let focused = FocusWalk(
                check: wezterm + ["list-clients", "--format", "json"],
                listing: .json(rowsWhere: ["pid": String(terminal.pid)], column: "focused_pane_id"), value: pane, steps: 1)
            return PaneCommand(wezterm + ["activate-pane", "--pane-id", pane], until: focused)
        },
        front: { terminal, socket, facts in
            guard let socket else { return .unknown(.unreported(name)) }
            return front(terminal, socket: socket, facts: facts)
        })

    static func cli(_ terminal: TerminalProcess, socket: String) -> [String] {
        let wezterm = ((terminal.executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent("wezterm")
        return ["/usr/bin/env", "\(socketKey)=\(socket)", wezterm, "cli", "--no-auto-start"]
    }

    private static func isPaneID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private struct Client: Decodable {
        var pid: Int
        var focused_pane_id: Int?
    }

    private struct Pane: Decodable {
        var pane_id: Int
        var tty_name: String?
    }

    private static func front(_ terminal: TerminalProcess, socket: String, facts: TerminalFacts) -> FrontStep {
        let wezterm = cli(terminal, socket: socket)
        guard let clients = decode([Client].self, facts.run(wezterm + ["list-clients", "--format", "json"])) else {
            return .unknown(.unreadable(name))
        }
        let own = clients.filter { $0.pid == terminal.pid }
        guard own.count == 1 else { return own.isEmpty ? .unknown(.unreported(name)) : .unknown(.ambiguous) }
        guard let panes = decode([Pane].self, facts.run(wezterm + ["list", "--format", "json"])) else { return .unknown(.unreadable(name)) }
        guard let pane = own[0].focused_pane_id else { return .unknown(.unreported(name)) }
        let focused = panes.filter { $0.pane_id == pane }
        guard focused.count == 1, let tty = focused[0].tty_name, !tty.isEmpty else { return .unknown(.unreported(name)) }
        return .tty(tty)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ result: (status: Int32, output: String)) -> T? {
        guard result.status == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.output.utf8))
    }
}
