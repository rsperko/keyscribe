import Foundation

public struct ScriptedTerminalRoute: TerminalRoute {
    public let name: String
    public let app: String
    let helperPrefix: String?
    let front: String
    let body: String
    public var placeScript: String?
    var placesFrom: (@Sendable (_ answer: String, _ ttys: [String], _ surface: String) -> PlaceLayer?)?
    public let environmentKeys: [String] = []
    public var frontScript: String? { front }

    func claims(_ process: TerminalProcess) -> Bool {
        process.app == app || helperPrefix.map(process.name.hasPrefix) == true
    }

    public func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard claims(process) else { return nil }
        return Opening(open(pid: process.pid, ttys: TerminalRoutes.ttys(of: inner)))
    }

    public func places(answer: String, ttys: [String]) -> PlaceLayer? {
        placesFrom?(answer, ttys, name)
    }

    public static func route(named name: String) -> ScriptedTerminalRoute? { all.first { $0.name == name } }

    public func open(pid: Int, ttys: [String]) -> [OpenAction] {
        guard !ttys.isEmpty else { return [.activate(app: app, pid: pid)] }
        let wanted = "set wanted to {" + ttys.map(AppleScriptText.literal).joined(separator: ", ") + "}\n"
        return [.select(.script(app: app, pid: pid, body: wanted + body)), .activate(app: app, pid: pid)]
    }

    public static let all = [ghostty, terminal, iterm]
}

public enum AppleScriptText {
    public static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
