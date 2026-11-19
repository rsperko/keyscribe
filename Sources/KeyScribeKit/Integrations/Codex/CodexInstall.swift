extension AgentProcesses.Rule {
    public static let codex = AgentProcesses.Rule(
        agent: CodexThread.agent, command: CodexInstall.command, packages: ["/@openai/codex/"], anyVersionName: false,
        setupVariable: "CODEX_HOME", defaultSetup: "~/.codex", needsTerminal: true)
}

public enum CodexInstall {
    public static let command = "codex"

    public static func isCommandLine(resolved: String) -> Bool {
        !resolved.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
    }
}
