import Foundation
import KeyScribeKit

struct TitleReading: Equatable, Sendable {
    var titles: [Int: String] = [:]
    var unread: Set<Int> = []
}

private struct CarriedFacts: @unchecked Sendable {
    let facts: TerminalFacts
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

struct TerminalTitleReader: Sendable {
    typealias Command = @Sendable (_ argv: [String]) -> (status: Int32, output: String)
    typealias Wait = @Sendable (_ answered: @escaping @Sendable () -> Int) async -> Void

    let surfaces: ResolvedSurfaces
    var facts: @Sendable () -> TerminalFacts
    var script: @Sendable (_ app: String, _ pid: Int, _ body: String) async -> TerminalRead
    var command: Command?
    var wait: Wait

    init(
        surfaces: ResolvedSurfaces, facts: (@Sendable () -> TerminalFacts)? = nil,
        script: @escaping @Sendable (_ app: String, _ pid: Int, _ body: String) async -> TerminalRead = {
            await TerminalScripting.read($0, pid: $1, body: $2, asking: {}, mayAsk: false)
        },
        command: Command? = nil, wait: @escaping Wait = { _ in try? await Task.sleep(for: .seconds(2)) }
    ) {
        self.surfaces = surfaces
        self.facts = facts ?? { CachedTerminalFacts(SystemTerminalFacts(environmentKeys: surfaces.environmentKeys)) }
        self.script = script
        self.command = command ?? (facts == nil ? Self.outputOnly : nil)
        self.wait = wait
    }

    static let outputOnly: Command = { argv in
        let ran = ToolCLI.execute(argv, timeout: 3, includeErrors: false)
        if case .exited(let status) = ran.end { return (status, ran.text) }
        return (-1, "")
    }

    func titles(of pids: [Int]) async -> TitleReading {
        let shared = facts()
        var reads: [Int: TitleRead] = [:]
        for pid in Set(pids) {
            reads[pid] = TerminalTitles.read(agent: pid, facts: shared, routes: surfaces.routes)
        }
        let answers = await answer(Set(reads.values.map(\.source)), facts: shared)
        var reading = TitleReading()
        for (pid, read) in reads {
            guard let answered = answers[read.source] else {
                reading.unread.insert(pid)
                continue
            }
            if let title = surfaces.route(named: read.route)?.title(answer: answered, pane: read.pane) { reading.titles[pid] = title }
        }
        return reading
    }

    private func answer(_ sources: Set<TitleRead.Source>, facts shared: TerminalFacts) async -> [TitleRead.Source: String] {
        guard !sources.isEmpty else { return [:] }
        let carried = CarriedFacts(facts: shared)
        let run = command ?? { carried.facts.run($0) }
        let script = script
        let (stream, results) = AsyncStream<(TitleRead.Source, String?)?>.makeStream()
        let heard = Heard()
        for source in sources {
            Task.detached {
                let answer: String?
                switch source {
                case .command(let argv):
                    let result = await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: run(argv)) } }
                    answer = result.status == 0 ? result.output : nil
                case .script(let app, let pid, let body):
                    if case .value(let said) = await script(app, pid, body) { answer = said } else { answer = nil }
                }
                results.yield((source, answer))
                heard.add()
            }
        }
        let wait = wait
        let timer = Task.detached {
            await wait { heard.value }
            results.yield(nil)
        }
        defer { timer.cancel() }
        var answers: [TitleRead.Source: String] = [:]
        var received = 0
        for await item in stream {
            guard let (source, answer) = item else { break }
            received += 1
            answers[source] = answer
            if received == sources.count { break }
        }
        results.finish()
        return answers
    }
}
