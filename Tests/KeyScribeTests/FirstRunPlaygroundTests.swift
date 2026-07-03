import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct FirstRunPlaygroundTests {
    private func connectedModel() async -> (FirstRunModel, URL) {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-playground-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        ModeStore.seedStartersIfEmpty(in: modesDir)
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in },
            selectEngine: { _ in },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            saveAPIKey: { _, _ in true },
            testConnection: { _ in .passed },
            listModels: { _, _ in [] },
            onComplete: {})
        model.aiServiceName = "Gemini Flash"
        model.aiProvider = .gemini
        model.aiModel = "gemini-2.5-flash"
        model.aiAPIKey = "secret"
        await model.createAIService()
        return (model, supportDir)
    }

    @Test func enteringPlaygroundBuildsDictationThenConnectedRewriteLessons() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }

        model.enterPlayground()

        #expect(model.step == .playground)
        #expect(model.playgroundLessons.map(\.modeId) == [Mode.directId, "polish", "edit-selection"])
        let dictation = model.playgroundLessons.first { $0.modeId == Mode.directId }
        #expect(dictation?.title == "Dictation")
        let polish = model.playgroundLessons.first { $0.modeId == "polish" }
        #expect(polish?.invocation.contains("⌥") == true)
        let selection = model.playgroundLessons.first { $0.modeId == "edit-selection" }
        #expect(selection?.invocation.contains("⌘") == true)
    }

    @Test func aLessonMarksCompleteWithItsBeforeAndAfterOnAnInsertedDictation() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()

        model.noteDictation(DictationCompletion(
            outcome: .inserted, modeId: "polish",
            heard: "um so like send the report", finalText: "Send the report."))

        let done = model.completedLessons["polish"]
        #expect(done?.before == "um so like send the report")
        #expect(done?.after == "Send the report.")
        #expect(model.completedLessons[Mode.directId] == nil)
    }

    @Test func directDictationCompletesTheDictationLesson() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()

        model.noteDictation(DictationCompletion(
            outcome: .inserted, modeId: Mode.directId, heard: "plain words", finalText: "Plain words"))

        let done = model.completedLessons[Mode.directId]
        #expect(done?.before == "plain words")
        #expect(done?.after == "Plain words")
        #expect(model.finishedPlaygroundLessonIds.contains(Mode.directId))
    }

    @Test func advancingALessonMarksItFinished() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()
        model.openPlaygroundLesson("polish")

        model.advancePlayground()

        #expect(model.finishedPlaygroundLessonIds.contains("polish"))
        #expect(model.activePlaygroundLessonId == "edit-selection")
    }

    @Test func finalLessonIsDetectedAsLastLesson() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()

        #expect(model.isLastPlaygroundLesson("edit-selection"))
        #expect(!model.isLastPlaygroundLesson("polish"))
    }

    @Test func openingEditSelectionSeedsSimpleSelectableText() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()
        model.playgroundText = ""

        model.openPlaygroundLesson("edit-selection")

        #expect(model.playgroundText == "We need to review the long meeting notes, identify the open questions, and decide the next steps before Friday.")
    }

    @Test func reopeningEditSelectionReseedsAndReselectsAfterAnEdit() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()
        model.openPlaygroundLesson("edit-selection")
        let seedToken = model.playgroundReseedToken
        model.playgroundText = "Shortened."

        model.openPlaygroundLesson("edit-selection")

        #expect(model.playgroundText == "We need to review the long meeting notes, identify the open questions, and decide the next steps before Friday.")
        #expect(model.playgroundReseedToken > seedToken)
    }

    @Test func aFailedDictationDoesNotRecordALesson() async {
        let (model, supportDir) = await connectedModel()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        model.enterPlayground()

        model.noteDictation(DictationCompletion(
            outcome: .failed, modeId: "polish", heard: "x", finalText: ""))

        #expect(model.completedLessons.isEmpty)
    }

    @Test func enteringPlaygroundWithNoConnectedLessonsFinishesInstead() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-playground-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStartersIfEmpty(in: modesDir)
        var completed = 0
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in },
            selectEngine: { _ in },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: { completed += 1 })

        model.enterPlayground()

        #expect(model.step != .playground)
        #expect(completed == 1)
    }

    @Test func skippingAISetupShowsTheBasicDictationTrial() {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-playground-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        var completed = 0
        let model = FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: { _, _ in },
            selectEngine: { _ in },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: { completed += 1 })

        model.skipAISetup()

        #expect(model.step == .tryIt)
        #expect(completed == 0)
    }
}
