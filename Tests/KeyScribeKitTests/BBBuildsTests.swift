import Foundation
import KeyScribeKit
import Testing

struct BBBuildsTests {
    @Test func theAppABuildRunsFromIsTheBundleItsRuntimeRecordNames() {
        let runtime = Data(#"{"entryPath":"/Applications/bb (Acme).app/Contents/Resources/app.asar.unpacked/dist/bb-app-bridge.mjs","pid":4}"#.utf8)
        #expect(BBBuilds.app(runtime: runtime, launcher: nil) == "/Applications/bb (Acme).app")
    }

    @Test func withoutARuntimeRecordTheAppComesFromTheLauncherBbWrote() {
        let launcher = """
            #!/bin/sh
            data_dir='/Users/a/.acme-bb'
            export BB_DATA_DIR="${BB_DATA_DIR:-$data_dir}"
            runtime='/Users/a/Applications/it'\\''s bb.app/Contents/MacOS/bb'
            exec "$runtime" "$entry" "$@"
            """
        #expect(BBBuilds.app(runtime: nil, launcher: launcher) == "/Users/a/Applications/it's bb.app")
        #expect(BBBuilds.app(runtime: Data("{}".utf8), launcher: launcher) == "/Users/a/Applications/it's bb.app")
    }

    @Test func aRecordThatNamesNoAppBundleNamesNoApp() {
        #expect(BBBuilds.app(runtime: Data(#"{"entryPath":"/opt/bb/bb.js"}"#.utf8), launcher: "runtime='relative/bb.app/x'") == nil)
        #expect(BBBuilds.app(runtime: nil, launcher: nil) == nil)
    }

    @Test func aBuildDeclaresItsDataFolderInItsLaunchEnvironment() {
        #expect(BBBuilds.dataFolder(environment: ["BB_DATA_DIR": "~/.acme-bb"], home: "/Users/a") == "/Users/a/.acme-bb")
        #expect(BBBuilds.dataFolder(environment: ["BB_DATA_DIR": "/srv/bb"], home: "/Users/a") == "/srv/bb")
        #expect(BBBuilds.dataFolder(environment: ["BB_DATA_DIR": "relative"], home: "/Users/a") == nil)
        #expect(BBBuilds.dataFolder(environment: ["OTHER": "/x"], home: "/Users/a") == nil)
        #expect(BBBuilds.dataFolder(environment: nil, home: "/Users/a") == nil)
    }

    @Test func aBuildIsCalledWhatItsAppIsCalled() {
        #expect(BBBuilds.name(info: ["CFBundleDisplayName": "bb (Acme)", "CFBundleName": "bb"]) == "bb (Acme)")
        #expect(BBBuilds.name(info: ["CFBundleName": "bb beta"]) == "bb beta")
        #expect(BBBuilds.name(info: ["CFBundleDisplayName": " "]) == "bb")
        #expect(BBBuilds.name(info: nil) == "bb")
    }

    @Test func twoCopiesOfOneAppAreCalledWhatFinderCallsEachCopy() {
        let info = ["CFBundleDisplayName": "bb", "CFBundleName": "bb"]
        #expect(BBBuilds.name(info: info, app: "/Applications/bb Work.app") == "bb Work")
        #expect(BBBuilds.name(info: info, app: "/Applications/bb.app") == "bb")
        #expect(BBBuilds.name(info: info, app: nil) == "bb")
    }

    @Test func theBuildOfferedFirstIsOneThatIsOpenThenTheUsualFolder() {
        let usual = BBBuild(folder: "/Users/a/.bb", bundle: "dev.bb.desktop", name: "bb")
        let acme = BBBuild(folder: "/Users/a/.acme-bb", bundle: "com.example.acme-bb", name: "bb (Acme)")
        #expect(BBBuilds.preferred([acme, usual], open: { $0 == acme }, home: "/Users/a") == acme)
        #expect(BBBuilds.preferred([acme, usual], open: { _ in true }, home: "/Users/a") == usual)
        #expect(BBBuilds.preferred([acme, usual], open: { _ in false }, home: "/Users/a") == usual)
        #expect(BBBuilds.preferred([acme], open: { _ in false }, home: "/Users/a") == acme)
        #expect(BBBuilds.preferred([], open: { _ in true }, home: "/Users/a") == nil)
    }

    @Test func theCommandOfABuildIsTheLauncherInItsDataFolder() {
        #expect(BBBuild(folder: "/Users/a/.acme-bb", name: "bb").launcher == "/Users/a/.acme-bb/bin/bb")
    }
}
