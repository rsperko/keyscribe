import Testing
@testable import KeyScribeKit

struct AppNamingTests {
    private typealias App = VoiceCommandCatalog.App

    @Test func theFirstUsableNameIsShownAndEveryDistinctNameIsSpoken() {
        let app = AppNaming.app(bundleId: "com.microsoft.VSCode", names: ["Visual Studio Code", "Code", "Code", "Visual Studio Code"])
        #expect(app == App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode", spokenNames: ["Visual Studio Code", "Code"]))
    }

    @Test func namesThatKeyTheSameAreSpokenOnce() {
        let app = AppNaming.app(bundleId: "com.apple.TextEdit", names: ["TextEdit", "textedit", "Text Edit", "TEXTEDIT"])
        #expect(app.spokenNames == ["TextEdit", "Text Edit"])
    }

    @Test func boundaryDirectionMarksAndWhitespaceAreTrimmedButInnerCharactersStay() {
        let app = AppNaming.app(bundleId: "net.whatsapp.WhatsApp", names: ["\u{200E}WhatsApp ", " Caf\u{00E9}\u{200D}Bar\u{200F}"])
        #expect(app.name == "WhatsApp")
        #expect(app.spokenNames == ["WhatsApp", "Caf\u{00E9}\u{200D}Bar"])
    }

    @Test func anUnusableFirstNameFallsBackToTheNextUsableOne() {
        let app = AppNaming.app(bundleId: "com.example.tool", names: [nil, "  ", "\u{200E}", "...", "Tool"])
        #expect(app == App(name: "Tool", bundleId: "com.example.tool"))
    }

    @Test func noUsableNameLeavesTheBundleId() {
        let app = AppNaming.app(bundleId: "com.example.empty", names: [nil, "", "\u{2066}\u{2069}"])
        #expect(app == App(name: "com.example.empty", bundleId: "com.example.empty"))
    }

    @Test func anAppWithoutExtraNamesSpeaksItsName() {
        #expect(App(name: "Ghostty", bundleId: "com.mitchellh.ghostty").spokenNames == ["Ghostty"])
    }

    @Test func runningEntriesReplaceTheInstalledCopyOfTheSameBundle() {
        let runningCode = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode", spokenNames: ["Visual Studio Code", "Code"])
        let installedCode = App(name: "VSCode", bundleId: "com.microsoft.VSCode")
        let safari = App(name: "Safari", bundleId: "com.apple.Safari")
        #expect(VoiceCommandCatalog.reconciling(installed: [installedCode, safari], with: [runningCode]) == [runningCode, safari])
    }
}
