import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ConnectorSetupRegistryTests {
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setups-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aMissingFileIsNoSetupsAndAGrantIsSavedBeforeItAdmits() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        #expect(registry.problem == nil)
        let setup = try registry.grant(agent: "pi", folder: "/a")
        #expect(registry.admits(agent: "pi", installation: setup.installation))
        #expect(ConnectorSetupRegistry(directory: dir).admits(agent: "pi", installation: setup.installation))
    }

    @Test func anUnreadableFileAdmitsNothingAndRefusesGrants() throws {
        let dir = directory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent(ConnectorSetupRegistry.fileName))
        let registry = ConnectorSetupRegistry(directory: dir)
        #expect(registry.problem != nil)
        #expect(registry.setups == nil)
        #expect(throws: (any Error).self) { try registry.grant(agent: "pi", folder: "/a") }
        #expect(throws: ConnectorSetupRegistry.Unavailable.self) { try registry.beginRemoval(agent: "pi", folder: "/a") }
        #expect(throws: ConnectorSetupRegistry.Unavailable.self) { try registry.finishRemoval(agent: "pi", folder: "/a") }
        #expect(!registry.admits(agent: "pi", installation: "anything"))
    }

    @Test func aFileThatBecomesUnreadableKeepsTheSetupsAlreadyLoaded() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        let setup = try registry.grant(agent: "pi", folder: "/a")
        try Data("{".utf8).write(to: dir.appendingPathComponent(ConnectorSetupRegistry.fileName))
        registry.reload()
        #expect(registry.problem != nil)
        #expect(registry.admits(agent: "pi", installation: setup.installation))
    }

    @Test func aRevocationTakesEffectEvenWhenItCannotBeSaved() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        let setup = try registry.grant(agent: "pi", folder: "/a")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        #expect(throws: (any Error).self) { try registry.beginRemoval(agent: "pi", folder: "/a") }
        #expect(!registry.admits(agent: "pi", installation: setup.installation))
    }

    @Test func aFileFromANewerVersionIsUnreadable() throws {
        let dir = directory()
        try Data(#"{"schema_version": 99, "setups": []}"#.utf8).write(to: dir.appendingPathComponent(ConnectorSetupRegistry.fileName))
        #expect(ConnectorSetupRegistry(directory: dir).problem != nil)
    }

    @Test func aRepairedFileIsReadAgainOnReload() throws {
        let dir = directory()
        let file = dir.appendingPathComponent(ConnectorSetupRegistry.fileName)
        try Data("not json".utf8).write(to: file)
        let registry = ConnectorSetupRegistry(directory: dir)
        try FileManager.default.removeItem(at: file)
        registry.reload()
        #expect(registry.problem == nil)
        #expect(throws: Never.self) { try registry.grant(agent: "pi", folder: "/a") }
    }
}
