import Testing
@testable import KeyScribeKit

private func mode(
    _ id: String, enabled: Bool = true, keys: [String] = [],
    phrases: [String] = [], bundles: [String] = [], urlPattern: String? = nil
) -> Mode {
    var m = try! ModeStore.decode(from: "schema_version = 1\nname = \"\(id)\"", id: id)
    m.enabled = enabled
    m.triggerKeys = keys.map { Mode.TriggerKey(key: $0) }
    m.triggerPhrases = phrases
    m.constraints = bundles.map { Mode.Constraint(bundleId: $0, urlPattern: urlPattern) }
    return m
}

private func phaseA(_ modes: [Mode], context: RoutingContext, triggerKey: String?) -> Mode {
    ModeResolver.resolvePhaseA(modes: modes, directFallback: .direct, context: context, triggerKey: triggerKey)
}

struct ModeResolverTests {
    // Eligibility
    @Test func emptyConstraintsEligibleEverywhere() {
        let plain = mode("plain")
        #expect(ModeResolver.eligibleModes([plain], context: .init(bundleId: "anything")).map(\.id) == ["plain"])
    }

    @Test func appConstrainedEligibleOnlyInThatApp() {
        let email = mode("email", bundles: ["com.apple.mail"])
        #expect(ModeResolver.eligibleModes([email], context: .init(bundleId: "com.apple.mail")).count == 1)
        #expect(ModeResolver.eligibleModes([email], context: .init(bundleId: "com.apple.notes")).isEmpty)
    }

    @Test func disabledModesAreNeverEligible() {
        let off = mode("off", enabled: false)
        #expect(ModeResolver.eligibleModes([off], context: .init()).isEmpty)
    }

    @Test func urlPatternConstrains() {
        let gmail = mode("gmail", bundles: ["com.google.Chrome"], urlPattern: #"mail\.google\.com"#)
        #expect(ModeResolver.eligibleModes([gmail],
            context: .init(bundleId: "com.google.Chrome", url: "https://mail.google.com/u/0")).count == 1)
        #expect(ModeResolver.eligibleModes([gmail],
            context: .init(bundleId: "com.google.Chrome", url: "https://docs.google.com")).isEmpty)
    }

    @Test func bundlePrefixConstrains() {
        var ide = mode("ide")
        ide.constraints = [Mode.Constraint(bundlePrefix: "com.jetbrains.")]
        #expect(ModeResolver.eligibleModes([ide], context: .init(bundleId: "com.jetbrains.intellij")).count == 1)
        #expect(ModeResolver.eligibleModes([ide], context: .init(bundleId: "com.jetbrains.pycharm")).count == 1)
        #expect(ModeResolver.eligibleModes([ide], context: .init(bundleId: "com.apple.dt.Xcode")).isEmpty)
    }

    @Test func bundlePrefixIsCaseInsensitive() {
        var ide = mode("ide")
        ide.constraints = [Mode.Constraint(bundlePrefix: "com.jetbrains.")]
        #expect(ModeResolver.eligibleModes([ide], context: .init(bundleId: "COM.JetBrains.GoLand")).count == 1)
    }

    @Test func windowTitleConstrains() {
        var review = mode("review")
        review.constraints = [Mode.Constraint(windowTitle: #"(?i)pull request"#)]
        #expect(ModeResolver.eligibleModes([review],
            context: .init(bundleId: "com.google.Chrome", windowTitle: "Add modes · Pull Request #42")).count == 1)
        #expect(ModeResolver.eligibleModes([review],
            context: .init(bundleId: "com.google.Chrome", windowTitle: "Inbox")).isEmpty)
        #expect(ModeResolver.eligibleModes([review],
            context: .init(bundleId: "com.google.Chrome", windowTitle: nil)).isEmpty)
    }

    @Test func bundleIdBeatsBundlePrefixOnSharedKey() {
        var exact = mode("exact", keys: ["right_option"])
        exact.constraints = [Mode.Constraint(bundleId: "com.jetbrains.intellij")]
        var prefix = mode("prefix", keys: ["right_option"])
        prefix.constraints = [Mode.Constraint(bundlePrefix: "com.jetbrains.")]
        let m = phaseA([prefix, exact],
            context: .init(bundleId: "com.jetbrains.intellij"), triggerKey: "right_option")
        #expect(m.id == "exact")
    }

    @Test func urlBeatsWindowTitleOnSharedKey() {
        var titled = mode("titled", keys: ["right_option"])
        titled.constraints = [Mode.Constraint(windowTitle: #"(?i)github"#)]
        var urled = mode("urled", keys: ["right_option"])
        urled.constraints = [Mode.Constraint(urlPattern: #"github\.com"#)]
        let m = phaseA([titled, urled],
            context: .init(bundleId: "com.google.Chrome", url: "https://github.com/x", windowTitle: "GitHub"),
            triggerKey: "right_option")
        #expect(m.id == "urled")
    }

    @Test func requiresWindowTitleContextOnlyWhenAModeUsesIt() {
        var titled = mode("titled")
        titled.constraints = [Mode.Constraint(windowTitle: #"x"#)]
        #expect(ModeResolver.requiresWindowTitleContext([titled]))
        #expect(!ModeResolver.requiresWindowTitleContext([mode("plain")]))
        var off = titled; off.enabled = false
        #expect(!ModeResolver.requiresWindowTitleContext([off]))
    }

    @Test func constraintFieldsCombineForSpecificity() {
        var both = mode("both", keys: ["right_option"])
        both.constraints = [Mode.Constraint(bundleId: "com.google.Chrome", urlPattern: #"github\.com"#)]
        var urlOnly = mode("urlOnly", keys: ["right_option"])
        urlOnly.constraints = [Mode.Constraint(urlPattern: #"github\.com"#)]
        let m = phaseA([urlOnly, both],
            context: .init(bundleId: "com.google.Chrome", url: "https://github.com/x"),
            triggerKey: "right_option")
        #expect(m.id == "both")
    }

    // Phase A
    @Test func triggerKeyBindingSelectsKeyedMode() {
        let plain = mode("plain")
        let email = mode("email", keys: ["right_option"])
        let m = phaseA([plain, email], context: .init(), triggerKey: "right_option")
        #expect(m.id == "email")
    }

    @Test func contextDefaultPrefersAppSpecificMode() {
        let plain = mode("plain")
        let email = mode("email", bundles: ["com.apple.mail"])
        let m = phaseA([plain, email],
            context: .init(bundleId: "com.apple.mail"), triggerKey: nil)
        #expect(m.id == "email")
    }

    @Test func fallsBackToDirectWhenNoKeyAndNoContextMatch() {
        let plain = mode("plain")
        let email = mode("email", bundles: ["com.apple.mail"])
        let m = phaseA([plain, email], context: .init(bundleId: "com.apple.notes"), triggerKey: nil)
        #expect(m.id == Mode.directId)
    }

    @Test func keyPressFallsThroughToDirectWhenConstraintExcludesContext() {
        // design.md §4.3: an app constraint gates every trigger, and a key press is never a no-op —
        // pressing the key outside email's constrained app falls through to Direct.
        let plain = mode("plain")
        let email = mode("email", keys: ["right_option"], bundles: ["com.apple.mail"])
        let m = phaseA([plain, email],
            context: .init(bundleId: "com.apple.notes"), triggerKey: "right_option")
        #expect(m.id == Mode.direct.id)
        #expect(m.aiRewrite == nil)
    }

    @Test func keyPressRunsConstrainedModeInsideItsContext() {
        let plain = mode("plain")
        let email = mode("email", keys: ["right_option"], bundles: ["com.apple.mail"])
        let m = phaseA([plain, email],
            context: .init(bundleId: "com.apple.mail"), triggerKey: "right_option")
        #expect(m.id == "email")
    }

    @Test func userNamedDirectCannotCollideWithTheSystemFloor() {
        // "_direct" lives in the reserved "_" namespace the slugger can never produce from user
        // input, so a user mode named "Direct" gets a distinct id and the two never clash.
        let userId = ModeStore.newID(for: "Direct", existing: [Mode.directId])
        #expect(userId == "direct")
        #expect(userId != Mode.directId)
        #expect(Mode.direct.isSystem)
        #expect(!mode("direct").isSystem)
    }

    @Test func keyPressFallsThroughToDirectWhenAllBoundModesAreIneligible() {
        let slack = mode("slack", keys: ["right_option"], bundles: ["com.tinyspeck.slackmacgap"])
        let obsidian = mode("obsidian", keys: ["right_option"], bundles: ["md.obsidian"])
        let m = phaseA([slack, obsidian],
            context: .init(bundleId: "com.apple.notes"), triggerKey: "right_option")
        #expect(m.id == Mode.direct.id)
    }

    @Test func sharedKeyRoutesByAppContext() {
        let slack = mode("slack", keys: ["right_option"], bundles: ["com.tinyspeck.slackmacgap"])
        let obsidian = mode("obsidian", keys: ["right_option"], bundles: ["md.obsidian"])
        let modes = [slack, obsidian]
        let inSlack = phaseA(modes,
            context: .init(bundleId: "com.tinyspeck.slackmacgap"), triggerKey: "right_option")
        let inObsidian = phaseA(modes,
            context: .init(bundleId: "md.obsidian"), triggerKey: "right_option")
        #expect(inSlack.id == "slack")
        #expect(inObsidian.id == "obsidian")
    }

    @Test func sharedKeyConstrainedBeatsUnconstrainedInItsApp() {
        let plain = mode("plain", keys: ["right_option"])
        let markdown = mode("markdown", keys: ["right_option"], bundles: ["md.obsidian"])
        let modes = [plain, markdown]
        let inObsidian = phaseA(modes,
            context: .init(bundleId: "md.obsidian"), triggerKey: "right_option")
        // An unconstrained mode sharing the key stays eligible everywhere, so the press outside
        // Obsidian runs it rather than falling through to Direct.
        let elsewhere = phaseA(modes,
            context: .init(bundleId: "com.apple.Notes"), triggerKey: "right_option")
        #expect(inObsidian.id == "markdown")
        #expect(elsewhere.id == "plain")
    }

    @Test func phaseAPrefersMostSpecificConstraintOverDeclarationOrder() {
        let app = mode("app", bundles: ["com.google.Chrome"])                                  // score 1
        let appUrl = mode("appurl", bundles: ["com.google.Chrome"], urlPattern: #"github\.com"#) // score 3
        let ctx = RoutingContext(bundleId: "com.google.Chrome", url: "https://github.com/x")
        // app is declared first but must lose: specificity beats declaration order.
        let m = phaseA([app, appUrl], context: ctx, triggerKey: nil)
        #expect(m.id == "appurl")
    }

    // Phase B
    @Test func suffixPhraseRoutesAndStrips() {
        let email = mode("email", phrases: [#"(?i)\bas an email$"#])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [email], transcript: "send this to bob as an email")
        #expect(r.routedModeId == "email")
        #expect(r.transcript == "send this to bob")
    }

    @Test func noPhraseMatchLeavesTranscriptUnchanged() {
        let email = mode("email", phrases: [#"(?i)\bas an email$"#])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [email], transcript: "just a normal sentence")
        #expect(r.routedModeId == nil)
        #expect(r.transcript == "just a normal sentence")
    }

    @Test func multiplePhrasesPerMode() {
        let pig = mode("pig", phrases: [#"(?i)\bas pig latin$"#, #"(?i)\bpig latinize$"#])
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [pig], transcript: "hello world pig latinize").routedModeId == "pig")
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [pig], transcript: "hello as pig latin").routedModeId == "pig")
    }

    @Test func suffixPhraseToleratesSTTPunctuationAndCase() {
        // Parakeet emits capitalized, period-terminated output — must still route.
        let email = mode("email", phrases: [#"(?i)\bas an email$"#])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [email], transcript: "send this to bob as an email.")
        #expect(r.routedModeId == "email")
        #expect(r.transcript == "send this to bob")
    }

    @Test func phraseMustMatchAtSuffixNotMiddle() {
        let email = mode("email", phrases: [#"(?i)\bas an email$"#])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [email], transcript: "as an email send this to bob")
        #expect(r.routedModeId == nil)
    }

    @Test func fallsBackToDirectWhenTheOnlyModeIsIneligible() {
        let plain = mode("plain", bundles: ["com.apple.mail"])
        let m = phaseA([plain], context: .init(bundleId: "com.apple.notes"), triggerKey: nil)
        #expect(m.id == Mode.directId)
    }

    @Test func urlOnlyConstraintMatchesByURL() {
        var gh = mode("gh")
        gh.constraints = [Mode.Constraint(bundleId: nil, urlPattern: #"github\.com"#)]
        #expect(ModeResolver.eligibleModes([gh], context: .init(bundleId: "anything", url: "https://github.com/x")).count == 1)
        #expect(ModeResolver.eligibleModes([gh], context: .init(bundleId: "anything", url: "https://gitlab.com")).isEmpty)
    }

    // The Chrome / ModeB / ModeC / ModeD example from design.md §4.3.
    @Test func phaseBPrefersMoreSpecificEligibleModeOverDeclarationOrder() {
        let search = #"(?i)\bas search$"#
        let b = mode("b", phrases: [search], bundles: ["md.obsidian"])         // ineligible in Chrome
        let c = mode("c", phrases: [search], bundles: ["com.google.Chrome"])   // specific, score 1
        let d = mode("d", phrases: [search])                                   // unconstrained, score 0
        let ctx = RoutingContext(bundleId: "com.google.Chrome")
        // d declared before c to prove specificity beats declaration order; b filtered out entirely.
        let eligible = ModeResolver.eligibleModes([d, b, c], context: ctx)
        let r = ModeResolver.resolvePhaseB(eligibleModes: eligible, transcript: "find this as search", context: ctx)
        #expect(r.routedModeId == "c")
        #expect(r.transcript == "find this")
    }

    // URL probing is opt-in: only worth the Apple Events round trip + Automation prompt when an
    // enabled mode could actually match on URL (design.md §4.4).
    @Test func requiresURLContextOnlyWhenAnEnabledModeHasURLPattern() {
        let plain = mode("plain")
        let appOnly = mode("app", bundles: ["com.apple.mail"])
        #expect(ModeResolver.requiresURLContext([plain, appOnly]) == false)

        let urlMode = mode("gmail", bundles: ["com.google.Chrome"], urlPattern: #"mail\.google\.com"#)
        #expect(ModeResolver.requiresURLContext([plain, urlMode]) == true)

        let disabledURLMode = mode("off", enabled: false, bundles: ["com.google.Chrome"], urlPattern: #"x"#)
        #expect(ModeResolver.requiresURLContext([plain, disabledURLMode]) == false)
    }

    @Test func phaseBTiesBreakByDeclarationOrder() {
        let search = #"(?i)\bas search$"#
        let d1 = mode("d1", phrases: [search])
        let d2 = mode("d2", phrases: [search])   // equal specificity (both unconstrained)
        let r = ModeResolver.resolvePhaseB(eligibleModes: [d1, d2], transcript: "x as search")
        #expect(r.routedModeId == "d1")
    }

    // A bare spoken phrase (no (?i), \b, or $) must route on every common STT output ending: the
    // matcher supplies case-insensitivity, the end anchor, and trailing-cruft tolerance itself.
    @Test(arguments: [
        "summarize this thread as prompt",
        "summarize this thread as prompt.",       // Parakeet/Whisper default
        "summarize this thread as prompt!",
        "summarize this thread as prompt?",
        "summarize this thread as prompt...",
        "summarize this thread as prompt. ",
        "summarize this thread as prompt ",
        "summarize this thread as prompt,\n",
        "summarize this thread As Prompt.",
        "summarize this thread AS PROMPT",
    ])
    func bareLiteralPhraseToleratesCommonSTTEndings(_ transcript: String) {
        let ai = mode("ai-prompt", phrases: ["as prompt"])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [ai], transcript: transcript)
        #expect(r.routedModeId == "ai-prompt")
        #expect(r.transcript == "summarize this thread")
    }

    @Test func bareLiteralPhraseHonorsLeadingWordBoundary() {
        // Must not fire inside "has prompt" / "gas prompt" — that would split a word.
        let ai = mode("ai-prompt", phrases: ["as prompt"])
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [ai], transcript: "this has prompt").routedModeId == nil)
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [ai], transcript: "increase the gas prompt").routedModeId == nil)
        let r = ModeResolver.resolvePhaseB(eligibleModes: [ai], transcript: "rewrite this as prompt")
        #expect(r.routedModeId == "ai-prompt")
        #expect(r.transcript == "rewrite this")
    }

    @Test func bareLiteralPhraseMustBeAtEndNotMiddle() {
        let ai = mode("ai-prompt", phrases: ["as prompt"])
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [ai], transcript: "as prompt summarize this").routedModeId == nil)
    }

    @Test func regexPhraseStillSupported() {
        let note = mode("note", phrases: [#"(?i)\bas (a |an )?note$"#])
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [note], transcript: "jot this as a note.").transcript == "jot this")
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [note], transcript: "jot this as note").transcript == "jot this")
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [note], transcript: "jot this down").routedModeId == nil)
    }

    @Test func caseSensitivityCanBeOptedBackIn() {
        // Phrases are case-insensitive by default; (?-i) opts back in.
        let m = mode("cs", phrases: [#"(?-i)as prompt"#])
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [m], transcript: "do this as prompt").routedModeId == "cs")
        #expect(ModeResolver.resolvePhaseB(eligibleModes: [m], transcript: "do this As Prompt").routedModeId == nil)
    }

    // MARK: mode-choice reasons (UX2 phase 7c) — additions, not behavioral changes.

    @Test func phaseAReasonIsTriggerKeyForAKeySelectedMode() {
        let polish = mode("polish", keys: ["right_option"])
        let r = ModeResolver.resolvePhaseAWithReason(
            modes: [polish], directFallback: .direct, context: .init(), triggerKey: "right_option")
        #expect(r.mode.id == "polish")
        #expect(r.reason == .triggerKey)
    }

    @Test func phaseAReasonIsContextRuleForAConstraintWonMode() {
        let mail = mode("mail", bundles: ["com.apple.mail"])
        let r = ModeResolver.resolvePhaseAWithReason(
            modes: [mail], directFallback: .direct, context: .init(bundleId: "com.apple.mail"), triggerKey: nil)
        #expect(r.mode.id == "mail")
        #expect(r.reason == .contextRule)
    }

    @Test func phaseAReasonIsFallbackWhenNothingMatches() {
        let mail = mode("mail", bundles: ["com.apple.mail"])
        let r = ModeResolver.resolvePhaseAWithReason(
            modes: [mail], directFallback: .direct, context: .init(bundleId: "com.apple.notes"), triggerKey: nil)
        #expect(r.mode.id == Mode.directId)
        #expect(r.reason == .fallback)
    }

    @Test func phaseAReasonIsFallbackWhenBoundKeyIsIneligibleHere() {
        let mail = mode("mail", keys: ["fn"], bundles: ["com.apple.mail"])
        let r = ModeResolver.resolvePhaseAWithReason(
            modes: [mail], directFallback: .direct, context: .init(bundleId: "com.apple.notes"), triggerKey: "fn")
        #expect(r.mode.id == Mode.directId)
        #expect(r.reason == .fallback)
    }

    @Test func phaseBReportsTheMatchedPhrase() {
        let email = mode("email", phrases: ["as an email"])
        let r = ModeResolver.resolvePhaseB(eligibleModes: [email], transcript: "send this to bob as an email")
        #expect(r.routedModeId == "email")
        #expect(r.matchedPhrase == "as an email")
    }
}
