import Foundation
import KeyScribeKit

struct HostPane: Equatable, Sendable {
    var pid: Int
    var title: String
}

struct HostPanes: Equatable, Sendable {
    var panes: [HostPane]
    var unread: Set<Int> = []
}

enum HostPaneReader {
    typealias Read = @Sendable (_ keep: @escaping @Sendable (AgentCandidate) -> Bool) async -> HostPanes

    static func reading(_ rule: AgentProcesses.Rule, surfaces: ResolvedSurfaces) -> Read {
        let table = AgentProcessTable(surfaces: surfaces)
        let titles = TerminalTitleReader(surfaces: surfaces)
        return { keep in
            let found = await Task.detached { table.found(rule).candidates }.value.filter(keep)
            guard !found.isEmpty else { return HostPanes(panes: []) }
            let read = await titles.titles(of: found.map(\.pid))
            return HostPanes(panes: found.compactMap { candidate in read.titles[candidate.pid].map { HostPane(pid: candidate.pid, title: $0) } }, unread: read.unread)
        }
    }
}
