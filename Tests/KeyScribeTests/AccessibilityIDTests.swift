import Foundation
import Testing
@testable import KeyScribe

struct AccessibilityIDTests {
    // Catalog constants are a lowercase dot-path: each dot-separated segment starts with a lowercase
    // letter and is otherwise camelCase alphanumerics (e.g. "settings.sidebar.speechModels"). No spaces.
    static let pattern = "^[a-z][a-zA-Z0-9]*(\\.[a-z][a-zA-Z0-9]*)+$"

    @Test func everyCatalogIdentifierMatchesTheNamingPattern() {
        let regex = try! NSRegularExpression(pattern: Self.pattern)
        for id in AccessibilityID.all {
            let range = NSRange(id.startIndex..., in: id)
            #expect(
                regex.firstMatch(in: id, range: range) != nil,
                "identifier \"\(id)\" is not a lowercase dot-path")
        }
    }

    @Test func catalogIdentifiersAreUnique() {
        var seen = Set<String>()
        for id in AccessibilityID.all {
            #expect(seen.insert(id).inserted, "duplicate identifier \"\(id)\"")
        }
    }

    @Test func dynamicRowIdentifiersInterpolateTheDomainID() {
        #expect(AccessibilityID.Settings.Speech.row("parakeet-tdt-v3") == "settings.speech.row.parakeet-tdt-v3")
        #expect(AccessibilityID.Settings.AI.row("fast") == "settings.ai.list.row.fast")
        #expect(AccessibilityID.Mode.List.row("_direct") == "mode.list.row._direct")
        #expect(AccessibilityID.Settings.Permissions.row("microphone") == "settings.permissions.row.microphone")
        #expect(AccessibilityID.Menu.modeRow("_direct") == "menu.modes._direct")
    }

    // Dynamic ids splice a stable domain id (engine/mode/connection/feature/permission id) into a fixed
    // dot-path. The domain segment itself may carry '-', '_', or a leading '_' (e.g. "_direct"), so the
    // catalog pattern does not apply to it — but the fixed prefix must hold and the id never has spaces.
    @Test func dynamicRowIdentifiersKeepTheirFixedPrefixAndHaveNoSpaces() {
        let cases: [(String, String)] = [
            (AccessibilityID.Settings.Speech.primaryAction("apple"), "settings.speech.row."),
            (AccessibilityID.Settings.Permissions.openSettings("accessibility"), "settings.permissions.row."),
            (AccessibilityID.Settings.Advanced.feature("streaming_transcription"), "settings.advanced.feature."),
            (AccessibilityID.FirstRun.Permissions.grant("microphone"), "firstrun.permissions.row."),
            (AccessibilityID.FirstRun.Playground.lesson("polish"), "firstrun.playground.lesson."),
        ]
        for (id, prefix) in cases {
            #expect(id.hasPrefix(prefix), "\(id) missing prefix \(prefix)")
            #expect(!id.contains(" "), "\(id) contains a space")
        }
    }
}
