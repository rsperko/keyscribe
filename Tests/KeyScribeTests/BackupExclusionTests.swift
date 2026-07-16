import Foundation
import Testing

@testable import KeyScribe

struct BackupExclusionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func excludingADirectoryMarksItExcludedFromBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BackupExclusion.isExcluded(dir) == false)
        #expect(BackupExclusion.exclude(dir) == true)
        #expect(BackupExclusion.isExcluded(dir) == true)
    }

    @Test func excludingIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BackupExclusion.exclude(dir) == true)
        #expect(BackupExclusion.exclude(dir) == true)
        #expect(BackupExclusion.isExcluded(dir) == true)
    }

    @Test func excludingAMissingPathFailsWithoutThrowing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)", isDirectory: true)

        #expect(BackupExclusion.exclude(missing) == false)
        #expect(BackupExclusion.isExcluded(missing) == false)
    }
}
