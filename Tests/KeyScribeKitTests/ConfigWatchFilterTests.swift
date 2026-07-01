import XCTest
@testable import KeyScribeKit

final class ConfigWatchFilterTests: XCTestCase {
    private let base = "/Users/x/Library/Application Support/KeyScribe"

    func testHistoryAppendIsIgnored() {
        XCTAssertFalse(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/history/2026-07-01.jsonl", supportDir: base))
    }

    func testLkgWriteIsIgnored() {
        XCTAssertFalse(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/lkg/seed-ledger.toml", supportDir: base))
        XCTAssertFalse(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/lkg/modes/_direct.toml", supportDir: base))
    }

    func testModeWriteInvalidates() {
        XCTAssertTrue(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/modes/x.toml", supportDir: base))
    }

    func testTopLevelConfigFilesInvalidate() {
        for file in ["settings.toml", "connections.toml", "dictionary.toml", "replacements.toml", "_direct.toml"] {
            XCTAssertTrue(ConfigWatchFilter.isConfigRelevant(
                changedPath: base + "/" + file, supportDir: base), file)
        }
    }

    func testFragmentsInvalidate() {
        XCTAssertTrue(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/fragments/greeting.md", supportDir: base))
    }

    func testPrivatePrefixNormalization() {
        // FSEvents delivers /private/var/... while the support URL is /var/...
        let tmpBase = "/var/folders/ab/xyz/T/keyscribe-test"
        XCTAssertFalse(ConfigWatchFilter.isConfigRelevant(
            changedPath: "/private" + tmpBase + "/history/2026-07-01.jsonl", supportDir: tmpBase))
        XCTAssertTrue(ConfigWatchFilter.isConfigRelevant(
            changedPath: "/private" + tmpBase + "/modes/x.toml", supportDir: tmpBase))
    }

    func testPathOutsideSupportDirIsRelevant() {
        XCTAssertTrue(ConfigWatchFilter.isConfigRelevant(
            changedPath: "/somewhere/else/history/x.jsonl", supportDir: base))
    }

    func testBatchFiresWhenAnyPathRelevant() {
        XCTAssertTrue(ConfigWatchFilter.batchIsConfigRelevant(
            changedPaths: [base + "/history/a.jsonl", base + "/modes/x.toml"], supportDir: base))
        XCTAssertFalse(ConfigWatchFilter.batchIsConfigRelevant(
            changedPaths: [base + "/history/a.jsonl", base + "/lkg/b.toml"], supportDir: base))
    }

    func testTrailingSlashOnSupportDir() {
        XCTAssertFalse(ConfigWatchFilter.isConfigRelevant(
            changedPath: base + "/history/a.jsonl", supportDir: base + "/"))
    }
}
