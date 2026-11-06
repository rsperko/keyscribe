import Foundation

struct ZellijRoute: PaneRoute {
    static let sessionKey = "ZELLIJ_SESSION_NAME"
    static let paneKey = "ZELLIJ_PANE_ID"
    static let name = "Zellij"
    let environmentKeys = [sessionKey, paneKey]

    func layer(server: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> (layer: PaneLayer, client: Int?)? {
        guard server.name == "zellij", let flag = server.arguments.firstIndex(of: "--server"), flag + 1 < server.arguments.count
        else { return nil }
        let socket = server.arguments[flag + 1]
        let clients = Self.clients(of: socket, server: server.pid, facts: facts)
        let client = TerminalRoutes.steadiest(clients, preferring: nil)
        guard let pane = TerminalRoutes.nearest(Self.paneKey, in: inner),
              let id = pane.environment[Self.paneKey].flatMap({ Int($0.replacingOccurrences(of: "terminal_", with: "")) })
        else { return (.unresolved(Self.name), client) }
        let session = pane.environment[Self.sessionKey] ?? (socket as NSString).lastPathComponent
        let action = [server.executable, "--session", session, "action"]
        guard let tab = Self.tab(of: id, in: facts.run(action + ["list-panes", "-t", "-j"])) else { return (.unresolved(Self.name), client) }
        let commands = [
            PaneCommand(action + ["go-to-tab-by-id", String(tab)]),
            PaneCommand(action + ["focus-pane-id", "terminal_\(id)"], alreadyDone: "is already focused"),
        ]
        return (PaneLayer(Self.name, commands: commands, confirmed: clients.count <= 1), client)
    }

    private struct Pane: Decodable {
        var id: Int
        var is_plugin: Bool
        var tab_id: Int?
    }

    static func tab(of id: Int, in result: (status: Int32, output: String)) -> Int? {
        guard result.status == 0, let panes = try? JSONDecoder().decode([Pane].self, from: Data(result.output.utf8)) else { return nil }
        return panes.first { !$0.is_plugin && $0.id == id }?.tab_id
    }

    static func clients(of socket: String, server: Int, facts: TerminalFacts) -> [Int] {
        let (status, output) = facts.run(["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"])
        guard status == 0 || !output.isEmpty else { return [] }
        var accepted: Set<String> = []
        var peers: [(pid: Int, peer: String)] = []
        var pid = 0
        var device = ""
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int(value) ?? 0
            case "f": device = ""
            case "d": device = value
            case "n" where pid == server: if value == socket { accepted.insert(device) }
            case "n": if value.hasPrefix("->") { peers.append((pid, String(value.dropFirst(2)))) }
            default: break
            }
        }
        return Array(Set(peers.filter { accepted.contains($0.peer) }.map(\.pid))).sorted()
    }
}
