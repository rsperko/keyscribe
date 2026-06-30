import Foundation
import TOMLKit

// One forward-only, backup-first migration runner shared by every config file type (design.md
// §5.1). Each step upgrades a TOML table from version `from` to `from + 1`; the runner applies
// the chain in order, refuses files newer than the app understands, and never downgrades.
public struct MigrationStep {
    public let from: Int
    public let migrate: (TOMLTable) throws -> Void

    public init(from: Int, migrate: @escaping (TOMLTable) throws -> Void) {
        self.from = from
        self.migrate = migrate
    }
}

public enum MigrationRunner {
    public static func migrate(
        toml: String, target: Int, steps: [MigrationStep]
    ) throws -> (toml: String, didMigrate: Bool) {
        let table: TOMLTable
        do { table = try TOMLTable(string: toml) }
        catch { throw ConfigError.invalid("\(error)") }

        guard let version = table["schema_version"]?.int else { throw ConfigError.missingSchemaVersion }
        if version > target { throw ConfigError.newerSchemaVersion(found: version, supported: target) }
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
}
