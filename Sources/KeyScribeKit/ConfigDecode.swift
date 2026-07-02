import Foundation
import TOMLKit

enum ConfigDecode {
    static func table<T>(
        _ toml: String, supportedVersion: Int, migrations: [MigrationStep] = [],
        _ build: (TOMLTable) throws -> T
    ) throws -> T {
        let table: TOMLTable
        do {
            let migrated = try MigrationRunner.migrate(
                toml: toml, target: supportedVersion, steps: migrations)
            table = try TOMLTable(string: migrated.toml)
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
