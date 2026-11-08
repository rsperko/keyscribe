import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct SharedVocabularyAudienceTests {
    private func mode(_ name: String, enabled: Bool = true) -> Mode {
        var m = Mode(id: name.lowercased(), name: name)
        m.enabled = enabled
        return m
    }

    @Test func disabledModesAreNamedAsDisabled() {
        let both = VocabularyScopePicker.audience([mode("Code"), mode("Docs")])
        #expect(both.names == "Code and Docs")
        #expect(both.effect == "Changes here apply to both modes.")
        let mixed = VocabularyScopePicker.audience([mode("Code"), mode("Email", enabled: false)])
        #expect(mixed.names == "Code and Email (disabled)")
        #expect(mixed.effect == "Changes here apply to Code now, and to Email when it is enabled.")
        let none = VocabularyScopePicker.audience([mode("Email", enabled: false), mode("Notes", enabled: false)])
        #expect(none.effect == "Used when these modes are enabled.")
        #expect(VocabularyScopePicker.audience([mode("Email", enabled: false)]).effect == "Used when this mode is enabled.")
    }

    @Test func theListSaysWhenSavedEntriesAreNotInUse() {
        let vocabulary = SharedVocabulary(id: "programming", name: "Programming", words: ["Rust"])
        #expect(VocabularyScopePicker.sharedListSubtitle(vocabulary, users: []) == "Not used by any modes")
        #expect(VocabularyScopePicker.sharedListSubtitle(vocabulary, users: [mode("Email", enabled: false)])
            == "Used only by disabled modes")
        #expect(VocabularyScopePicker.sharedListSubtitle(vocabulary, users: [mode("Code")])
            == VocabularyScopePicker.sharedSummary(vocabulary))
    }

    @Test func detachingSaysWhatStillApplies() {
        #expect(VocabularyScopePicker.detachNote(modes: ["Markdown"], vocabularies: ["Programming"])
            == "Markdown will stop using Programming. Global and mode-only entries will still apply.")
        #expect(VocabularyScopePicker.detachNote(modes: ["Code", "Docs"], vocabularies: ["Programming"])
            == "Code and Docs will stop using Programming. Global and mode-only entries will still apply.")
        #expect(VocabularyScopePicker.detachNote(modes: [], vocabularies: ["Programming"]) == nil)
    }
}
