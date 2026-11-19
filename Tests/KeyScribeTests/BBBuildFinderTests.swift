import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct BBBuildFinderTests {
    final class Fixture {
        let root: URL
        let home: URL
        let folder: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbfind-\(UUID().uuidString.prefix(8))", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            folder = home.appendingPathComponent(".bb-work", isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var path: String { ConnectorFolders.canonical(folder).path }

        func servedFromOutsideAnyApp() throws {
            let launcher = folder.appendingPathComponent(BBBuilds.launcherPath)
            try "#!/bin/sh\nruntime='/nix/store/abc-nodejs-22/bin/node'\nexec \"$runtime\" \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            try Data(#"{"entryPath":"/nix/store/abc-bb-0.49.0/lib/bb-app/dist/bb-app.js","surface":"web"}"#.utf8)
                .write(to: folder.appendingPathComponent(BBBuilds.runtimeFile))
        }

        func app(_ name: String, bundle: String, dataFolder: String?) throws -> URL {
            let app = root.appendingPathComponent("Applications/\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleName": "bb"]
            if let dataFolder { info["LSEnvironment"] = [BBBuilds.dataFolderKey: dataFolder, "BB_SERVER_PORT": "4411"] }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
    }

    @Test func aRecordIsServedOnlyByTheUsersOwnProcessThatStartedBeforeItWasWritten() throws {
        let fixture = try Fixture()
        let now = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
        func record(pid: Int32, at: String) throws {
            try Data(#"{"pid":\#(pid),"serverUrl":"http://127.0.0.1:38886","startedAt":"\#(at)"}"#.utf8)
                .write(to: fixture.folder.appendingPathComponent(BBBuilds.runtimeFile))
        }
        try record(pid: getpid(), at: now)
        #expect(BBBuildFinder.serves(folder: fixture.path))
        try record(pid: 1, at: now)
        #expect(!BBBuildFinder.serves(folder: fixture.path))
        try record(pid: getpid(), at: "2020-01-01T00:00:00.000Z")
        #expect(!BBBuildFinder.serves(folder: fixture.path))
        #expect(BBBuildFinder.environment(folder: fixture.path, home: fixture.home.path)[BBBuilds.serverKey] == nil)
    }

    @Test func aFolderServedFromOutsideAnyAppBelongsToTheAppThatDeclaresIt() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let other = try fixture.app("Notes", bundle: "com.example.notes", dataFolder: nil)
        let work = try fixture.app("bb Work", bundle: "com.example.bb-work", dataFolder: "~/.bb-work")
        let build = BBBuildFinder.describe(folder: fixture.path, apps: [other, work], home: fixture.home.path)
        #expect(build == BBBuild(folder: fixture.path, app: ConnectorFolders.canonical(work).path, bundle: "com.example.bb-work", name: "bb Work"))
    }

    @Test func anAppThatDeclaresTheFolderOutranksTheAppItsRuntimeRecordNames() throws {
        let record = Data(#"{"entryPath":"/Applications/bb.app/Contents/Resources/dist/bb-app.js"}"#.utf8)
        let declared = try Fixture()
        try declared.servedFromOutsideAnyApp()
        try record.write(to: declared.folder.appendingPathComponent(BBBuilds.runtimeFile))
        let work = try declared.app("bb Work", bundle: "com.example.bb-work", dataFolder: declared.path)
        #expect(BBBuildFinder.describe(folder: declared.path, apps: [work], home: declared.home.path)?.app == ConnectorFolders.canonical(work).path)
        let undeclared = try Fixture()
        try undeclared.servedFromOutsideAnyApp()
        try record.write(to: undeclared.folder.appendingPathComponent(BBBuilds.runtimeFile))
        #expect(BBBuildFinder.describe(folder: undeclared.path, apps: [], home: undeclared.home.path)?.app == "/Applications/bb.app")
    }

    @Test func withNoAppDeclaringItAFolderServedFromOutsideAnyAppNamesNoApp() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let elsewhere = try fixture.app("bb Lab", bundle: "com.example.bb-lab", dataFolder: "~/.bb-lab")
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [elsewhere], home: fixture.home.path)
            == BBBuild(folder: fixture.path, name: BBBuilds.fallbackName))
    }

    @Test func ofTwoRunningAppsThatDeclareOneFolderTheFirstByLocationOwnsIt() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let later = try fixture.app("bb Xtra", bundle: "com.example.bb-xtra", dataFolder: "~/.bb-work")
        let first = try fixture.app("bb Work", bundle: "com.example.bb-work", dataFolder: "~/.bb-work")
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [later, first], home: fixture.home.path)?.name == "bb Work")
    }

    @Test func aRunningAppTheRuntimeRecordNamesOutranksADeclaringAppThatQuit() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let quit = try fixture.app("bb Work", bundle: "com.example.bb-work", dataFolder: "~/.bb-work")
        let serving = try fixture.app("bb Serve", bundle: "com.example.bb-serve", dataFolder: nil)
        let entry = ConnectorFolders.canonical(serving).appendingPathComponent("Contents/Resources/dist/bb-app.js").path
        try Data(#"{"entryPath":"\#(entry)"}"#.utf8).write(to: fixture.folder.appendingPathComponent(BBBuilds.runtimeFile))
        _ = BBBuildFinder.describe(folder: fixture.path, apps: [quit], home: fixture.home.path)
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [serving], home: fixture.home.path)?.name == "bb Serve")
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [], home: fixture.home.path)?.name == "bb Work")
    }

    @Test func aDeclaringAppThatQuitKeepsNamingItsFolder() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let work = try fixture.app("bb Work", bundle: "com.example.bb-work", dataFolder: "~/.bb-work")
        _ = BBBuildFinder.describe(folder: fixture.path, apps: [work], home: fixture.home.path)
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [], home: fixture.home.path)?.name == "bb Work")
        try FileManager.default.removeItem(at: work)
        #expect(BBBuildFinder.describe(folder: fixture.path, apps: [], home: fixture.home.path)?.app == nil)
    }

    @Test func findingCopiesNamesEachByTheAppThatDeclaresItsFolder() throws {
        let fixture = try Fixture()
        try fixture.servedFromOutsideAnyApp()
        let work = try fixture.app("bb Work", bundle: "com.example.bb-work", dataFolder: "~/.bb-work")
        let found = BBBuildFinder.find(home: fixture.home.path, apps: [work])
        #expect(found.map(\.name) == ["bb Work"])
        #expect(found.first?.bundle == "com.example.bb-work")
    }
}
