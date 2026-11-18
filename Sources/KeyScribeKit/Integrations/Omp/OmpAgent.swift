import Foundation

extension AgentKind {
    public static let omp = AgentKind(
        id: "omp", displayName: "omp", connectorName: "omp connector", resumeCommand: "omp --resume")
}

extension AgentProcesses.Rule {
    public static let omp = AgentProcesses.Rule(
        agent: AgentKind.omp.id, command: "omp", packages: ["/@oh-my-pi/pi-coding-agent/"], anyVersionName: false,
        setupVariable: "PI_CODING_AGENT_DIR", defaultSetup: "~/.omp/agent", needsTerminal: true,
        profileFlags: ["--profile"], profileVariables: ["OMP_PROFILE", "PI_PROFILE"])
}

public enum OmpCLI {
    public static let minimumVersion = [18, 22, 2]

    public static func version(in output: String) -> [Int]? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let word: Substring
            if text.hasPrefix("omp/") {
                word = text.dropFirst(4)
            } else if text.hasPrefix("omp v") {
                word = text.dropFirst(5)
            } else {
                word = text[...]
            }
            let core = word.prefix { $0.isNumber || $0 == "." }
            guard !core.isEmpty, core.endIndex == word.endIndex || word[core.endIndex] == "-" else { continue }
            let parts = core.split(separator: ".").map { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { continue }
            return parts.compactMap { $0 }
        }
        return nil
    }

    public static func disabledModules(_ configAnswer: String) -> [String]? {
        guard let data = configAnswer.data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              answer["key"] as? String == "disabledExtensions",
              let names = answer["value"] as? [String]
        else { return nil }
        let prefix = "extension-module:"
        return names.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
