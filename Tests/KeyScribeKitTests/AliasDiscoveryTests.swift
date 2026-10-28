import Testing
@testable import KeyScribeKit

private func phrases(_ texts: [String], _ target: String, dictionary: [String] = []) -> [String] {
    AliasDiscovery.find(target: target, in: texts, dictionary: dictionary).map(\.phrase)
}

struct AliasDiscoveryTests {
    @Test func findsMisspellingsSplitsAndRespellingsOfTheTarget() {
        #expect(phrases(["We store the orders in Ugabyte."], "Yugabyte") == ["Ugabyte"])
        #expect(phrases(["I prefer Yuga Bite over Postgres for this."], "Yugabyte") == ["Yuga Bite"])
        #expect(phrases(["The UGBte cluster is down again."], "Yugabyte") == ["UGBte"])
        #expect(phrases(["Load the Quinn model first."], "Qwen") == ["Quinn"])
        #expect(phrases(["Sign the jot before sending it."], "JWT") == ["jot"])
        #expect(phrases(["Ask Sophia about the release."], "Sofia") == ["Sophia"])
        #expect(phrases(["The patient presented with tachardia."], "tachycardia") == ["tachardia"])
    }

    @Test func aSpellingFarOffButWithTheSameConsonantsAsTheNameIsFound() {
        let texts = ["Croydon, create a pane for me", "Cryden, pair with me", "Crayton, open it"]
        #expect(Set(phrases(texts, "Kryten")) == ["Croydon", "Cryden", "Crayton"])
    }

    @Test func sameConsonantsAloneDoNotFlagAWordThatSoundsDifferent() {
        #expect(phrases(["The courtyard is quiet."], "Kryten").isEmpty)
        #expect(phrases(["Order a crate and a tin."], "Kryten").isEmpty)
    }

    @Test func soundAlikesBuiltFromDifferentWordsAreOutOfReach() {
        #expect(phrases(["I expect you to fight for this."], "Yugabyte").isEmpty)
        #expect(phrases(["Pull the masks over the cluster."], "Postgres").isEmpty)
    }

    @Test func neverSuggestsTheTargetItselfInAnyCasingOrSpacing() {
        #expect(phrases(["Yugabyte is fast, yugabyte scales, and Yuga byte replicates."], "Yugabyte").isEmpty)
    }

    @Test func aCorrectMentionDoesNotHideAMisheardOne() {
        #expect(phrases(["We use Yugabyte, but the Yuga Bite cluster needs attention."], "Yugabyte") == ["Yuga Bite"])
    }

    @Test func findsEveryDifferentMissInOneDictation() {
        let found = phrases(["Yuga Bite handles the writes, while the Gugabyte cluster serves reads."], "Yugabyte")
        #expect(Set(found) == ["Yuga Bite", "Gugabyte"])
    }

    @Test func skipsOtherDictionaryWordsAndPhrasesContainingTheTarget() {
        #expect(phrases(["Bias it with WhisperKit."], "Whisper", dictionary: ["WhisperKit"]).isEmpty)
        #expect(!phrases(["Turn on the Whisper bias."], "Whisper").contains { $0.contains("Whisper") })
    }

    @Test func neverSpansAPlaceholderOrInteriorPunctuation() {
        let text = "Send the Yuga Bite report to ⟦SN:REDACT:1⟧."
        let findings = AliasDiscovery.find(target: "Yugabyte", in: [text])
        #expect(findings.map(\.phrase) == ["Yuga Bite"])
        #expect(!phrases(["Yuga, bite the bullet."], "Yugabyte").contains { $0.contains(",") })
    }

    @Test func rangesPointAtTheOriginalTextPastUnicode() throws {
        let text = "Café — déjà vu: Ugabyte!"
        let finding = try #require(AliasDiscovery.find(target: "Yugabyte", in: [text]).first)
        let occurrence = try #require(finding.occurrences.first)
        #expect(text[occurrence.range] == "Ugabyte")
    }

    @Test func groupsCaseInsensitivelyAndKeepsEveryOccurrence() throws {
        let texts = ["Ugabyte is down.", "Ugabyte is down.", "restart ugabyte, then Ugabyte again"]
        let findings = AliasDiscovery.find(target: "Yugabyte", in: texts)
        let finding = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(finding.phrase == "Ugabyte")
        #expect(finding.occurrences.map(\.entry) == [0, 1, 2, 2])
    }

    @Test func occurrencesInOneDictationNeverOverlap() {
        let text = "Can you check the Yuga by DB logs?"
        let ranges = AliasDiscovery.find(target: "Yugabyte", in: [text]).flatMap(\.occurrences).map(\.range)
        #expect(!ranges.isEmpty)
        for (i, a) in ranges.enumerated() {
            for b in ranges[(i + 1)...] { #expect(!a.overlaps(b)) }
        }
    }

    @Test func ordersByClosenessBeforeFrequency() {
        let texts = Array(repeating: "when is it ready", count: 5) + ["Quen ships today"]
        let found = phrases(texts, "Qwen")
        #expect(found.first == "Quen")
    }

    @Test func comparesNonLatinTextBySpelling() {
        #expect(phrases(["мы в Масква"], "Москва") == ["Масква"])
    }

    @Test func ranksTheRealMissAboveACompetingWord() {
        #expect(AliasDiscovery.score("ugabyte", target: "yugabyte") > AliasDiscovery.score("gigabyte", target: "yugabyte"))
        #expect(AliasDiscovery.score("youtofight", target: "yugabyte") < AliasDiscovery.defaultThreshold)
    }
}
