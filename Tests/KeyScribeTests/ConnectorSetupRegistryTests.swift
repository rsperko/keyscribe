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

    @Test func everyChangeToTheLoadedSetupsIsAnnouncedAndNothingElse() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        let changes = Counter()
        registry.onChange = { changes.add() }
        try registry.grant(agent: "pi", folder: "/a")
        try registry.grant(agent: "pi", folder: "/a")
        #expect(changes.value == 1)
        registry.reload()
        #expect(changes.value == 1)
        try ConnectorSetupRegistry(directory: dir).beginRemoval(agent: "pi", folder: "/a")
        registry.reload()
        #expect(changes.value == 2)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(ConnectorSetupRegistry.fileName))
        registry.reload()
        #expect(changes.value == 2)
        try registry.finishRemoval(agent: "pi", folder: "/a")
        #expect(changes.value == 3)
    }

    @Test func aRevocationThatCouldNotBeSavedIsSavedWhenRepeated() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        try registry.grant(agent: "pi", folder: "/a")
        let changes = Counter()
        registry.onChange = { changes.add() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) { try registry.beginRemoval(agent: "pi", folder: "/a") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(changes.value == 1)
        try registry.beginRemoval(agent: "pi", folder: "/a")
        #expect(changes.value == 1)
        #expect(ConnectorSetupRegistry(directory: dir).setups?.setup(agent: "pi", folder: "/a")?.removing == true)
    }

    @Test func aGrantThatCouldNotBeSavedLeavesTheFileInChargeOfTheNextReload() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        try registry.grant(agent: "pi", folder: "/a")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) { try registry.grant(agent: "claude", folder: "/b") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try ConnectorSetupRegistry(directory: dir).grant(agent: "pi", folder: "/c")
        registry.reload()
        #expect(registry.setups?.setup(agent: "pi", folder: "/c") != nil)
        #expect(registry.setups?.setup(agent: "claude", folder: "/b") == nil)
    }

    @Test func aReloadNeverBringsBackARevocationThatIsNotSavedYet() throws {
        let dir = directory()
        let registry = ConnectorSetupRegistry(directory: dir)
        try registry.grant(agent: "pi", folder: "/a")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) { try registry.beginRemoval(agent: "pi", folder: "/a") }
        registry.reload()
        #expect(registry.setups?.setup(agent: "pi", folder: "/a")?.removing == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        registry.reload()
        #expect(registry.setups?.setup(agent: "pi", folder: "/a")?.removing == true)
        #expect(ConnectorSetupRegistry(directory: dir).setups?.setup(agent: "pi", folder: "/a")?.removing == true)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
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
