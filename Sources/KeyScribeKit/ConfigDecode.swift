import Foundation
import TOMLKit

enum ConfigDecode {
    static func table<T>(
        _ toml: String, supportedVersion: Int, migrations: [MigrationStep] = [],
        _ build: (TOMLTable) throws -> T
    ) throws -> T {
        let table: TOMLTable
        do {
            // With no migration steps, preserve the historical "gate only" contract: reject a NEWER file
            // but let an older-or-equal one fall through to additive decode. Running an empty chain through
            // `migrate` would throw on every schema_version < supportedVersion (W23 regression, V6).
            let source = migrations.isEmpty
                ? try MigrationRunner.gate(toml: toml, target: supportedVersion)
                : try MigrationRunner.migrate(toml: toml, target: supportedVersion, steps: migrations).toml
            table = try TOMLTable(string: source)
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
