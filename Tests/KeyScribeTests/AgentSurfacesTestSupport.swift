import Foundation
import KeyScribeKit

extension ResolvedSurfaces {
    static let builtIn = try! AgentSurfaces.builtIn.resolve()
}
