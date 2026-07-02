import Foundation
import TOMLKit

public struct MigrationStep {
    public let from: Int
    public let migrate: (TOMLTable) throws -> Void

    public init(from: Int, migrate: @escaping (TOMLTable) throws -> Void) {
        self.from = from
        self.migrate = migrate
    }
}

public enum MigrationRunner {
    // Version gate only: reject files newer than this build supports and require `schema_version`, but
    // perform no transformation. Stores with no migration steps rely on additive decode for older files.
    public static func gate(toml: String, target: Int) throws -> String {
        _ = try parseAndCheck(toml: toml, target: target)
        return toml
    }

    public static func migrate(
        toml: String, target: Int, steps: [MigrationStep]
    ) throws -> (toml: String, didMigrate: Bool) {
        let (table, version) = try parseAndCheck(toml: toml, target: target)
        if version == target { return (toml, false) }

        var current = version
        while current < target {
            guard let step = steps.first(where: { $0.from == current }) else {
                throw ConfigError.invalid("no migration step from schema_version \(current)")
            }
            try step.migrate(table)
            current += 1
            table["schema_version"] = current
        }
        return (table.convert(), true)
    }

    private static func parseAndCheck(toml: String, target: Int) throws -> (TOMLTable, Int) {
        let table: TOMLTable
        do { table = try TOMLTable(string: toml) }
        catch { throw ConfigError.invalid("\(error)") }

        guard let version = table["schema_version"]?.int else { throw ConfigError.missingSchemaVersion }
        if version > target { throw ConfigError.newerSchemaVersion(found: version, supported: target) }
        return (table, version)
    }
}
