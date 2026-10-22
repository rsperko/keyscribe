import Foundation
import Testing
@testable import KeyScribeKit

struct ConfigKeyCheckTests {
    @Test func aMisspelledModeKeyIsReportedWithTheKeyItMeant() {
        let toml = """
        schema_version = 2
        name = "Notes"
        trigger_key = ["fn"]
        """
        #expect(ModeStore.unknownKeys(in: toml) == [UnknownConfigKey(path: "trigger_key", suggestion: "trigger_keys")])
    }

    @Test func aMisspelledKeyInsideATableIsReportedByItsFullPath() {
        let toml = """
        schema_version = 2
        name = "Notes"

        [ai_rewrite]
        connection = "c"
        prompt = "Tidy."
        promt = "Tidy this up."
        """
        #expect(ModeStore.unknownKeys(in: toml) == [UnknownConfigKey(path: "ai_rewrite.promt", suggestion: "prompt")])
    }

    @Test func aMisspelledKeyInAnArrayOfTablesNamesTheEntry() {
        let toml = """
        schema_version = 1

        [[rules]]
        heard = "teh"
        replace = "the"

        [[rules]]
        heard = "recieve"
        replace = "receive"
        regx = true
        """
        #expect(ReplacementsStore.unknownKeys(in: toml) == [UnknownConfigKey(path: "rules[1].regx", suggestion: "regex")])
    }

    @Test func theSameMisspellingInSeveralPlacesIsReportedAtEach() {
        let toml = """
        schema_version = 2
        name = "Notes"
        enabld = true

        [replacements]
        enabld = true

        [[replacements.rules]]
        heard = "teh"
        replace = "the"
        regx = true

        [[replacements.rules]]
        heard = "recieve"
        replace = "receive"
        regx = true
        """
        #expect(ModeStore.unknownKeys(in: toml).map(\.path) == [
            "enabld", "replacements.enabld", "replacements.rules[0].regx", "replacements.rules[1].regx",
        ])
    }

    @Test func aKeyNothingLikeAnyRealKeyGetsNoSuggestion() {
        let toml = """
        schema_version = 2
        name = "Notes"
        favourite_colour = "blue"
        """
        #expect(ModeStore.unknownKeys(in: toml) == [UnknownConfigKey(path: "favourite_colour", suggestion: nil)])
    }

    @Test func aMalformedFileReportsNoUnknownKeysBecauseItFailsToLoadInstead() {
        #expect(ModeStore.unknownKeys(in: "name = [unclosed").isEmpty)
    }

    @Test func retiredSettingsKeysAreNotReported() {
        let toml = """
        schema_version = 1
        default_mode_id = "notes"

        [during_dictation]
        other_audio = "quiet"
        mute_system_audio = true
        keep_display_awake = true
        sounds = true
        """
        #expect(SettingsStore.unknownKeys(in: toml).isEmpty)
    }

    @Test func theLegacyAudioKeyAloneIsReadNotReported() throws {
        let toml = """
        schema_version = 1

        [during_dictation]
        mute_system_audio = false
        keep_display_awake = true
        sounds = true
        sound_volume = 80
        """
        #expect(SettingsStore.unknownKeys(in: toml).isEmpty)
        #expect(try SettingsStore.decode(from: toml).duringDictation.otherAudio == .unchanged)
    }

    @Test func everyKeyTheAppWritesIsAKeyItReads() throws {
        for mode in ModeStore.templates() + ModeStore.starterModes() + [Mode.direct, richMode(), ModeStore.everyKeyExample] {
            #expect(ModeStore.unknownKeys(in: try ModeStore.encode(mode)).isEmpty, "\(mode.id)")
        }
        #expect(SettingsStore.unknownKeys(in: try SettingsStore.encode(.defaults)).isEmpty)
        let connections = ConnectionSet(connections: [
            Connection(
                id: "c", name: "C", provider: .openaiCompatible, model: "m", keyRef: "k",
                baseUrl: "http://127.0.0.1:1/v1", tokenCommand: "printf token",
                params: .init(temperature: 0.4, maxTokens: 100, reasoningEffort: "low", geminiThinkingLevel: "low"))
        ])
        #expect(ConnectionStore.unknownKeys(in: try ConfigEncode.toml(connections)).isEmpty)
        #expect(DictionaryStore.unknownKeys(in: try ConfigEncode.toml(DictionarySet(words: ["Postgres"]))).isEmpty)
        let replacements = ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: true)])
        #expect(ReplacementsStore.unknownKeys(in: try ConfigEncode.toml(replacements)).isEmpty)
    }

    private func richMode() -> Mode {
        var mode = Mode(id: "rich", name: "Rich")
        mode.triggerKeys = [.init(key: "right_option")]
        mode.triggerPhrases = ["note that"]
        mode.constraints = [.init(bundleId: "com.example.app", urlPattern: "example\\.com", windowTitle: "Inbox")]
        mode.source = .selection
        mode.output = .replaceSelection
        mode.dictionary = .init(includeGlobal: false, words: ["Kubernetes"])
        mode.replacements = .init(includeGlobal: false, rules: [.init(heard: "k eight s", replace: "k8s", regex: false)])
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy.", fragments: ["voice"], context: .init(app: true))
        mode.clipboardSync = true
        mode.pasteSettleMs = 50
        mode.trimTrailingPunctuation = true
        mode.excludeFromHistory = true
        return mode
    }
}
