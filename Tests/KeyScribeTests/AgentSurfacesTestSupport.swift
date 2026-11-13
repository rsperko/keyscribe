import Foundation
import KeyScribeKit

extension ResolvedSurfaces {
    static let builtIn = try! AgentSurfaces.builtIn.resolve()
}

extension ConnectorSurfaces {
    static let builtIn = ConnectorSurfaces(ResolvedSurfaces.builtIn)
}
