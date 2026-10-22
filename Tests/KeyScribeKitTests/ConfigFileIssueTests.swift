import Testing
@testable import KeyScribeKit

struct ConfigFileIssueTests {
    private let parserError = ConfigError.invalid(
        "Error while parsing literal string: control characters other than TAB (U+0009) are explicitly prohibited (at line 19, column 23)")

    @Test func anUnreadableFileSplitsTheParserMessageFromItsLocation() {
        let issue = ConfigFileIssue.unreadable("settings.toml", error: parserError, recovery: .previousVersion)
        #expect(issue.title == "Couldn’t read settings.toml")
        #expect(issue.location == "Line 19, column 23")
        #expect(issue.detail == "Error while parsing literal string: control characters other than TAB (U+0009) are explicitly prohibited")
        #expect(issue.isError)
    }

    @Test func theRecoverySentenceSaysWhatIsActuallyRunning() {
        #expect(ConfigFileIssue.unreadable("dictionary.toml", error: parserError, recovery: .previousVersion).recovery
            == "The previous version is still in use.")
        #expect(ConfigFileIssue.unreadable("settings.toml", error: parserError, recovery: .defaults).recovery
            .hasPrefix("Default settings are in use until it’s fixed."))
        #expect(ConfigFileIssue.unreadable("replacements.toml", error: parserError, recovery: .ignored).recovery
            == "It’s ignored until it’s fixed.")
    }

    @Test func theOneLineFormNeverShowsTheSwiftErrorWrapper() {
        let line = ConfigFileIssue.unreadable("settings.toml", error: parserError, recovery: .defaults).oneLine
        #expect(!line.contains("invalid("))
        #expect(line.hasPrefix("Couldn’t read settings.toml — "))
        #expect(line.hasSuffix(" — using defaults until fixed"))
    }

    @Test func anErrorWithNoLocationKeepsItsWholeMessage() {
        let issue = ConfigFileIssue.unreadable("notes.toml", error: .missingSchemaVersion, recovery: .ignored)
        #expect(issue.location == nil)
        #expect(issue.detail == "missing schema_version")
    }

    @Test func unreadKeysAreAnAdvisoryNamingEachKey() {
        let issue = ConfigFileIssue.unusedKeys(
            "notes.toml", relativePath: "modes/notes.toml",
            [UnknownConfigKey(path: "trigger_key", suggestion: "trigger_keys")])
        #expect(!issue.isError)
        #expect(issue.relativePath == "modes/notes.toml")
        #expect(issue.oneLine == "notes.toml — “trigger_key” (did you mean “trigger_keys”?) has no effect")
    }

    @Test func theMenuSummaryIsShortAndCountsFiles() {
        let settings = ConfigFileIssue.unreadable("settings.toml", error: parserError, recovery: .previousVersion)
        let replacements = ConfigFileIssue.unreadable("replacements.toml", error: parserError, recovery: .ignored)
        #expect(ConfigFileIssue.menuSummary([]) == nil)
        #expect(ConfigFileIssue.menuSummary([settings]) == "Settings file needs attention…")
        #expect(ConfigFileIssue.menuSummary([replacements]) == "A config file needs attention…")
        #expect(ConfigFileIssue.menuSummary([settings, replacements]) == "2 config files need attention…")
    }

    @Test func aModeFileNamedSettingsIsNotTheSettingsFile() {
        let mode = ConfigFileIssue.unreadable(
            "settings.toml", relativePath: "modes/settings.toml", error: parserError, recovery: .ignored)
        #expect(ConfigFileIssue.menuSummary([mode]) == "A config file needs attention…")
        #expect(mode.title == "Couldn’t read modes/settings.toml")
    }

    @Test func theExplanationIsPlainLanguageForEachKindOfFailure() {
        #expect(ConfigFileIssue.unreadable("a.toml", error: parserError, recovery: .ignored).explanation
            == "There’s a formatting mistake near line 19, column 23 — often a missing quote, bracket, or comma.")
        #expect(ConfigFileIssue.unreadable("a.toml", error: .newerSchemaVersion(found: 3, supported: 2), recovery: .ignored).explanation
            == "It was saved by a newer version of this app.")
        #expect(ConfigFileIssue.unreadable("a.toml", error: .missingSchemaVersion, recovery: .ignored).explanation
            == "It’s missing its schema_version line.")
        #expect(ConfigFileIssue.unreadable("a.toml", error: .invalid("typeMismatch(Swift.Bool)"), recovery: .ignored).explanation
            == "Something in it isn’t valid for this app.")
        #expect(ConfigFileIssue.unreadable("a.toml", error: .unreadableFile("Permission denied"), recovery: .ignored).explanation
            == "It couldn’t be opened as text. Check that you can read it and that it’s saved as UTF-8.")
        #expect(ConfigFileIssue.unusedKeys("a.toml", [UnknownConfigKey(path: "x", suggestion: nil)]).explanation
            == "It has a key this app doesn’t read, usually a typo, so that line has no effect.")
    }

    @Test func aBrokenSettingsFileSaysInAppChangesAreNotSaved() {
        let settings = ConfigFileIssue.unreadable("settings.toml", error: parserError, recovery: .previousVersion)
        #expect(settings.recovery.hasSuffix(
            "App-wide settings you change meanwhile are temporary: fixing the file reloads it and replaces them. Modes and vocabulary still save normally."))
        let replacements = ConfigFileIssue.unreadable("replacements.toml", error: parserError, recovery: .previousVersion)
        #expect(replacements.recovery == "The previous version is still in use.")
    }
}
