import Foundation
@testable import KeyScribeKit

extension ResolvedSurfaces {
    static let builtIn = try! AgentSurfaces.builtIn.resolve()
}

extension TerminalRoutes {
    static func plan(agent pid: Int, facts: TerminalFacts) -> [OpenAction] {
        plan(agent: pid, facts: facts, routes: ResolvedSurfaces.builtIn.routes)
    }
}

extension TerminalPlaces {
    static func walk(agent pid: Int, facts: TerminalFacts) -> TerminalPlaceWalk? {
        walk(agent: pid, facts: facts, routes: ResolvedSurfaces.builtIn.routes)
    }
}

extension FrontPanes {
    static func read(answer: String, from terminal: any TerminalRoute, appPid: Int, facts: TerminalFacts) -> FrontReading {
        read(
            answer: answer, from: terminal, app: terminal.apps.sorted()[0], appPid: appPid, facts: facts,
            panes: ResolvedSurfaces.builtIn.multiplexers)
    }

    static func read(_ front: TerminalFront, facts: TerminalFacts) -> FrontReading {
        read(front, facts: facts, panes: ResolvedSurfaces.builtIn.multiplexers)
    }
}

extension FrontReading {
    func check(agent pid: Int, facts: TerminalFacts) -> FrontCheck {
        check(agent: pid, facts: facts, surfaces: .builtIn)
    }
}

extension Route {
    func check(agent pid: Int, view: FrontView, facts: TerminalFacts) -> FrontCheck {
        check(agent: pid, view: view, facts: facts, multiplexerProcesses: ResolvedSurfaces.builtIn.multiplexerProcesses)
    }
}

extension TerminalRoute {
    var app: String { apps.sorted()[0] }
}

extension ScriptedTerminalRoute {
    func open(pid: Int, ttys: [String]) -> [OpenAction] { open(app: app, pid: pid, ttys: ttys) }
}

extension TerminalFacts {
    func reporting(_ environment: [String: String], for pid: Int) -> TerminalFacts {
        reporting(environment, for: pid, keeping: ResolvedSurfaces.builtIn.environmentKeys)
    }
}
