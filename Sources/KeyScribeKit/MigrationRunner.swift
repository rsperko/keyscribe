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

    // File-level helper: migrate in place, writing a pre-migration backup first (design.md §5.1).
    @discardableResult
    public static func migrateFile(
        at url: URL, target: Int, steps: [MigrationStep], backupDir: URL
    ) throws -> Bool {
        let original = try String(contentsOf: url, encoding: .utf8)
        let result = try migrate(toml: original, target: target, steps: steps)
        guard result.didMigrate else { return false }

        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backup = backupDir.appendingPathComponent("\(url.lastPathComponent).bak")
        try original.write(to: backup, atomically: true, encoding: .utf8)
        try result.toml.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
