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
        case nil: String(describing: conflict)
        }
    }

    public static var builtIn: CodingAgentIntegrations {
        CodingAgentIntegrations(surfaces: .builtIn, placeSources: [{ HerdrPlaceReader() }])
    }
}
