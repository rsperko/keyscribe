import Foundation

public struct TitleRead: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case command([String])
        case script(app: String, pid: Int, body: String)
    }

    public var route: String
    public var source: Source
    public var pane: [String]

    public init(route: String, source: Source, pane: [String]) {
        self.route = route
        self.source = source
        self.pane = pane
    }
}

public enum TerminalTitles {
    public static func read(agent pid: Int, facts: TerminalFacts, routes: [any Route]) -> TitleRead? {
        let chain = TerminalRoutes.ancestors(of: pid, facts: facts)
        for (index, process) in chain.enumerated() {
            for route in routes where hosts(route, process) {
                return route.titleRead(process, inner: chain[..<index], facts: facts)
            }
        }
        return nil
    }

    static func hosts(_ route: any Route, _ process: TerminalProcess) -> Bool {
        if let terminal = route as? any TerminalRoute { return terminal.claims(process) }
        if let pane = route as? any PaneRoute { return process.name == pane.processName && process.tty == nil }
        return false
    }

    public static func shown(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func rows(_ answer: String, fields: Int) -> [[String]] {
        answer.split(separator: "\n").map {
            $0.split(separator: "\t", maxSplits: fields - 1, omittingEmptySubsequences: false).map(String.init)
        }.filter { $0.count == fields }
    }

    public static func keyed(_ answer: String, among pane: [String]) -> String? {
        let titles = Dictionary(rows(answer, fields: 2).map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        return pane.lazy.compactMap { titles[$0] }.first.flatMap(shown)
    }
}
