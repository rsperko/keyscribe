import Foundation
import TOMLKit

// The outcome of loading a config file, keeping absent (expected → use default) distinct from a present
// file that failed to decode (malformed, or newer-schema after a downgrade), which must not silently
// disappear (P2-14).
public enum ConfigLoad<T: Equatable & Sendable>: Equatable, Sendable {
    case absent
    case loaded(T)
    case failed(ConfigError)

    // Existence is checked first so a present-but-unreadable file (bad permissions, invalid UTF-8) reports
    // .failed rather than being mistaken for absent — the silent-swallow class this seam closes (P2-14).
    static func read(_ file: URL, decode: (String) throws -> T) -> ConfigLoad<T> {
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        let toml: String
        do { toml = try String(contentsOf: file, encoding: .utf8) }
        catch { return .failed(.invalid("\(error)")) }
        do { return .loaded(try decode(toml)) }
        catch let error as ConfigError { return .failed(error) }
        catch { return .failed(.invalid("\(error)")) }
    }
}

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
