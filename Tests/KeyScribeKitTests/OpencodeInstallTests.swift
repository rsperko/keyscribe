import Foundation
import KeyScribeKit
import Testing

struct OpencodeInstallTests {
    @Test func onlyTheSharedServiceLineIsSupported() {
        #expect(OpencodeInstall.supports(version: "opencode v2.3.2"))
        #expect(OpencodeInstall.supports(version: "2.0.0\n"))
        #expect(OpencodeInstall.supports(version: "opencode v10.1.0"))
        #expect(!OpencodeInstall.supports(version: "opencode v1.19.6"))
        #expect(!OpencodeInstall.supports(version: "1.3.0"))
        #expect(!OpencodeInstall.supports(version: "opencode"))
        #expect(!OpencodeInstall.supports(version: ""))
    }

    @Test func theServiceProcessIsOpencodeServingAsTheService() {
        #expect(OpencodeInstall.isService(arguments: ["/opt/homebrew/Cellar/opencode-v2/2.3.2/bin/opencode", "serve", "--service"]))
        #expect(OpencodeInstall.isService(arguments: ["opencode", "serve", "--service"]))
        #expect(!OpencodeInstall.isService(arguments: ["opencode", "serve", "--port", "4096"]))
        #expect(!OpencodeInstall.isService(arguments: ["opencode"]))
        #expect(!OpencodeInstall.isService(arguments: ["/usr/bin/python3", "opencode", "serve", "--service"]))
        #expect(!OpencodeInstall.isService(arguments: []))
    }

    @Test func aTUIShowsItsWindowTitleUnlessItsSettingsTurnItOff() {
        #expect(OpencodeInstall.showsWindowTitle(settings: nil))
        #expect(OpencodeInstall.showsWindowTitle(settings: Data(#"{"tabs":{"mode":"on"}}"#.utf8)))
        #expect(OpencodeInstall.showsWindowTitle(settings: Data(#"{"terminal":{"title":true}}"#.utf8)))
        #expect(!OpencodeInstall.showsWindowTitle(settings: Data(#"{"terminal":{"title":false}}"#.utf8)))
        #expect(!OpencodeInstall.showsWindowTitle(settings: Data("{ broken".utf8)))
    }

    @Test func theTUISettingsLiveInTheConfigFolder() {
        #expect(OpencodeInstall.tuiSettings(home: "/Users/a", environment: [:]).path == "/Users/a/.config/opencode/cli.json")
        #expect(OpencodeInstall.tuiSettings(home: "/Users/a", environment: ["XDG_CONFIG_HOME": "/c"]).path == "/c/opencode/cli.json")
    }
}
