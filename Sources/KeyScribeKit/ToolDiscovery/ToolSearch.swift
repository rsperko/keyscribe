import Foundation

public enum ToolSearch {
    public enum Source: String, Equatable, Sendable {
        case chosen, session, shell, app, usual

        public var label: String {
            switch self {
            case .chosen: "chosen by you"
            case .session: "a running conversation"
            case .shell: "login shell PATH"
            case .app: "app PATH"
            case .usual: "usual install folder"
            }
        }
    }

    public struct Place: Equatable, Sendable {
        public var path: String
        public var source: Source

        public init(path: String, source: Source) {
            self.path = path
            self.source = source
        }
    }

    public struct Result: Equatable, Sendable {
        public var tool: Place?
        public var searched: [Place]

        public init(tool: Place?, searched: [Place]) {
            self.tool = tool
            self.searched = searched
        }
    }

    public static func usualFolders(home: String) -> [String] {
        [
            (home as NSString).appendingPathComponent(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
            (home as NSString).appendingPathComponent(".local/share/mise/shims"), (home as NSString).appendingPathComponent(".asdf/shims"),
            (home as NSString).appendingPathComponent(".volta/bin"),
        ]
    }

    public static func places(
        program: String, chosen: String?, sessions: [String], shellPath: [String]?, appPath: [String], home: String, extra: [String]
    ) -> [Place] {
        if let chosen { return [Place(path: chosen, source: .chosen)] }
        let folders: [(String, Source)] = (shellPath ?? []).map { ($0, .shell) } + appPath.map { ($0, .app) }
            + (usualFolders(home: home) + extra).map { ($0, .usual) }
        var seen: Set<String> = []
        let tools = sessions.map { Place(path: $0, source: .session) }
            + folders.filter { $0.0.hasPrefix("/") }.map { Place(path: ($0.0 as NSString).appendingPathComponent(program), source: $0.1) }
        return tools.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }
    }

    public static func find(_ places: [Place], isExecutable: (String) -> Bool) -> Result {
        Result(tool: places.first { isExecutable($0.path) }, searched: places)
    }

    public static func launcher(for path: String, isExecutable: (String) -> Bool) -> String {
        let name = (path as NSString).lastPathComponent
        let plain = AgentProcesses.Rule.unwrapped(name)
        guard plain != name, !plain.isEmpty else { return path }
        let sibling = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(plain)
        return isExecutable(sibling) ? sibling : path
    }

    public static func runPath(tool: String, runtime: String?, shellPath: [String]?, appPath: [String]) -> String {
        let own = [tool, runtime].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent }
        var seen: Set<String> = []
        return (own + (shellPath ?? []) + appPath).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}
