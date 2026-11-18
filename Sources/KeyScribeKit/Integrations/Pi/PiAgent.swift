import Foundation

extension AgentKind {
    public static let pi = AgentKind(
        id: "pi", displayName: "Pi", connectorName: "Pi connector", reloadCommand: "/reload")
}

extension AgentProcesses.Rule {
    public static let pi = AgentProcesses.Rule(
        agent: AgentKind.pi.id, command: "pi", packages: ["/@earendil-works/pi-coding-agent/", "/@mariozechner/pi-coding-agent/"], anyVersionName: false, setupVariable: "PI_CODING_AGENT_DIR",
        defaultSetup: "~/.pi/agent", needsTerminal: true)
}
