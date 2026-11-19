import Foundation
import Testing
@testable import KeyScribeKit

// ResolvedConfig is the frozen per-generation config snapshot a dictation captures at record-start
// (design.md §5): a config reload mid-dictation builds a NEW ResolvedConfig rather than mutating the
// one an in-flight dictation holds, so a dictation always sees one coherent config.
struct ResolvedConfigTests {
    private func resolved(
        modes: [Mode] = [], dictionary: [String] = [], replacements: [ReplacementsSet.Rule] = [],
        fragments: [String: String] = [:]
    ) -> ResolvedConfig {
        ResolvedConfig(
            modes: modes, dictionary: DictionarySet(words: dictionary),
            replacements: ReplacementsSet(rules: replacements),
            connections: ConnectionSet(), fragments: fragments)
    }

    @Test func theRewriteNamesOnlyTheDictionaryWordsTheContentContainsIgnoringCase() {
        let rc = resolved(dictionary: ["Kubernetes", "Postgres", "Kryten", "ChargeBee"])
        #expect(rc.dictionaryWordsPresent(in: "the KUBERNETES pod talks to postgresql", for: nil)
            == ["Kubernetes", "Postgres"])
        #expect(rc.dictionaryWordsPresent(in: "nothing to see", for: nil).isEmpty)
    }

    @Test func aDictionaryWordIsPresentOnlyAsWholeCharactersAsBefore() {
        let rc = resolved(dictionary: ["cafe", "café", "Ünter", ""])
        #expect(rc.dictionaryWordsPresent(in: "un cafe\u{301} noir", for: nil) == ["café"])
        #expect(rc.dictionaryWordsPresent(in: "ein ÜNTER cafe", for: nil) == ["cafe", "Ünter"])
    }

    @Test func aDictionaryWordMatchesTextThatIsTheSameCharactersInAnotherEncoding() {
        let rc = resolved(dictionary: ["a;b", "x`y", "kelvin"])
        #expect(rc.dictionaryWordsPresent(in: "see a\u{37E}b and x\u{1FEF}y at 3 \u{212A}elvin", for: nil)
            == ["a;b", "x`y", "kelvin"])
    }

    @Test func aModeCompilingItsStagesDoesNotBlockAnotherModesLookup() {
        let slow = Mode(id: "slow", name: "Slow")
        let fast = Mode(id: "fast", name: "Fast")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let rc = ResolvedConfig(
            modes: [slow, fast], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:],
            onBuildTextStages: { id in
                guard id == "slow" else { return }
                entered.signal()
                release.wait()
            })
        _ = rc.postSTTTextStages(for: fast)

        let building = Thread { _ = rc.postSTTTextStages(for: slow) }
        building.start()
        #expect(entered.wait(timeout: .now() + 2) == .success)

        let lookedUp = DispatchSemaphore(value: 0)
        Thread {
            _ = rc.postSTTTextStages(for: fast)
            _ = rc.recognitionBiasTerms(for: fast)
            _ = rc.mergedDictionary(for: fast)
            lookedUp.signal()
        }.start()
        let unblocked = lookedUp.wait(timeout: .now() + 1) == .success
        release.signal()
        #expect(unblocked)
    }

    @Test func mergedDictionaryUnionsGlobalAndModeWithDedup() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["ChargeBee", "Postgres"])
        let rc = resolved(modes: [mode], dictionary: ["Postgres", "Kubernetes"])
        #expect(rc.mergedDictionary(for: mode) == ["Postgres", "Kubernetes", "ChargeBee"])
    }

    @Test func mergedDictionaryHonorsIncludeGlobalFalse() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: false, words: ["OnlyLocal"])
        let rc = resolved(modes: [mode], dictionary: ["Global"])
        #expect(rc.mergedDictionary(for: mode) == ["OnlyLocal"])
    }

    @Test func nilModeFallsBackToGlobalDictionaryAndDefaultStages() {
        let rc = resolved(dictionary: ["Global"])
        #expect(rc.mergedDictionary(for: nil) == ["Global"])
        let stages = rc.postSTTTextStages(for: nil)
        #expect(stages.count == 3)
    }

    @Test func textStagesReflectModeCommands() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        mode.commands.numbers = true
        let rc = resolved(modes: [mode], dictionary: ["ChargeBee"])
        #expect(rc.postSTTTextStages(for: mode).count == 4)
    }

    @Test func fuzzyStageAppendedOnlyWhenMergedDictionaryNonEmpty() {
        var mode = Mode(id: "m", name: "M")
        mode.commands.liveEdits = true
        let withDict = resolved(modes: [mode], dictionary: ["ChargeBee"])
        #expect(withDict.postSTTTextStages(for: mode).count == 3)
        let empty = resolved(modes: [mode], dictionary: [])
        #expect(empty.postSTTTextStages(for: mode).count == 2)
    }

    @Test func postSTTTextStagesAreMemoizedSameInstanceReused() {
        let mode = Mode(id: "m", name: "M")
        let rc = resolved(modes: [mode], dictionary: ["ChargeBee"])
        let first = rc.postSTTTextStages(for: mode)
        let second = rc.postSTTTextStages(for: mode)
        #expect(first.count == second.count)
    }

    @Test func fragmentBodiesResolveFromFrozenMapDroppingBlanksAndMissing() {
        let rc = resolved(fragments: ["a": "Body A", "b": "", "c": "Body C"])
        #expect(rc.fragmentBodies(ids: ["a", "b", "missing", "c"]) == ["Body A", "Body C"])
    }

    @Test func recognitionBiasTermsTrimWhitespaceAndDropBlanks() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["  Padded  ", "   "])
        let rc = resolved(modes: [mode], dictionary: ["Postgres"])
        #expect(rc.recognitionBiasTerms(for: mode) == ["Postgres", "Padded"])
    }

    @Test func recognitionBiasTermsFallBackToGlobalForNilMode() {
        let rc = resolved(dictionary: ["Global"])
        #expect(rc.recognitionBiasTerms(for: nil) == ["Global"])
    }

    private func withCommands(_ modes: [Mode], dictionary: [String] = []) -> ResolvedConfig {
        ResolvedConfig(
            modes: modes, dictionary: DictionarySet(words: dictionary), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:],
            voiceCommands: VoiceCommandConfig(
                places: [VoiceCommandPlace(name: "Zorblex", say: ["zorb", "Postgres"], target: .app(bundleId: "a"))],
                scripts: [VoiceCommandScript(name: "next unread", say: ["NEXT UNREAD"], run: ["/bin/echo"])]))
    }

    @Test func theVoiceCommandsModeHintsEverySavedCommandNameOnce() {
        let rc = withCommands([Mode.voiceCommands], dictionary: ["Postgres"])
        #expect(rc.recognitionBiasTerms(for: Mode.voiceCommands) == ["Postgres", "Zorblex", "zorb", "next unread"])
    }

    @Test func commandNamesNeverReachOrdinaryDictation() {
        let mode = Mode(id: "m", name: "M")
        let rc = withCommands([mode, Mode.voiceCommands], dictionary: ["Postgres"])
        #expect(rc.recognitionBiasTerms(for: mode) == ["Postgres"])
        #expect(rc.recognitionBiasTerms(for: nil) == ["Postgres"])
        #expect(rc.mergedDictionary(for: Mode.voiceCommands) == ["Postgres"])
    }

    @Test func mergedDictionaryAndBiasShareCache() {
        var mode = Mode(id: "m", name: "M")
        mode.dictionary = Mode.ModeDictionary(includeGlobal: true, words: ["ChargeBee", "Postgres"])
        let rc = resolved(modes: [mode], dictionary: ["Postgres", "Kubernetes"])
        _ = rc.recognitionBiasTerms(for: mode)
        #expect(rc.mergedDictionary(for: mode) == ["Postgres", "Kubernetes", "ChargeBee"])
    }

    @Test func textStagesTagEachRuleWithTheScopeItCameFrom() throws {
        var mode = Mode(id: "code", name: "Code")
        mode.replacements = .init(includeGlobal: true, rules: [.init(heard: "teh", replace: "THE", regex: false)])
        let rc = resolved(modes: [mode], replacements: [
            .init(heard: "Teh", replace: "the", regex: false), .init(heard: "pipe", replace: "|", regex: false),
        ])
        let stage = try #require(rc.postSTTTextStages(for: mode).compactMap { $0 as? ReplacementsStage }.first)
        #expect(stage.rules.map(\.origin) == [.mode("code"), .global])
        #expect(try #require(rc.postSTTTextStages(for: nil).compactMap { $0 as? ReplacementsStage }.first)
            .rules.map(\.origin) == [.global, .global])
    }

    @Test func anAgentAddressReadsThroughTheModesReplacementsAndDictionary() throws {
        var mode = Mode(id: "agent", name: "Agent")
        mode.replacements = .init(includeGlobal: true, rules: [.init(heard: "R Sperco", replace: "rsperko", regex: false)])
        let rc = resolved(modes: [mode], dictionary: ["Kubernetes"], replacements: [
            .init(heard: "Arsperco", replace: "rsperko", regex: false),
        ])
        let read = try #require(rc.agentAddressReader(for: "Tell R Sperco Green to check kabernetas", mode: mode))
        #expect(read("R Sperco Green") == "rsperko Green")
        #expect(read("kabernetas") == "Kubernetes")
    }

    @Test(arguments: [["backend", "backand"], ["backand", "backend"]])
    func theDictionaryNeverPicksBetweenEquallyCloseSessionNames(dictionary: [String]) throws {
        let names = ["backend", "backand"]
        let read = try #require(resolved(dictionary: dictionary).agentAddressReader(for: "Tell backund to stop", mode: nil))
        #expect(AgentAddress.parse("Tell backund to stop", names: names, read: read)
            == AgentAddress.parse("Tell backund to stop", names: names))
    }

    @Test(arguments: [["backend", "backand"], ["backand", "backend"]])
    func theDictionaryNeverPicksBetweenNamesTwoEditsAway(dictionary: [String]) throws {
        let names = ["backend", "backand"]
        let read = try #require(resolved(dictionary: dictionary).agentAddressReader(for: "Tell bickund to stop", mode: nil))
        #expect(read("bickund") != "bickund")
        #expect(AgentAddress.parse("Tell bickund to stop", names: names, read: read)
            == AgentAddress.parse("Tell bickund to stop", names: names))
    }

    nonisolated static let spokenBranches: [(said: String, name: String, body: String)] = [
        ("Tell Ultimate 61 to run the tests.", "ultimate 61", "to run the tests."),
        ("Tell ultimate sixty one to run the tests.", "ultimate 61", "to run the tests."),
        ("Tell ultimate sixty-one to run the tests.", "ultimate 61", "to run the tests."),
        ("Tell Ultimate 6 to run the tests.", "ultimate six", "to run the tests."),
        ("Tell ultimate six to run the tests.", "ultimate six", "to run the tests."),
        ("Tell Ultimate61 to run the tests.", "ultimate 61", "to run the tests."),
        ("Tell Ultimate 14 to run the tests.", "ultimate 14", "to run the tests."),
        ("Tell ultimate fourteen to run the tests.", "ultimate 14", "to run the tests."),
        ("Tell Ultimate 105 to run the tests.", "ultimate 105", "to run the tests."),
        ("Tell ultimate one hundred five to run the tests.", "ultimate 105", "to run the tests."),
        ("Tell ultimate, run the tests.", "ultimate", "run the tests."),
        ("Tell ultimate six more things are broken.", "ultimate six", "more things are broken."),
        ("Tell ultimate one more thing.", "ultimate", "one more thing."),
        ("Tell ultimate 61 tests are failing.", "ultimate 61", "tests are failing."),
        ("Tell ultimate sixty one tests are failing.", "ultimate 61", "tests are failing."),
    ]

    @Test(arguments: spokenBranches)
    func aBranchNumberReachesItsBranchWhetherTheEngineWritesItAsDigitsOrWords(said: String, name: String, body: String) throws {
        let rc = resolved(modes: [Mode.agentMode])
        let read = try #require(rc.agentAddressReader(for: said, mode: Mode.agentMode))
        #expect(AgentAddress.parse(said, names: ["ultimate", "ultimate 6", "ultimate 14", "ultimate 61", "ultimate 105"], read: read) == .name(name, body: body))
    }

    enum Reading: String, Sendable, CaseIterable { case number, replacement, dictionary }
    enum Other: String, Sendable, CaseIterable { case prefix, sibling, unrelated }

    nonisolated static let rivalGrid: [(Reading, Other, Bool)] = Reading.allCases.flatMap { reading in
        Other.allCases.flatMap { other in [true, false].map { (reading, other, $0) } }
    }

    static func rivalCase(_ reading: Reading, _ other: Other, literal: Bool) -> (said: String, mode: Mode, dictionary: [String], names: [String], hit: String) {
        var mode = Mode.agentMode
        var dictionary: [String] = []
        let said: String, hit: String, sibling: String
        switch reading {
        case .number:
            said = "Tell ultimate sixty one to check the pods."
            hit = "ultimate 61"
            sibling = "ultimate six"
        case .replacement:
            mode.replacements = .init(includeGlobal: true, rules: [.init(heard: "cube", replace: "kubernetes", regex: false)])
            said = "Tell ultimate cube to check the pods."
            hit = "ultimate kubernetes"
            sibling = "ultimate cuba"
        case .dictionary:
            dictionary = ["Kubernetes"]
            said = "Tell ultimate kubernetis to check the pods."
            hit = "ultimate kubernetes"
            sibling = "ultimate kubernetic"
        }
        let otherName = switch other {
        case .prefix: "ultimate"
        case .sibling: sibling
        case .unrelated: "docs"
        }
        var names = [hit, otherName]
        if literal, !names.contains("ultimate") { names.append("ultimate") }
        return (said, mode, dictionary, names, hit)
    }

    static func rivalOutcome(_ reading: Reading, _ other: Other, literal: Bool, hit: String) -> AgentAddress {
        let body = "to check the pods."
        guard reading != .number, other == .sibling else { return .name(hit, body: body) }
        let heard = reading == .replacement ? "cube" : "kubernetis"
        let sibling = reading == .replacement ? "ultimate cuba" : "ultimate kubernetic"
        return literal
            ? .name("ultimate", body: "\(heard) \(body)")
            : .ambiguous(spoken: "ultimate", names: [hit, sibling].sorted(), body: "\(heard) \(body)")
    }

    @Test(arguments: rivalGrid)
    func aReadingPicksTheLongerNameUnlessAGuessedCorrectionCouldMeanASiblingToo(reading: Reading, other: Other, literal: Bool) throws {
        let c = Self.rivalCase(reading, other, literal: literal)
        let rc = resolved(modes: [c.mode], dictionary: c.dictionary)
        let read = try #require(rc.agentAddressReader(for: c.said, mode: c.mode))
        #expect(AgentAddress.parse(c.said, names: c.names, read: read) == Self.rivalOutcome(reading, other, literal: literal, hit: c.hit))
    }

    @Test func aCorrectedAddressLeavesALiveEditAfterItInTheMessage() throws {
        let rc = resolved(replacements: [.init(heard: "Arsperco", replace: "rsperko", regex: false)])
        let text = "Tell Arsperco Green insert new line hello"
        let read = try #require(rc.agentAddressReader(for: text, mode: nil))
        #expect(AgentAddress.parse(text, names: ["rsperko green"], read: read)
            == .name("rsperko green", body: "insert new line hello"))
    }

    @Test func aSpanOwnedByALiteralRuleIsStillCorrected() throws {
        let rc = resolved(replacements: [.init(heard: "Arsperco", replace: "rsperko", regex: false)])
        let read = try #require(rc.agentAddressReader(for: "Go to Arsperco Green.", mode: nil))
        #expect(read("Arsperco") == "rsperko")
    }

    @Test func aTakeOwnedByAWholeUtteranceRuleHasNoAddressReader() {
        let rc = resolved(replacements: [.init(heard: "slash resume", replace: "/resume", regex: false)])
        #expect(rc.agentAddressReader(for: "slash resume", mode: nil) == nil)
        #expect(rc.agentAddressReader(for: "tell keyscribe blue slash resume", mode: nil) != nil)
    }
}
