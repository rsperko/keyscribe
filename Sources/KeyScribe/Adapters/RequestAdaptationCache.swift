import Foundation
import KeyScribeKit

actor RequestAdaptationCache {
    static let shared = RequestAdaptationCache()

    private var entries: [String: RequestAdaptations] = [:]

    func lookup(_ key: String) -> RequestAdaptations? { entries[key] }

    func remember(_ adaptations: RequestAdaptations, for key: String) { entries[key] = adaptations }

    func reset() { entries.removeAll() }
}

actor WireAPIOverrideCache {
    static let shared = WireAPIOverrideCache()

    static func key(for connection: Connection) -> String {
        [connection.id, connection.model, connection.baseUrl ?? ""].joined(separator: "\n")
    }

    private var overrides: [String: Connection.WireAPI] = [:]

    func lookup(_ key: String) -> Connection.WireAPI? { overrides[key] }

    func remember(_ wireAPI: Connection.WireAPI, for key: String) { overrides[key] = wireAPI }

    func forget(_ key: String) { overrides[key] = nil }

    func reset() { overrides.removeAll() }
}
