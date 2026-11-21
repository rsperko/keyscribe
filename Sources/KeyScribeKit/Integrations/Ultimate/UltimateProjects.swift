import Foundation

public enum UltimateProjects {
    public static let projectsFolder = "projects"
    public static let lockFile = "ultimate.lock"
    public static let projectFile = "project.json"
    public static let conversationsFile = "conversations.json"
    public static let settingsFile = "settings.json"
    public static let extensionsFolder = "extensions"
    public static let setupFolderName = ".ultimate"

    public struct Conversation: Equatable, Sendable {
        public var id: String
        public var handle: String?
        public var sidebarTitle: String?
        public var folder: String
        public var activeAt: Int?

        public init(id: String, handle: String? = nil, sidebarTitle: String? = nil, folder: String, activeAt: Int? = nil) {
            self.id = id
            self.handle = handle
            self.sidebarTitle = sidebarTitle
            self.folder = folder
            self.activeAt = activeAt
        }
    }

    public struct Lock: Equatable, Sendable {
        public var pid: Int
        public var port: Int

        public init(pid: Int, port: Int) {
            self.pid = pid
            self.port = port
        }
    }

    public struct Project: Equatable, Sendable {
        public var root: String
        public var name: String

        public init(root: String, name: String) {
            self.root = root
            self.name = name
        }
    }

    private static let rootConversation = 1
    private static let standingLabel = "agent"
    private static let landerLabel = "lander"

    private struct Listed: Decodable {
        var id: Int
        var title: String?
        var label: String?
        var cwd: String?
        var inputAt: Double?
        var answerAt: Double?
    }

    public static func conversations(_ data: Data) -> [Conversation]? {
        guard let listed = try? JSONDecoder().decode([Listed].self, from: data) else { return nil }
        return listed.compactMap { item in
            guard item.id != rootConversation, item.label != landerLabel else { return nil }
            let latest = [item.inputAt, item.answerAt].compactMap { $0 }.max()
            return Conversation(
                id: String(item.id), handle: item.label == standingLabel ? item.title : nil,
                sidebarTitle: item.title, folder: item.cwd ?? "", activeAt: latest.map { Int($0 / 1000) })
        }
    }

    private struct ConnectorList: Decodable {
        struct Row: Decodable {
            var id: Int
            var handle: String?
            var title: String?
            var cwd: String
            var activeAt: Int?
        }
        var result: [Row]
    }

    public static func listed(_ answer: Data) -> [Conversation]? {
        guard let list = try? JSONDecoder().decode(ConnectorList.self, from: answer) else { return nil }
        return list.result.map {
            Conversation(id: String($0.id), handle: $0.handle, sidebarTitle: $0.title, folder: $0.cwd, activeAt: $0.activeAt)
        }
    }

    public static func lock(_ data: Data) -> Lock? {
        struct Owner: Decodable {
            var pid: Int
            var port: Int?
        }
        guard let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.pid > 0, let port = owner.port, port > 0, port < 65536
        else { return nil }
        return Lock(pid: owner.pid, port: port)
    }

    public static func project(_ data: Data) -> Project? {
        struct Record: Decodable {
            var root: String?
            var name: String?
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), let root = record.root, !root.isEmpty else { return nil }
        return Project(root: root, name: record.name ?? (root as NSString).lastPathComponent)
    }

    public static func isSetupFolder(name: String, contents: [String]) -> Bool {
        name == setupFolderName && contents.contains { [projectsFolder, settingsFile, "model-families.json", "onboarding.json"].contains($0) }
    }

    public static func turnedOff(_ settings: Data?, extension name: String) -> Bool? {
        guard let settings else { return false }
        guard let object = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] else { return nil }
        guard let extensions = object["extensions"] else { return false }
        guard let table = extensions as? [String: Any] else { return nil }
        guard let disabled = table["disable"] else { return false }
        guard let names = disabled as? [String] else { return nil }
        return names.contains(name)
    }
}
