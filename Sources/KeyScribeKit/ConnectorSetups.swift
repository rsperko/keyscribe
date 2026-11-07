import Foundation

public struct ConnectorSetup: Codable, Equatable, Sendable {
    public var agent: String
    public var folder: String
    public var installation: String
    public var removing: Bool

    public init(agent: String, folder: String, installation: String, removing: Bool = false) {
        self.agent = agent
        self.folder = folder
        self.installation = installation
        self.removing = removing
    }
}

public struct ConnectorSetups: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public private(set) var setups: [ConnectorSetup]

    public init(setups: [ConnectorSetup] = []) {
        self.setups = setups
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case setups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setups = try container.decodeIfPresent([ConnectorSetup].self, forKey: .setups) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(setups, forKey: .setups)
    }

    public func admits(agent: String, installation: String?) -> Bool {
        guard let installation else { return false }
        return setups.contains { $0.agent == agent && $0.installation == installation && !$0.removing }
    }

    public func setup(agent: String, folder: String) -> ConnectorSetup? {
        setups.first { $0.agent == agent && $0.folder == folder }
    }

    public func enrolled(agent: String) -> [ConnectorSetup] {
        setups.filter { $0.agent == agent && !$0.removing }
    }

    @discardableResult
    public mutating func enroll(agent: String, folder: String, makeInstallation: () -> String) -> ConnectorSetup {
        if let index = setups.firstIndex(where: { $0.agent == agent && $0.folder == folder }) {
            if setups[index].removing { setups[index] = ConnectorSetup(agent: agent, folder: folder, installation: makeInstallation()) }
            return setups[index]
        }
        let made = ConnectorSetup(agent: agent, folder: folder, installation: makeInstallation())
        setups.append(made)
        return made
    }

    public mutating func beginRemoval(agent: String, folder: String) {
        guard let index = setups.firstIndex(where: { $0.agent == agent && $0.folder == folder }) else { return }
        setups[index].removing = true
    }

    public mutating func finishRemoval(agent: String, folder: String) {
        setups.removeAll { $0.agent == agent && $0.folder == folder && $0.removing }
    }

    public func known(agent: String, default defaultFolder: String, discovered: [String]) -> [String] {
        var seen: Set<String> = []
        return ([defaultFolder] + setups.filter { $0.agent == agent }.map(\.folder) + discovered).filter { seen.insert($0).inserted }
    }
}
