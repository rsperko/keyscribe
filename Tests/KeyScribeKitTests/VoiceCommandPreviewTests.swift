import Testing
@testable import KeyScribeKit

struct VoiceCommandPreviewTests {
    private let names: (String) -> String? = {
        ["com.brave.Browser": "Brave Browser", "com.google.Chrome": "Google Chrome", "com.apple.Notes": "Notes"][$0]
    }
    private let gmail = VoiceCommandCatalog.Window(
        bundleId: "com.brave.Browser", appName: "Brave Browser", pid: 1, id: "1",
        title: "pitch - someone@gmail.com - Gmail - Pinned - High memory usage - 1.1 GB - Brave")

    @Test func aWindowIsNamedByThePartOfItsTitleThatWasSaid() {
        let preview = VoiceCommandAction.window(gmail).preview(spoken: "switch to gmail", appName: names)
        #expect(preview == VoiceCommandPreview(
            headline: "Switch to Gmail", context: "Window in Brave Browser", details: .init(label: "Full title", value: gmail.title)))
    }

    @Test func titlePartsNamingDifferentSaidWordsAreAllKept() {
        var window = gmail
        window.title = "Project - Production - Terminal"
        let preview = VoiceCommandAction.window(window).preview(spoken: "switch to project production", appName: names)
        #expect(preview.headline == "Switch to Project \u{2013} Production")
    }

    @Test func theShortestTitlePartSharingTheMostSaidWordsWins() {
        let tab = VoiceCommandCatalog.Tab(
            browserBundleId: "com.google.Chrome", window: 1, tab: 2, url: "https://mail.google.com/",
            title: "Inbox (406) - someone@gmail.com - Gmail")
        let preview = VoiceCommandAction.tab(tab).preview(spoken: "switch to inbox", appName: names)
        #expect(preview.headline == "Switch to Inbox (406)")
        #expect(preview.context == "Tab in Google Chrome")
    }

    @Test func aTitleWithNoSaidWordsIsShownWhole() {
        var window = gmail
        window.title = "Untitled"
        let preview = VoiceCommandAction.window(window).preview(spoken: "switch to draft", appName: names)
        #expect(preview == VoiceCommandPreview(headline: "Switch to Untitled", context: "Window in Brave Browser"))
    }

    @Test func theCommandWordsNeverPickATitlePart() {
        var window = gmail
        window.title = "To Do - Reminders Board"
        let preview = VoiceCommandAction.window(window).preview(spoken: "switch to reminders board", appName: names)
        #expect(preview.headline == "Switch to Reminders Board")
    }

    @Test func appsAndAppNicknamesNameTheAppOnce() {
        let app = VoiceCommandAction.app(.init(name: "Notes", bundleId: "com.apple.Notes"))
        let notes = app.preview(spoken: "switch to notes", appName: names, reach: .running, isRunning: { _ in true })
        #expect(notes == VoiceCommandPreview(headline: "Switch to Notes", context: "App"))
        let nickname = VoiceCommandPlace(name: "Notebook", target: .app(bundleId: "com.apple.Notes"))
        #expect(VoiceCommandAction.place(nickname, .app(bundleId: "com.apple.Notes"))
            .preview(spoken: "notebook", appName: names, reach: .opening, isRunning: { _ in true }) == notes)
    }

    @Test func onlyOpeningAClosedAppSaysItWillStartIt() {
        let app = VoiceCommandAction.app(.init(name: "Notes", bundleId: "com.apple.Notes"))
        let starts = VoiceCommandPreview(headline: "Open Notes", context: "App \u{00B7} starts it if needed")
        #expect(app.preview(spoken: "open notes", appName: names, reach: .opening, isRunning: { _ in false }) == starts)
        #expect(app.preview(spoken: "open notes", appName: names, reach: .opening, isRunning: { _ in true })
            == VoiceCommandPreview(headline: "Switch to Notes", context: "App"))
        let nickname = VoiceCommandPlace(name: "Notebook", target: .app(bundleId: "com.apple.Notes"))
        #expect(VoiceCommandAction.place(nickname, .app(bundleId: "com.apple.Notes"))
            .preview(spoken: "notebook", appName: names, reach: .opening, isRunning: { _ in false }) == starts)
    }

    @Test func aSavedPageNamesTheSiteAndKeepsTheAddressForDetails() {
        let page = VoiceCommandPlace(name: "Example Page", target: .url("https://www.example.com/a/long/path"), browser: "com.google.Chrome")
        let opens = VoiceCommandAction.place(page, .openURL("https://www.example.com/a/long/path", browser: "com.google.Chrome"))
        #expect(opens.preview(spoken: "example page", appName: names) == VoiceCommandPreview(
            headline: "Open Example Page", context: "example.com in Google Chrome",
            details: .init(label: "Full address", value: "https://www.example.com/a/long/path")))
        let tab = VoiceCommandCatalog.Tab(
            browserBundleId: "com.google.Chrome", window: 1, tab: 1, url: "https://example.com/", title: "Example Domain")
        #expect(VoiceCommandAction.place(page, .tab(tab)).preview(spoken: "example page", appName: names) == VoiceCommandPreview(
            headline: "Switch to Example Page", context: "Open tab in Google Chrome",
            details: .init(label: "Tab title", value: "Example Domain")))
    }

    @Test func anAppLinkSaysWhereItOpens() {
        let link = VoiceCommandPlace(name: "Shortcut editor", target: .url("shortcuts://open-shortcut?name=Demo"))
        #expect(VoiceCommandAction.place(link, .openURL("shortcuts://open-shortcut?name=Demo", browser: nil))
            .preview(spoken: "shortcut editor", appName: names) == VoiceCommandPreview(
                headline: "Open Shortcut editor", context: "Link \u{00B7} opens in the app that handles it",
                details: .init(label: "Full address", value: "shortcuts://open-shortcut?name=Demo")))
    }

    @Test func sidebarItemsBackAndActionsReadAsOutcomes() {
        let item = VoiceCommandCatalog.SidebarItem(bundleId: "com.apple.Notes", pid: 1, name: "Recipes", section: nil, path: [0])
        #expect(VoiceCommandAction.sidebarItem(item).preview(spoken: "notes recipes", appName: names)
            == VoiceCommandPreview(headline: "Open Recipes", context: "In the Notes sidebar"))
        #expect(VoiceCommandAction.goBack.preview(spoken: "go back", appName: names)
            == VoiceCommandPreview(headline: "Go back", context: "To where you were before your last command"))
        let speak = VoiceCommandScript(name: "Speak", run: ["/usr/bin/say", "{text}"])
        #expect(VoiceCommandAction.script(speak, arguments: ["hello"]).preview(spoken: "speak hello", appName: names)
            == VoiceCommandPreview(headline: "Run Speak", context: "Runs /usr/bin/say hello in the background."))
    }
}
