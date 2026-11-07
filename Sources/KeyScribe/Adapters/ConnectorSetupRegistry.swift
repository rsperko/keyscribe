import Foundation
import KeyScribeKit

final class ConnectorSetupRegistry: @unchecked Sendable {
    static let fileName = "connectors.json"

    struct Unavailable: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    let directory: URL
    var url: URL { directory.appendingPathComponent(Self.fileName) }
    private let lock = NSLock()
    private var loaded: ConnectorSetups?
    private var loadProblem: String?
    private let makeInstallation: @Sendable () -> String

    init(directory: URL, makeInstallation: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.directory = directory
        self.makeInstallation = makeInstallation
        reload()
    }

    var setups: ConnectorSetups? { lock.withLock { loaded } }
    var problem: String? { lock.withLock { loadProblem } }

    func admits(agent: String, installation: String?) -> Bool {
        lock.withLock { loaded?.admits(agent: agent, installation: installation) ?? false }
    }

    func reload() {
        let read = Self.read(url)
        lock.withLock {
            switch read {
            case .success(let setups):
                loaded = setups
                loadProblem = nil
            case .failure(let problem):
                loadProblem = problem.reason
            }
        }
    }

    @discardableResult
    func grant(agent: String, folder: String) throws -> ConnectorSetup {
        try lock.withLock {
            guard var next = loaded else { throw Unavailable(reason: loadProblem ?? "\(Self.fileName) could not be read.") }
            let setup = next.enroll(agent: agent, folder: folder, makeInstallation: makeInstallation)
            try write(next)
            loaded = next
            return setup
        }
    }

    func beginRemoval(agent: String, folder: String) throws {
        try revoke { $0.beginRemoval(agent: agent, folder: folder) }
    }

    func finishRemoval(agent: String, folder: String) throws {
        try revoke { $0.finishRemoval(agent: agent, folder: folder) }
    }

    private func revoke(_ change: (inout ConnectorSetups) -> Void) throws {
        try lock.withLock {
            guard var next = loaded else { throw Unavailable(reason: loadProblem ?? "\(Self.fileName) could not be read.") }
            change(&next)
            loaded = next
            try write(next)
        }
    }

    private func write(_ setups: ConnectorSetups) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(setups).write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> Result<ConnectorSetups, Unavailable> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(ConnectorSetups()) }
        guard let data = try? Data(contentsOf: url) else { return .failure(Unavailable(reason: "\(fileName) could not be opened.")) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schema_version"] as? Int, let setups = try? JSONDecoder().decode(ConnectorSetups.self, from: data)
        else { return .failure(Unavailable(reason: "\(fileName) is not in a form \(Branding.appName) can read.")) }
        guard version <= ConnectorSetups.schemaVersion else {
            return .failure(Unavailable(reason: "\(fileName) was saved by a newer version of \(Branding.appName)."))
        }
        return .success(setups)
    }
}
