import Foundation

extension AgentKind {
    public static let pi = AgentKind(
        id: "pi", displayName: "Pi", connectorName: "Pi connector", reloadCommand: "/reload",
        connectorFeatures: ["focus", "label", "readiness", "notify", "images", "check"])
}

extension AgentProcesses.Rule {
    public static let pi = AgentProcesses.Rule(
        agent: AgentKind.pi.id, names: ["node", "bun", "pi"], anyVersionName: false, command: "pi", setupVariable: "PI_CODING_AGENT_DIR",
        defaultSetup: "~/.pi/agent", needsTerminal: true)
}
