import Foundation
import KeyScribeKit

enum TitleProbe {
    static func lines(candidates: [AgentCandidate], titles: ([Int]) async -> [Int: String]) async -> [String] {
        guard !candidates.isEmpty else { return ["No running agent processes found."] }
        let read = await titles(candidates.map(\.pid))
        return candidates.flatMap { candidate in
            let folder = URL(fileURLWithPath: candidate.cwd).lastPathComponent
            return [
                "\(candidate.agent)  pid \(candidate.pid)  tty \(candidate.tty ?? "-")  setup \(candidate.setup ?? "-")  folder \(folder)",
                "  title: " + (read[candidate.pid] ?? "none read (no title route for this terminal, Automation not granted, or the read failed)"),
            ]
        }
    }

    static func run(rules: [AgentProcesses.Rule], surfaces: ResolvedSurfaces) async -> [String] {
        let table = AgentProcessTable(surfaces: surfaces)
        let candidates = await Task.detached { rules.flatMap { table.found($0).candidates } }.value
        let reader = TerminalTitleReader(surfaces: surfaces)
        return await lines(candidates: candidates, titles: { await reader.titles(of: $0) })
    }
}
