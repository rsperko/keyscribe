import Foundation
import KeyScribeKit

struct HerdrPlaceReader: AgentPlaceReading {
    var environment: @Sendable (Int) -> [String: String]? = { pid in
        SystemTerminalFacts.arguments(
            of: pid, keeping: [HerdrPlaces.socketKey, HerdrPlaces.paneKey, HerdrPlaces.executableKey])?.environment
    }
    var serverExecutable: @Sendable () -> String? = {
        SystemTerminalFacts(environmentKeys: []).processes(named: HerdrPlaces.processName)?
            .first { $0.arguments.dropFirst().first == "server" && !$0.executable.isEmpty }?.executable
    }
    var run: @Sendable ([String]) -> (status: Int32, output: String) = { ToolCLI.run($0, timeout: 3) }

    func read(_ queries: [AgentPlaceQuery]) -> [String: AgentPlaceAnswer] {
        var answers: [String: AgentPlaceAnswer] = [:]
        var bySocket: [String: [(query: AgentPlaceQuery, pane: String?)]] = [:]
        var executable: String?
        for query in queries {
            guard let environment = environment(query.pid) else {
                answers[query.id] = .unknown
                continue
            }
            guard let socket = environment[HerdrPlaces.socketKey], !socket.isEmpty else {
                answers[query.id] = .absent
                continue
            }
            executable = executable ?? environment[HerdrPlaces.executableKey].flatMap { $0.isEmpty ? nil : $0 }
            bySocket[socket, default: []].append((query, environment[HerdrPlaces.paneKey]))
        }
        guard !bySocket.isEmpty else { return answers }
        guard let herdr = executable ?? serverExecutable() else {
            for member in bySocket.values.flatMap({ $0 }) { answers[member.query.id] = .unknown }
            return answers
        }
        for (socket, members) in bySocket {
            let commands = HerdrPlaces.listCommands(socket: socket, executable: herdr)
            let panes = run(commands.panes), tabs = run(commands.tabs), workspaces = run(commands.workspaces), agents = run(commands.agents)
            guard panes.status == 0, tabs.status == 0, workspaces.status == 0, agents.status == 0,
                  let listing = HerdrPlaces.listing(
                    panes: panes.output, tabs: tabs.output, workspaces: workspaces.output, agents: agents.output)
            else {
                for member in members { answers[member.query.id] = .unknown }
                continue
            }
            for member in members {
                let association = HerdrPlaces.place(agent: member.query.agent, native: member.query.native, in: listing, socket: socket) {
                    member.pane.map { HerdrPlaces.currentPane(run(HerdrPlaces.currentPaneCommand(socket: socket, pane: $0, executable: herdr))) }
                }
                answers[member.query.id] = switch association {
                case .found(let place): .found(place)
                case .absent: .absent
                case .unresolved: .unknown
                }
            }
        }
        return answers
    }
}
