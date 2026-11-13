import Foundation

public struct ScriptedTerminalRoute: TerminalRoute {
    public typealias PlacesParser = @Sendable (_ answer: String, _ ttys: [String], _ surface: String) -> PlaceLayer?

    public let name: String
    public let apps: Set<String>
    public let helperPrefix: String?
    public let front: String
    public let body: String
    public let placeScript: String?
    public let placesFrom: PlacesParser?
    public let environmentKeys: [String] = []
    public var frontScript: String? { front }

    public init(
        name: String, apps: Set<String>, helperPrefix: String? = nil, front: String, body: String,
        placeScript: String? = nil, placesFrom: PlacesParser? = nil
    ) {
        self.name = name
        self.apps = apps
        self.helperPrefix = helperPrefix
        self.front = front
        self.body = body
        self.placeScript = placeScript
        self.placesFrom = placesFrom
    }

    public func bundle(of process: TerminalProcess) -> String? {
        if let app = process.app, apps.contains(app) { return app }
        guard helperPrefix.map(process.name.hasPrefix) == true, apps.count == 1 else { return nil }
        return apps.first
    }

    public func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard let app = bundle(of: process) else { return nil }
        return Opening(open(app: app, pid: process.pid, ttys: TerminalRoutes.ttys(of: inner)))
    }

    public func places(answer: String, ttys: [String]) -> PlaceLayer? {
        placesFrom?(answer, ttys, name)
    }

    public func open(app: String, pid: Int, ttys: [String]) -> [OpenAction] {
        guard !ttys.isEmpty else { return [.activate(app: app, pid: pid)] }
        let wanted = "set wanted to {" + ttys.map(AppleScriptText.literal).joined(separator: ", ") + "}\n"
        return [.select(.script(app: app, pid: pid, body: wanted + body)), .activate(app: app, pid: pid)]
    }
}

public enum AppleScriptText {
    public static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
