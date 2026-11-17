import Foundation

public struct DiscoveryReport: Equatable, Sendable {
    public struct Folder: Equatable, Sendable {
        public var path: String
        public var sources: [String]

        public init(path: String, sources: [String]) {
            self.path = path
            self.sources = sources
        }
    }

    public struct Sighting: Equatable, Sendable {
        public var pid: Int
        public var name: String
        public var paths: [String]
        public var matched: Bool
        public var setup: String?

        public init(pid: Int, name: String, paths: [String], matched: Bool, setup: String?) {
            self.pid = pid
            self.name = name
            self.paths = paths
            self.matched = matched
            self.setup = setup
        }
    }

    public var app: String
    public var agent: String
    public var folder: String
    public var search: ToolSearch.Result?
    public var check: ToolCheck?
    public var shell: ShellProbeState
    public var folders: [Folder]
    public var sightings: [Sighting]

    public init(
        app: String, agent: String, folder: String, search: ToolSearch.Result?, check: ToolCheck?, shell: ShellProbeState, folders: [Folder],
        sightings: [Sighting]
    ) {
        self.app = app
        self.agent = agent
        self.folder = folder
        self.search = search
        self.check = check
        self.shell = shell
        self.folders = folders
        self.sightings = sightings
    }

    public var text: String {
        var lines = ["\(app): how it finds \(agent)", "Configuration folder: \(folder)", ""]
        if let search {
            if let tool = search.tool {
                lines.append("Using \(tool.path) (\(tool.source.label))")
                if let check { lines.append("--version: \(check.reportLine)") }
            } else {
                lines.append("Command not found")
            }
            lines.append("Looked in:")
            for place in search.searched {
                lines.append("  \(place.path) (\(place.source.label)): \(place == search.tool ? "found" : "not found")")
            }
            lines.append("")
        }
        switch shell {
        case .notRun: lines.append("Login shell: not run yet")
        case .failed(let reason): lines.append("Login shell: \(reason)")
        case .read(let environment, let at, let failure):
            if let failure { lines.append("Login shell: last refresh failed (\(failure)); using the answer from \(Self.stamp(at))") }
            else { lines.append("Login shell: read \(Self.stamp(at))") }
            for key in environment.values.keys.sorted() { lines.append("  \(key)=\(environment.values[key] ?? "")") }
        }
        lines.append("")
        lines.append("Configuration folders:")
        if folders.isEmpty { lines.append("  none") }
        for folder in folders { lines.append("  \(folder.path) (\(folder.sources.joined(separator: ", ")))") }
        lines.append("")
        lines.append("Processes seen:")
        lines.append("  (paths in Documents, Desktop, Downloads, Pictures, Movies, Music, iCloud Drive, cloud storage folders and other volumes are never looked at, so no permission prompt appears; an agent run from there is not recognized by its process)")
        if sightings.isEmpty { lines.append("  none") }
        for sighting in sightings {
            let what = sighting.matched ? "session" + (sighting.setup.map { ", folder \($0)" } ?? "") : "not a session"
            lines.append("  \(sighting.pid) \(sighting.name): \(what)")
            for path in sighting.paths { lines.append("    \(path)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
