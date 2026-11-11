import Foundation
import KeyScribeKit

actor RequestAdaptationCache {
    static let shared = RequestAdaptationCache()

    private var file: URL?
    private var entries: [String: RequestAdaptations]

    private let appVersion: String

    init(file: URL? = nil, appVersion: String = DiagnosticsCollector.appVersion()) {
        self.file = file
        self.appVersion = appVersion
        entries = ShapeFile.load(file, appVersion: appVersion) ?? [:]
    }

    func persist(to file: URL) {
        self.file = file
        entries.merge(ShapeFile.load(file, appVersion: appVersion) ?? [:]) { learned, _ in learned }
    }

    func lookup(_ key: String) -> RequestAdaptations? { entries[key] }

    func remember(_ adaptations: RequestAdaptations, for key: String) {
        entries[key] = adaptations
        ShapeFile.save(entries, to: file, appVersion: appVersion)
    }

    func forget(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        ShapeFile.save(entries, to: file, appVersion: appVersion)
    }

    func reset() {
        entries.removeAll()
        ShapeFile.remove(file)
        file = nil
    }
}

actor WireAPIOverrideCache {
    static let shared = WireAPIOverrideCache()

    static func key(for connection: Connection) -> String {
        [connection.id, connection.model, connection.baseUrl ?? ""].joined(separator: "\n")
    }

    private var file: URL?
    private var overrides: [String: Connection.WireAPI]

    private let appVersion: String

    init(file: URL? = nil, appVersion: String = DiagnosticsCollector.appVersion()) {
        self.file = file
        self.appVersion = appVersion
        overrides = ShapeFile.load(file, appVersion: appVersion) ?? [:]
    }

    func persist(to file: URL) {
        self.file = file
        overrides.merge(ShapeFile.load(file, appVersion: appVersion) ?? [:]) { learned, _ in learned }
    }

    func lookup(_ key: String) -> Connection.WireAPI? { overrides[key] }

    func remember(_ wireAPI: Connection.WireAPI, for key: String) {
        overrides[key] = wireAPI
        ShapeFile.save(overrides, to: file, appVersion: appVersion)
    }

    func forget(_ key: String) {
        guard overrides.removeValue(forKey: key) != nil else { return }
        ShapeFile.save(overrides, to: file, appVersion: appVersion)
    }

    func reset() {
        overrides.removeAll()
        ShapeFile.remove(file)
        file = nil
    }
}

private enum ShapeFile {
    private struct Stamped<Value: Codable>: Codable {
        let appVersion: String
        let entries: [String: Value]
    }

    static func load<Value: Codable>(_ file: URL?, appVersion: String) -> [String: Value]? {
        guard let file, let data = try? Data(contentsOf: file),
              let stamped = try? JSONDecoder().decode(Stamped<Value>.self, from: data),
              stamped.appVersion == appVersion
        else { return nil }
        return stamped.entries
    }

    static func save<Value: Codable>(_ entries: [String: Value], to file: URL?, appVersion: String) {
        guard let file, let data = try? JSONEncoder().encode(Stamped(appVersion: appVersion, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func remove(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
