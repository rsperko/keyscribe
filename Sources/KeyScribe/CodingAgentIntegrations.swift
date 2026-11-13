import KeyScribeKit

public struct CodingAgentIntegrations: Sendable {
    public typealias PlaceSource = @Sendable () -> any AgentPlaceReading

    public var surfaces: AgentSurfaces
    public var placeSources: [PlaceSource]

    public init(surfaces: AgentSurfaces, placeSources: [PlaceSource]) {
        self.surfaces = surfaces
        self.placeSources = placeSources
    }

    static func describe(_ conflict: Error) -> String {
        switch conflict as? AgentSurfaces.Conflict {
        case .name(let name): "More than one terminal or multiplexer is named “\(name)”."
        case .app(let app): "More than one terminal claims the app \(app)."
        case .processName(let process): "More than one multiplexer claims the process “\(process)”."
        case .focusDefinition(let id):
            "The focus command “\(id)” is defined more than once, does not start with an absolute program path, or uses a variable its route does not list."
        case .environmentKey(let key): "The environment variable “\(key)” is not a plain variable name."
        case nil: String(describing: conflict)
        }
    }

    public static var builtIn: CodingAgentIntegrations {
        CodingAgentIntegrations(surfaces: .builtIn, placeSources: [{ HerdrPlaceReader() }])
    }
}
