import Foundation
import TOMLKit

// Shared decode preamble for every versioned config file: parse the TOML, require a
// `schema_version`, refuse anything newer than the app understands, then run the type-specific
// build step — mapping non-ConfigError failures to `ConfigError.invalid`. One source of truth so
// the five stores (settings, modes, connections, dictionary, replacements) can't drift.
enum ConfigDecode {
    static func table<T>(
        _ toml: String, supportedVersion: Int, _ build: (TOMLTable) throws -> T
    ) throws -> T {
        let table: TOMLTable
        do { table = try TOMLTable(string: toml) }
        catch { throw ConfigError.invalid("\(error)") }

        guard let version = table["schema_version"]?.int else { throw ConfigError.missingSchemaVersion }
        if version > supportedVersion {
            throw ConfigError.newerSchemaVersion(found: version, supported: supportedVersion)
        }

        do { return try build(table) }
        catch let e as ConfigError { throw e }
        catch { throw ConfigError.invalid("\(error)") }
    }
}
