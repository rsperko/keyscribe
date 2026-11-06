import Foundation

extension AgentKind {
    public static let pi = AgentKind(
        id: "pi", displayName: "Pi", connectorName: "Pi connector", reloadCommand: "/reload",
        connectorFeatures: ["focus", "label", "readiness"])
}
