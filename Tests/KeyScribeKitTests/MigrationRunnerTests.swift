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
        // need to go 1→2 but only a 2→3 step exists
        #expect(throws: ConfigError.self) {
            try MigrationRunner.migrate(
                toml: "schema_version = 1", target: 3,
                steps: [MigrationStep(from: 2) { _ in }])
        }
    }
}
