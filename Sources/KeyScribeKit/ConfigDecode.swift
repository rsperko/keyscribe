import Foundation
import TOMLKit

enum ConfigDecode {
    static func table<T>(
        _ toml: String, supportedVersion: Int, migrations: [MigrationStep] = [],
        _ build: (TOMLTable) throws -> T
    ) throws -> T {
        let table: TOMLTable
        do {
            // With no migration steps, reject newer files but let older-or-equal files use additive decode.
            table = migrations.isEmpty
                ? try MigrationRunner.gateTable(toml: toml, target: supportedVersion)
                : try MigrationRunner.migrateTable(toml: toml, target: supportedVersion, steps: migrations).table
        } catch let e as ConfigError {
            throw e
        } catch {
            throw ConfigError.invalid("\(error)")
        }

        do { return try build(table) }
        catch let e as ConfigError { throw e }
        catch { throw ConfigError.invalid("\(error)") }
    }
}
