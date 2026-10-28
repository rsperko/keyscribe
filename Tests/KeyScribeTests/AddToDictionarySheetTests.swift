import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct AddToDictionarySheetTests {
    @Test func aNameAlreadyListedOffersToCorrectTheSelectedSpelling() {
        let offer = VocabularyDraftAnalysis.teachableCorrection(
            selected: " Crayton ", term: "Kryten", action: .noChange(.wordAlreadyListed))
        #expect(offer?.heard == "Crayton")
        #expect(offer?.word == "Kryten")
        #expect(VocabularyDraftAnalysis.teachableCorrection(
            selected: "Crayton", term: "Kryten", action: .noChange(.wordCoveredByGlobal))?.heard == "Crayton")
    }

    @Test func noCorrectionIsOfferedWhenThereIsNothingToCorrect() {
        #expect(VocabularyDraftAnalysis.teachableCorrection(selected: "kryten", term: "Kryten", action: .noChange(.wordAlreadyListed)) == nil)
        #expect(VocabularyDraftAnalysis.teachableCorrection(selected: "", term: "Kryten", action: .noChange(.wordAlreadyListed)) == nil)
        #expect(VocabularyDraftAnalysis.teachableCorrection(selected: "Crayton", term: "Kryten", action: .addWord) == nil)
        #expect(VocabularyDraftAnalysis.teachableCorrection(selected: "Crayton", term: "Kryten", action: nil) == nil)
    }
}

@MainActor
struct CorrectionPanelReviewTests {
    private func finder(heard: [String]) -> HistoryReplacementsModel {
        let items = heard.enumerated().map { i, text in
            HistorySnapshot.Item(
                reference: .init(dayFile: "d.jsonl", line: i),
                entry: HistoryEntry(
                    timestamp: Date(timeIntervalSince1970: 1_000_000), modeName: "Plain Dictation", heard: text,
                    result: text, outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: []))
        }
        let snapshot = HistorySnapshot(
            items: items, unreadableLines: 0, fingerprint: HistorySnapshot.Fingerprint(files: ["d.jsonl": items.count]))
        return HistoryReplacementsModel(
            word: "Kryten", destination: .global, destinationName: "Global", historyEnabled: true,
            dependencies: .init(
                loadSnapshot: { snapshot }, fingerprint: { snapshot.fingerprint },
                vocabulary: { .init(global: ReplacementsSet(), globalWords: ["Kryten"], modes: []) },
                save: { _, _, _, _ in .saved }),
            onSaved: { _ in })
    }

    @Test func aNewWordOpensTheReviewOnlyWhenHistoryHasLikelyMishearings() async {
        #expect(await CorrectionPanelController.reviewWorthShowing(finder(heard: ["Ask Cryden for help"])) != nil)
        #expect(await CorrectionPanelController.reviewWorthShowing(finder(heard: ["nothing like it"])) == nil)
    }
}
