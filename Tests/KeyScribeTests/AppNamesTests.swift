import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct AppNamesTests {
    private typealias App = VoiceCommandCatalog.App

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-app-names-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func app(
            _ path: String, id: String, info: [String: String] = [:], localized: [String: [String: String]] = [:]
        ) throws -> URL {
            let url = root.appendingPathComponent(path)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: String] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
            plist.merge(info) { _, new in new }
            try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            for (language, strings) in localized {
                let lproj = contents.appendingPathComponent("Resources/\(language).lproj")
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                try (strings as NSDictionary).write(to: lproj.appendingPathComponent("InfoPlist.strings"))
            }
            return url
        }
    }

    @Test func aRenamedBundleAnswersToItsFileAndBundleNames() throws {
        let fixture = Fixture()
        let url = try fixture.app("VSCode.app", id: "com.microsoft.VSCode", info: ["CFBundleName": "Code"])
        #expect(AppNames.app(at: url, bundleId: "com.microsoft.VSCode")
                == App(name: "VSCode", bundleId: "com.microsoft.VSCode", spokenNames: ["VSCode", "Code"]))
    }

    @Test func eachPlistKeyPrefersItsOwnLocalizedValue() throws {
        let fixture = Fixture()
        let url = try fixture.app(
            "Tool.app", id: "com.example.tool", info: ["CFBundleDisplayName": "Tool Display", "CFBundleName": "Tool Bundle"],
            localized: ["fr": ["CFBundleName": "Outil"]])
        #expect(AppNames.app(at: url, bundleId: "com.example.tool", preferences: ["fr-FR"])?.spokenNames
                == ["Tool", "Tool Display", "Outil"])
    }

    @Test func aLanguageTheUserDoesNotReadNeverNamesTheApp() throws {
        let fixture = Fixture()
        let url = try fixture.app(
            "Tool.app", id: "com.example.tool", info: ["CFBundleName": "Tool Bundle", "CFBundleDevelopmentRegion": "en"],
            localized: ["ca": ["CFBundleName": "Eina"], "de": ["CFBundleName": "Werkzeug"]])
        #expect(AppNames.app(at: url, bundleId: "com.example.tool", preferences: ["fr-FR"])?.spokenNames == ["Tool", "Tool Bundle"])
        #expect(AppNames.app(at: url, bundleId: "com.example.tool", preferences: ["de-CH"])?.spokenNames == ["Tool", "Werkzeug"])
    }

    @Test func localizationFollowsThePreferencesThenTheDevelopmentRegion() {
        #expect(AppNames.localization(available: ["ca", "de", "en"], preferences: ["fr-FR"], developmentRegion: "en") == "en")
        #expect(AppNames.localization(available: ["ca", "de", "en"], preferences: ["fr-FR"], developmentRegion: "de") == "de")
        #expect(AppNames.localization(available: ["ca", "de"], preferences: ["fr-FR"], developmentRegion: "en") == nil)
        #expect(AppNames.localization(available: ["de", "fr"], preferences: ["fr-CA", "de"], developmentRegion: "en") == "fr")
        #expect(AppNames.localization(available: ["English", "German"], preferences: ["en-US"], developmentRegion: nil) == "English")
        #expect(AppNames.localization(available: ["pt", "pt-PT"], preferences: ["pt-PT"], developmentRegion: "en") == "pt-PT")
    }

    @Test func onlyTheMacVariantOfAPlatformTableCounts() {
        #expect(AppNames.localization(available: ["en_GB", "en_AU~appletv"], preferences: ["en-GB"], developmentRegion: "en") == "en_GB")
        #expect(AppNames.localization(available: ["en~mac", "en~iphone", "en_AU"], preferences: ["en-US"], developmentRegion: "en") == "en~mac")
        #expect(AppNames.localization(available: ["en", "en~mac"], preferences: ["en-US"], developmentRegion: "en") == "en~mac")
        #expect(AppNames.localization(available: ["en~appletv", "en~ipad"], preferences: ["en-US"], developmentRegion: "en") == nil)
    }

    @Test func anotherRegionOrScriptOfTheLanguageIsNeverChosen() {
        #expect(AppNames.localization(available: ["en_AU", "en_CA", "en_GB", "en_PH"], preferences: ["en-US"], developmentRegion: "en") == nil)
        #expect(AppNames.localization(available: ["zh-Hans", "zh-Hant"], preferences: ["zh-Hant-TW"], developmentRegion: "en") == "zh-Hant")
        #expect(AppNames.localization(available: ["zh_CN", "zh_TW"], preferences: ["zh-Hant-TW"], developmentRegion: "en") == "zh_TW")
        #expect(AppNames.localization(available: ["pt-PT"], preferences: ["pt-BR"], developmentRegion: "en") == nil)
        #expect(AppNames.localization(available: ["en_GB"], preferences: [], developmentRegion: "en") == nil)
    }

    @Test func aPreferenceWithoutARegionTakesItsLikelyRegion() {
        #expect(AppNames.localization(available: ["zh_CN", "zh_TW"], preferences: ["zh-Hant"], developmentRegion: "en") == "zh_TW")
        #expect(AppNames.localization(available: ["zh_CN", "zh_TW"], preferences: ["zh-Hans"], developmentRegion: "en") == "zh_CN")
        #expect(AppNames.localization(available: ["zh_TW"], preferences: ["zh-Hant"], developmentRegion: "en") == "zh_TW")
        #expect(AppNames.localization(available: ["pt_BR", "pt_PT"], preferences: ["pt"], developmentRegion: "en") == "pt_BR")
    }

    @Test func systemSettingsAndPrintCenterKeepTheirMacNames() throws {
        let fixture = Fixture()
        let settings = try fixture.app("System Settings.app", id: "com.apple.systempreferences", info: ["CFBundleDevelopmentRegion": "en"])
        let table: NSDictionary = [
            "en~mac": ["CFBundleName": "System Settings"], "en~appletv": ["CFBundleName": "Sprocket"],
            "en_AU~appletv": ["CFBundleName": "Sprocket"], "en~iphone": ["CFBundleName": "Settings"],
        ]
        let resources = settings.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try table.write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        #expect(AppNames.app(at: settings, bundleId: "com.apple.systempreferences", preferences: ["en-US"])?.spokenNames
                == ["System Settings"])
        let print = try fixture.app(
            "Print Center.app", id: "com.apple.PrintCenter", info: ["CFBundleName": "Print Center", "CFBundleDevelopmentRegion": "en"],
            localized: ["en_GB": ["CFBundleName": "Print Centre"], "en_CA": ["CFBundleName": "Print Centre"]])
        #expect(AppNames.app(at: print, bundleId: "com.apple.PrintCenter", preferences: ["en-US"])?.spokenNames == ["Print Center"])
        #expect(AppNames.app(at: print, bundleId: "com.apple.PrintCenter", preferences: ["en-GB"])?.spokenNames
                == ["Print Center", "Print Centre"])
    }

    @Test func unreadableMetadataIsReportedSoTheCallerKeepsItsOwnName() throws {
        let fixture = Fixture()
        let url = fixture.root.appendingPathComponent("Gone.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(AppNames.app(at: url, bundleId: "com.example.gone") == nil)
    }

    @Test func anUpdateAtTheSameURLIsReadAgain() throws {
        let fixture = Fixture()
        let url = try fixture.app("Tool.app", id: "com.example.tool", localized: ["en": ["CFBundleName": "Old Tool"]])
        #expect(AppNames.app(at: url, bundleId: "com.example.tool", preferences: ["en"])?.spokenNames == ["Tool", "Old Tool"])
        try fixture.app("Tool.app", id: "com.example.tool", localized: ["en": ["CFBundleName": "New Tool"]])
        #expect(AppNames.app(at: url, bundleId: "com.example.tool", preferences: ["en"])?.spokenNames == ["Tool", "New Tool"])
    }

    @Test func theScanNamesEachAppAndPicksOneCopyPerBundle() throws {
        let fixture = Fixture()
        try fixture.app("Visual Studio Code.app", id: "com.microsoft.VSCode", info: ["CFBundleName": "Code"])
        try fixture.app("Old/Code Copy.app", id: "com.microsoft.VSCode", info: ["CFBundleName": "Code"])
        let registered = try fixture.app("Zed Two.app", id: "dev.zed.Zed", info: ["CFBundleDisplayName": "Zed"])
        try fixture.app("Archive/Zed One.app", id: "dev.zed.Zed")
        try fixture.app("Tool.app", id: "com.example.tool")
        let outside = Fixture()
        let preview = try outside.app("Downloads/Tool Preview.app", id: "com.example.tool")
        let found = LiveVoiceCommandSystem.scanInstalledApps(in: [fixture.root], excluding: nil) {
            ["dev.zed.Zed": registered, "com.example.tool": preview][$0]
        }
        #expect(found == [
            App(name: "Code Copy", bundleId: "com.microsoft.VSCode", spokenNames: ["Code Copy", "Code"]),
            App(name: "Tool Preview", bundleId: "com.example.tool"),
            App(name: "Zed Two", bundleId: "dev.zed.Zed", spokenNames: ["Zed Two", "Zed"]),
        ])
    }
}
