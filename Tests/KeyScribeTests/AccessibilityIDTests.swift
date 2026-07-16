import Foundation
import Testing
@testable import KeyScribe

struct AccessibilityIDTests {
    // Catalog ids are a lowercase dot-path, e.g. "settings.sidebar.speechModels".
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
        #expect(AccessibilityID.History.row("2026-07-12T09-00-00") == "history.list.row.2026-07-12T09-00-00")
    }

    @Test func vocabularyDeletionDialogsHaveStableActions() {
        #expect(AccessibilityID.Settings.Vocabulary.dictionaryDeleteConfirmConfirm
            == "settings.vocabulary.dictionary.deleteConfirm.confirm")
        #expect(AccessibilityID.Settings.Vocabulary.replacementDeleteConfirmCancel
            == "settings.vocabulary.replacements.deleteConfirm.cancel")
    }

    // Dynamic ids splice a domain id (e.g. "_direct") into a fixed prefix, so the lowercase dot-path
    // pattern doesn't apply to the whole id — only the fixed prefix and no-spaces rule are checked here.
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
