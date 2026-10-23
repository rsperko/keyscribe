import Testing
@testable import KeyScribeKit

struct VoiceCommandAppLinkTests {
    @Test(arguments: ["slack://channel?team=T0123ABCD&id=C0456EFGH", "obsidian://open?vault=Work", "x-notes:open"])
    func anAppLinkIsAValidPlace(_ link: String) {
        let place = VoiceCommandPlace(name: "Channel", target: .url(link))
        #expect(place.issue == nil)
        #expect(place.isAppLink)
    }

    @Test func aWebAddressIsNotAnAppLink() {
        #expect(!VoiceCommandPlace(name: "Mail", target: .url("https://mail.example.com/")).isAppLink)
        #expect(!VoiceCommandPlace(name: "Code", target: .app(bundleId: "com.example.code")).isAppLink)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "blob:https://x", "about:blank",
        "ftp://example.com/", "no scheme here", "://missing", "1bad://x",
    ])
    func aLinkThatCouldReadFilesOrRunCodeIsRefused(_ link: String) {
        #expect(VoiceCommandPlace(name: "Bad", target: .url(link)).issue != nil)
        #expect(!VoiceCommandPlace(name: "Bad", target: .url(link)).isAppLink)
    }

    @Test func anAppLinkWithCredentialsIsRefused() {
        #expect(VoiceCommandPlace(name: "Bad", target: .url("slack://me:secret@open")).issue != nil)
    }

    @Test func anAppLinkCannotChooseABrowser() {
        let place = VoiceCommandPlace(name: "Channel", target: .url("slack://open"), browser: "com.example.browser")
        #expect(place.issue != nil)
    }

    @Test func anAppLinkPlaceOpensWithoutReadingTabs() {
        let place = VoiceCommandPlace(name: "Web Hooks", target: .url("slack://channel?team=T1&id=C1"))
        let resolution = VoiceCommandResolver.resolve(
            "switch to web hooks", catalog: VoiceCommandCatalog(places: [place], tabs: nil, windows: nil))
        #expect(resolution == .action(.place(place, .openURL("slack://channel?team=T1&id=C1", browser: nil))))
    }
}
