import Testing
import TOMLKit
@testable import KeyScribeKit

struct MigrationRunnerTests {
    @Test func noMigrationWhenAtTarget() throws {
        let result = try MigrationRunner.migrate(
            toml: "schema_version = 1\nname = \"x\"", target: 1, steps: [])
        #expect(result.didMigrate == false)
    }

    @Test func migratesOneVersion() throws {
        let steps = [MigrationStep(from: 1) { $0["added"] = true }]
        let result = try MigrationRunner.migrate(
            toml: "schema_version = 1\nname = \"x\"", target: 2, steps: steps)
        #expect(result.didMigrate)
        let table = try TOMLTable(string: result.toml)
        #expect(table["schema_version"]?.int == 2)
        #expect(table["added"]?.bool == true)
        #expect(table["name"]?.string == "x")
    }

    @Test func migratesThroughMultipleSteps() throws {
        let steps = [
            MigrationStep(from: 1) { $0["one"] = true },
            MigrationStep(from: 2) { $0["two"] = true },
        ]
        let result = try MigrationRunner.migrate(
            toml: "schema_version = 1", target: 3, steps: steps)
        let table = try TOMLTable(string: result.toml)
        #expect(table["schema_version"]?.int == 3)
        #expect(table["one"]?.bool == true)
        #expect(table["two"]?.bool == true)
    }

    @Test func newerThanTargetThrows() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 5, supported: 2)) {
            try MigrationRunner.migrate(toml: "schema_version = 5", target: 2, steps: [])
        }
    }

    @Test func missingSchemaVersionThrows() {
        #expect(throws: ConfigError.missingSchemaVersion) {
            try MigrationRunner.migrate(toml: "name = \"x\"", target: 1, steps: [])
        }
    }

    @Test func missingStepInChainThrows() {
        #expect(throws: ConfigError.self) {
            try MigrationRunner.migrate(
                toml: "schema_version = 1", target: 3,
                steps: [MigrationStep(from: 2) { _ in }])
        }
    }

    @Test func gatePassesOlderVersionThrough() throws {
        // No transform: an older-than-target file returns verbatim so additive decode re-derives defaults.
        let source = try MigrationRunner.gate(toml: "schema_version = 0\nname = \"x\"", target: 2)
        #expect(source == "schema_version = 0\nname = \"x\"")
    }

    @Test func gateRejectsNewerVersion() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 3, supported: 1)) {
            try MigrationRunner.gate(toml: "schema_version = 3", target: 1)
        }
    }

    // V6: with an empty migration chain, a schema_version < supportedVersion file must decode (gate only),
    // NOT throw "no migration step". This is the AGENTS.md §Config migrations additive-decode contract.
    @Test func configDecodeWithoutMigrationsDecodesOlderVersion() throws {
        let decoded = try ConfigDecode.table(
            "schema_version = 0\nname = \"old\"", supportedVersion: 2
        ) { table in
            (table["schema_version"]?.int, table["name"]?.string)
        }
        #expect(decoded.0 == 0)
        #expect(decoded.1 == "old")
    }

    @Test func configDecodeRunsMigrationsBeforeBuild() throws {
        let decoded = try ConfigDecode.table(
            "schema_version = 1\nname = \"old\"", supportedVersion: 2,
            migrations: [MigrationStep(from: 1) { table in table["name"] = "new" }]
        ) { table in
            (table["schema_version"]?.int, table["name"]?.string)
        }

        #expect(decoded.0 == 2)
        #expect(decoded.1 == "new")
    }

    @Test func gateTableReturnsParsedTable() throws {
        let table = try MigrationRunner.gateTable(toml: "schema_version = 0\nname = \"x\"", target: 2)
        #expect(table["schema_version"]?.int == 0)
        #expect(table["name"]?.string == "x")
    }

    @Test func gateTableRejectsNewerVersion() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 3, supported: 1)) {
            try MigrationRunner.gateTable(toml: "schema_version = 3", target: 1)
        }
    }

    @Test func migrateTableMutatesInPlace() throws {
        let steps = [MigrationStep(from: 1) { $0["added"] = true }]
        let result = try MigrationRunner.migrateTable(
            toml: "schema_version = 1\nname = \"x\"", target: 2, steps: steps)
        #expect(result.didMigrate)
        #expect(result.table["schema_version"]?.int == 2)
        #expect(result.table["added"]?.bool == true)
        #expect(result.table["name"]?.string == "x")
    }

    @Test func migrateTableAtTargetReturnsParsedOriginal() throws {
        let result = try MigrationRunner.migrateTable(
            toml: "schema_version = 2\nname = \"x\"", target: 2, steps: [])
        #expect(result.didMigrate == false)
        #expect(result.table["schema_version"]?.int == 2)
        #expect(result.table["name"]?.string == "x")
    }
}
