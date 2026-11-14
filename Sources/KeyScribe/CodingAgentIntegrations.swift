import Foundation
import KeyScribeKit

struct AgentIntegration: Sendable {
    let kind: AgentKind
    let discovery: @MainActor @Sendable (ConnectorSetupRegistry, AgentProcessTable) -> any AgentDiscovery
    let connector: @MainActor @Sendable (_ agentsDir: URL, _ pluginName: String, ConnectorSurfaces) -> any AgentConnector
}

public struct CodingAgentIntegrations: Sendable {
    public typealias PlaceSource = @Sendable () -> any AgentPlaceReading

    public var surfaces: AgentSurfaces
    public var placeSources: [PlaceSource]
    public var hosts: [AgentHostIntegration] = []
    var agents: [AgentIntegration]

    public init(surfaces: AgentSurfaces, placeSources: [PlaceSource]) {
        self.init(surfaces: surfaces, placeSources: placeSources, agents: [.claude, .pi])
    }

    init(surfaces: AgentSurfaces, placeSources: [PlaceSource], agents: [AgentIntegration]) {
        self.surfaces = surfaces
        self.placeSources = placeSources
        self.agents = agents
    }

    @MainActor func discoveries(setups: ConnectorSetupRegistry, processes: AgentProcessTable) -> [any AgentDiscovery] {
        agents.map { $0.discovery(setups, processes) }
    }

    public func resolve() throws -> ResolvedSurfaces {
        try AgentSurfaces.checkKinds(agents.map(\.kind.id) + hosts.map(\.kind.id))
        return try surfaces.resolve()
    }

    @MainActor func connectors(agentsDir: URL, pluginName: String, surfaces: ConnectorSurfaces) -> [any AgentConnector] {
        agents.map { $0.connector(agentsDir, pluginName, surfaces) }
    }

    static func describe(_ conflict: Error) -> String {
        switch conflict as? AgentSurfaces.Conflict {
        case .name(let name): "More than one terminal or multiplexer is named “\(name)”."
        case .app(let app): "More than one terminal claims the app \(app)."
        case .processName(let process): "More than one multiplexer claims the process “\(process)”."
        case .focusDefinition(let id):
            "The focus command “\(id)” is defined more than once, does not start with an absolute program path, or uses a variable its route does not list."
        case .environmentKey(let key): "The environment variable “\(key)” is not a plain variable name."
        case .kind(let id): "More than one coding agent or agent host uses the id “\(id)”, or the id is empty or contains “:”."
        case nil: String(describing: conflict)
        }
    }

    public static var builtIn: CodingAgentIntegrations {
        CodingAgentIntegrations(surfaces: .builtIn, placeSources: [{ HerdrPlaceReader() }])
    }
}
