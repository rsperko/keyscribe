import Testing
@testable import KeyScribeKit

private typealias Eval = AliasDiscoveryEvaluation

private func labelTexts(_ heard: String, _ reference: String, _ term: String) -> [String] {
    Eval.labels(heard: heard, reference: reference, term: term).map { label in
        switch label {
        case .miss(let range): "miss:\(heard[range])"
        case .exact(let range): "exact:\(heard[range])"
        case .omitted: "omitted"
        }
    }
}

struct AliasDiscoveryEvaluationTests {
    @Test func labelsAMisheardTermByAligningHeardToReference() {
        #expect(labelTexts("We store the orders in Ugabyte.", "We store the orders in Yugabyte.", "Yugabyte")
            == ["miss:Ugabyte"])
        #expect(labelTexts("The Yuga Bite cluster is down.", "The Yugabyte cluster is down.", "Yugabyte")
            == ["miss:Yuga Bite"])
    }

    @Test func labelsCorrectSpellingsAndSplitsAsExact() {
        #expect(labelTexts("Migrate to YugaByte now.", "Migrate to Yugabyte now.", "Yugabyte") == ["exact:YugaByte"])
        #expect(labelTexts("Migrate to Yuga byte now.", "Migrate to Yugabyte now.", "Yugabyte") == ["exact:Yuga byte"])
    }

    @Test func labelsEveryMentionIndependently() {
        #expect(labelTexts(
            "We use Yugabyte, but the Ugabyte cluster is slow.",
            "We use Yugabyte, but the Yugabyte cluster is slow.", "Yugabyte") == ["exact:Yugabyte", "miss:Ugabyte"])
    }

    @Test func labelsADroppedTermAsOmitted() {
        #expect(labelTexts("Migrate the table before Friday.", "Migrate the table to Yugabyte before Friday.", "Yugabyte")
            == ["omitted"])
    }

    @Test func aReferenceWithoutTheTermHasNoLabels() {
        #expect(labelTexts("The lava flows.", "The lava flows.", "Java").isEmpty)
    }

    @Test func scoresRecallWrongSuggestionsAndRanking() {
        let records = [
            Eval.Record(heard: "We store the orders in Ugabyte.", reference: "We store the orders in Yugabyte.",
                        dictionary: ["Yugabyte"]),
            Eval.Record(heard: "I expect you to fight for this.", reference: "I expect Yugabyte for this.",
                        dictionary: ["Yugabyte"]),
            Eval.Record(heard: "Leave a gigabyte free.", reference: "Leave a gigabyte free.", dictionary: ["Yugabyte"]),
            Eval.Record(heard: "Nothing related here.", reference: "Nothing related here.", dictionary: ["Yugabyte"]),
        ]
        let summary = Eval.evaluate(records: records, terms: ["Yugabyte"])
        #expect(summary.occurrences == 2)
        #expect(summary.occurrencesFound == 1)
        #expect(summary.forms == 2)
        #expect(summary.formsFound == 1)
        #expect(summary.negativeRecords == 2)
        #expect(summary.wrongSuggestions == 1)
        #expect(summary.wrongGroups == 1)
        #expect(summary.topThreeHits == 1)
        #expect(summary.topThreeSlots == 2)
        #expect(summary.terms.first?.missedForms == ["you to fight"])
    }

    @Test func topThreePrecisionCountsATermWhoseSuggestionsAreAllWrong() {
        let records = [
            Eval.Record(heard: "Leave a gigabyte free.", reference: "Leave a gigabyte free.", dictionary: ["Yugabyte"]),
        ]
        let summary = Eval.evaluate(records: records, terms: ["Yugabyte"])
        #expect(summary.wrongGroups == 1)
        #expect(summary.topThreeHits == 0)
        #expect(summary.topThreeSlots == 1)
    }
}
