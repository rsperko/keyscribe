import Foundation

extension AgentProcesses.Rule {
    public static let opencode = AgentProcesses.Rule(
        agent: OpencodeSession.agent, command: OpencodeInstall.command, packages: ["/opencode-ai/", "/opencode-v2/"], anyVersionName: false,
        setupVariable: "OPENCODE_CONFIG_DIR", defaultSetup: "~/.config/opencode", needsTerminal: true)
}

public enum OpencodeInstall {
    public static let command = "opencode"
    public static let firstSupportedMajor = 2

    public static func supports(version output: String) -> Bool {
        let words = output.split(whereSeparator: { $0.isWhitespace })
        guard let version = words.last(where: { $0.first?.isNumber == true || ($0.first == "v" && $0.dropFirst().first?.isNumber == true) }),
              let major = Int(version.drop { $0 == "v" }.prefix { $0.isNumber })
        else { return false }
        return major >= firstSupportedMajor
    }

    public static func isService(arguments: [String]) -> Bool {
        guard let first = arguments.first, (first as NSString).lastPathComponent == command else { return false }
        return arguments.dropFirst().first == "serve" && arguments.contains("--service")
    }

    public static func showsWindowTitle(settings: Data?) -> Bool {
        guard let settings else { return true }
        guard let object = OpencodeJSON.object(settings) else { return false }
        return ((object["terminal"] as? [String: Any])?["title"] as? Bool) ?? true
    }

    public static func tuiSettings(home: String, environment: [String: String]) -> URL {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        return URL(fileURLWithPath: config).appendingPathComponent("opencode/cli.json")
    }
}
