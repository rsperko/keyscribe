import Foundation
import KeyScribeKit

struct TerminalTitleReader: Sendable {
    let surfaces: ResolvedSurfaces
    var facts: @Sendable () -> TerminalFacts
    var script: @Sendable (_ app: String, _ pid: Int, _ body: String) async -> TerminalRead

    init(
        surfaces: ResolvedSurfaces, facts: (@Sendable () -> TerminalFacts)? = nil,
        script: @escaping @Sendable (_ app: String, _ pid: Int, _ body: String) async -> TerminalRead = {
            await TerminalScripting.read($0, pid: $1, body: $2, asking: {}, mayAsk: false)
        }
    ) {
        self.surfaces = surfaces
        self.facts = facts ?? { CachedTerminalFacts(SystemTerminalFacts(environmentKeys: surfaces.environmentKeys)) }
        self.script = script
    }

    func titles(of pids: [Int]) async -> [Int: String] {
        let shared = facts()
        var reads: [Int: TitleRead] = [:]
        for pid in Set(pids) {
            reads[pid] = TerminalTitles.read(agent: pid, facts: shared, routes: surfaces.routes)
        }
        var answers: [TitleRead.Source: String] = [:]
        for source in Set(reads.values.map(\.source)) {
            switch source {
            case .command(let argv):
                let result = shared.run(argv)
                if result.status == 0 { answers[source] = result.output }
            case .script(let app, let pid, let body):
                if case .value(let answer) = await script(app, pid, body) { answers[source] = answer }
            }
        }
        return reads.compactMapValues { read in
            answers[read.source].flatMap { surfaces.route(named: read.route)?.title(answer: $0, pane: read.pane) }
        }
    }
}
