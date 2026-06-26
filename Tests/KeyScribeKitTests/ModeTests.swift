import Testing
@testable import KeyScribeKit

struct ModeTests {
    @Test func decodesFullModeFile() throws {
        let toml = """
        schema_version = 1
        name = "Email"
        enabled = true
        trigger_phrases = ['(?i)\\bas an email$']
        source = "dictation"
        output = "cursor"
        insertion = "paste"
        exclude_from_history = false

        [[trigger_keys]]
        key = "right_option"
        press_style = "hold-or-tap"

        [[constraints]]
        bundle_id = "com.apple.mail"

        [commands]
        live_edits = true
        privacy = false

        [dictionary]
        include_global = true
        words = ["KeyScribe"]

        [replacements]
        include_global = true
        [[replacements.rules]]
        heard = "at gmail dot com"
        replace = "@gmail.com"
        regex = false

        [ai_rewrite]
        connection = "gemini-flash"
        prompt = "Rewrite as an email."
        fragments = ["my-voice"]
        context = { app = true, visible_text = false }
        """
        let mode = try ModeStore.decode(from: toml, id: "email")
        #expect(mode.id == "email")
        #expect(mode.name == "Email")
        #expect(mode.enabled)
        #expect(mode.triggerKeys == [Mode.TriggerKey(key: "right_option", pressStyle: "hold-or-tap")])
        #expect(mode.triggerPhrases == [#"(?i)\bas an email$"#])
        #expect(mode.constraints == [Mode.Constraint(bundleId: "com.apple.mail", urlPattern: nil)])
        #expect(mode.source == .dictation)
        #expect(mode.output == .cursor)
        #expect(mode.commands.liveEdits)
        #expect(!mode.commands.privacy)
        #expect(mode.dictionary.includeGlobal)
        #expect(mode.dictionary.words == ["KeyScribe"])
        #expect(mode.replacements.rules.first?.replace == "@gmail.com")
        #expect(mode.aiRewrite?.connection == "gemini-flash")
        #expect(mode.aiRewrite?.context.app == true)
        #expect(mode.aiRewrite?.context.visibleText == false)
        #expect(mode.insertion == .paste)
        #expect(!mode.excludeFromHistory)
    }

    @Test func appliesDefaultsForMinimalMode() throws {
        let mode = try ModeStore.decode(from: "schema_version = 1\nname = \"Plain\"", id: "plain")
        #expect(mode.enabled)              // default true
        #expect(mode.source == .dictation)
        #expect(mode.output == .cursor)
        #expect(!mode.commands.liveEdits)
        #expect(mode.dictionary.includeGlobal)
        #expect(mode.replacements.includeGlobal)
        #expect(mode.insertion == .paste)
        #expect(mode.aiRewrite == nil)
        #expect(mode.triggerKeys.isEmpty)
        #expect(mode.constraints.isEmpty)
    }

    @Test func privacyModeForcesContextOffSemantics() throws {
        // The model carries the toggle; the forced-off behavior is enforced at use time.
        let mode = try ModeStore.decode(
            from: "schema_version = 1\nname = \"Secure\"\n[commands]\nprivacy = true", id: "secure")
        #expect(mode.commands.privacy)
        #expect(mode.effectiveContext == Mode.ContextOptIn(app: false, visibleText: false))
    }

    @Test func localOnlyForSecureFieldStripsCloudAndContext() {
        var mode = Mode(id: "polished", name: "Polished")
        mode.aiRewrite = Mode.AIRewrite(
            connection: "gemini", prompt: "Clean it up.",
            context: .init(app: true, visibleText: true, precedingText: true))
        let secured = mode.localOnlyForSecureField()
        #expect(secured.aiRewrite == nil)
        #expect(secured.commands.privacy)
        #expect(secured.effectiveContext == Mode.ContextOptIn())
        #expect(secured.effectiveContextCategories.isEmpty)
        // Identity and name are preserved so the HUD still shows the resolved mode.
        #expect(secured.id == "polished")
        #expect(secured.name == "Polished")
    }

    @Test func missingSchemaVersionThrows() {
        #expect(throws: ConfigError.missingSchemaVersion) {
            try ModeStore.decode(from: "name = \"X\"", id: "x")
        }
    }

    @Test func newerSchemaVersionThrows() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 5, supported: 1)) {
            try ModeStore.decode(from: "schema_version = 5\nname = \"X\"", id: "x")
        }
    }

    @Test func seedProvenanceRoundTrips() throws {
        let toml = "schema_version = 1\nseed_id = \"polished-dictation\"\nseed_version = 2\nname = \"Polished\""
        let mode = try ModeStore.decode(from: toml, id: "polished-dictation")
        #expect(mode.seedId == "polished-dictation")
        #expect(mode.seedVersion == 2)
        let again = try ModeStore.decode(from: ModeStore.encode(mode), id: "polished-dictation")
        #expect(again.seedId == "polished-dictation")
        #expect(again.seedVersion == 2)
    }

    @Test func userCreatedModeHasNoSeedProvenance() throws {
        let mode = try ModeStore.decode(from: "schema_version = 1\nname = \"Mine\"", id: "mine")
        #expect(mode.seedId == nil)
        #expect(mode.seedVersion == nil)
        #expect(try !ModeStore.encode(mode).contains("seed_id"))
    }

    @Test func starterModesAreStampedWithSeedProvenance() {
        for mode in ModeStore.starterModes() {
            #expect(mode.seedId == mode.id)
            #expect(mode.seedVersion == 1)
        }
    }

    @Test func roundTripsThroughEncode() throws {
        let mode = try ModeStore.decode(
            from: "schema_version = 1\nname = \"Email\"\n[commands]\nlive_edits = true", id: "email")
        let toml = try ModeStore.encode(mode)
        let again = try ModeStore.decode(from: toml, id: "email")
        #expect(again.name == "Email")
        #expect(again.commands.liveEdits)
    }

    // Every field set to a non-default value — a full round-trip catches any broken snake_case key
    // in encode (trigger_keys, ai_rewrite, the nested context opt-ins, etc.).
    @Test func fullModeRoundTripPreservesEveryField() throws {
        var m = Mode(id: "email", name: "Email")
        m.enabled = false
        m.triggerKeys = [.init(key: "right_option", pressStyle: "hold-only")]
        m.triggerPhrases = [#"(?i)\bas an email$"#]
        m.constraints = [.init(bundleId: "com.apple.mail", urlPattern: #"mail\.google\.com"#)]
        m.source = .selection
        m.output = .replaceSelection
        m.commands = .init(liveEdits: true, privacy: true)
        m.dictionary = .init(includeGlobal: false, words: ["KeyScribe"])
        m.replacements = .init(includeGlobal: false, rules: [.init(heard: "a", replace: "b", regex: true)])
        m.aiRewrite = .init(connection: "gemini", prompt: "Rewrite.", fragments: ["my-voice"],
                            context: .init(app: true, visibleText: true))
        m.insertion = .type
        m.trailing = .newline
        m.submit = .shiftReturn
        m.excludeFromHistory = true
        m.seedId = "email"
        m.seedVersion = 3

        let again = try ModeStore.decode(from: ModeStore.encode(m), id: "email")
        #expect(again == m)
    }

    @Test func effectiveContextWhenPrivacyOffReturnsModeContext() {
        var m = Mode(id: "x", name: "X")
        m.aiRewrite = .init(connection: "c", prompt: "p", context: .init(app: true, visibleText: false))
        #expect(m.effectiveContext == Mode.ContextOptIn(app: true, visibleText: false))
    }

    @Test func privacyForcesPrecedingTextOff() throws {
        var m = Mode(id: "x", name: "X")
        m.commands.privacy = true
        m.aiRewrite = .init(connection: "c", prompt: "p", context: .init(precedingText: true))
        #expect(m.effectiveContext.precedingText == false)
        #expect(!m.effectiveContextCategories.contains("preceding text"))
    }

    @Test func precedingTextContextRoundTrips() throws {
        var m = Mode(id: "x", name: "X")
        m.aiRewrite = .init(connection: "c", prompt: "p", context: .init(app: false, visibleText: false, precedingText: true))
        let again = try ModeStore.decode(from: ModeStore.encode(m), id: "x")
        #expect(again.aiRewrite?.context.precedingText == true)
        #expect(again.effectiveContextCategories.contains("preceding text"))
    }

    @Test func effectiveContextWithNoRewriteIsAllOff() {
        #expect(Mode(id: "x", name: "X").effectiveContext == Mode.ContextOptIn(app: false, visibleText: false))
    }

    @Test func effectiveContextCategoriesRespectPrivacy() {
        var mode = Mode(id: "x", name: "X")
        mode.aiRewrite = .init(connection: "c", prompt: "p", context: .init(app: true, visibleText: true))
        #expect(mode.effectiveContextCategories == ["app", "visible text"])
        mode.commands.privacy = true
        #expect(mode.effectiveContextCategories.isEmpty)
    }

    @Test func trailingAndSubmitDefaultToNone() throws {
        let mode = try ModeStore.decode(from: "schema_version = 1\nname = \"Plain\"", id: "plain")
        #expect(mode.trailing == .none)
        #expect(mode.submit == .none)
    }

    @Test func trailingSuffixMapping() {
        #expect(Mode.Trailing.none.suffix == "")
        #expect(Mode.Trailing.space.suffix == " ")
        #expect(Mode.Trailing.newline.suffix == "\n")
    }

    @Test func trailingAndSubmitDecodeAndRoundTrip() throws {
        let toml = """
        schema_version = 1
        name = "Slack"
        trailing = "space"
        submit = "cmd_return"
        """
        let mode = try ModeStore.decode(from: toml, id: "slack")
        #expect(mode.trailing == .space)
        #expect(mode.submit == .cmdReturn)
        let again = try ModeStore.decode(from: ModeStore.encode(mode), id: "slack")
        #expect(again.trailing == .space)
        #expect(again.submit == .cmdReturn)
    }
}
