import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VocabularyPaneNoticeTests {
    private let broken = "schema_version = 1\n[[rules]\nheard = \"teh\"\n"

    private func makeSupport() throws -> (ConfigRepository, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vocab-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support)), support)
    }

    @Test func anUnreadableReplacementsFileIsNoticedBeforeAnyEdit() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try broken.write(to: support.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)

        let model = ReplacementsSettingsModel(repository: repository)

        #expect(model.notice?.title == "replacements.toml needs fixing")
        #expect(model.notice?.message.hasSuffix("Global replacements can’t be shown or changed here until then.") == true)
    }

    @Test func aFailedAddSaysWhatFailedLeavesTheFileAndCanBeRetriedAfterARepair() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let url = support.appendingPathComponent(ReplacementsStore.fileName)
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let model = ReplacementsSettingsModel(repository: repository)

        #expect(!model.add(heard: "recieve", replace: "receive", regex: false))
        let notice = try #require(model.notice)
        #expect(notice.title == "Replacement wasn’t saved")
        #expect(notice.message.hasPrefix("replacements.toml needs fixing."))
        #expect(!notice.message.contains("still working"))
        #expect(!notice.message.contains("ConfigError"))
        #expect(notice.fileURL == url)
        #expect(notice.details?.contains("Line ") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)

        try ReplacementsStore.write(ReplacementsSet(), to: support)
        model.reload()
        #expect(model.notice == nil)
        #expect(model.add(heard: "recieve", replace: "receive", regex: false))
        #expect(model.rules.map(\.heard) == ["recieve"])
    }

    @Test func aReloadWhileTheFileIsStillBrokenKeepsTheFailedOperation() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try broken.write(to: support.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        let model = ReplacementsSettingsModel(repository: repository)
        _ = model.add(heard: "recieve", replace: "receive", regex: false)

        model.reload()

        #expect(model.notice?.title == "Replacement wasn’t saved")
    }

    @Test func anUpdateThatCouldNotBeSavedReportsNoChange() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let rule = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        try ReplacementsStore.write(ReplacementsSet(rules: [rule]), to: support)
        let model = ReplacementsSettingsModel(repository: repository)
        try broken.write(to: support.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)

        #expect(!model.update(rule, to: .init(heard: "teh", replace: "THE", regex: false)))
        #expect(model.notice?.title == "Change wasn’t saved")
    }

    @Test func aFailedWordAddNamesTheWord() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try "schema_version = 1\nwords = [\n".write(
            to: support.appendingPathComponent(DictionaryStore.fileName), atomically: true, encoding: .utf8)
        let model = DictionarySettingsModel(repository: repository)

        #expect(!model.add("Kubernetes"))
        #expect(model.notice?.title == "“Kubernetes” wasn’t added")
    }

    @Test func aRetryAfterARepairClearsEveryNoticeWithoutWaitingForAReload() throws {
        let (repository, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try broken.write(to: support.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        let model = ReplacementsSettingsModel(repository: repository)
        _ = model.add(heard: "recieve", replace: "receive", regex: false)

        try ReplacementsStore.write(ReplacementsSet(), to: support)
        #expect(model.add(heard: "recieve", replace: "receive", regex: false))

        #expect(model.notice == nil)
    }

    @Test func aFailedWriteSurvivesAReloadThatCanStillReadTheFile() throws {
        let (repository, support) = try makeSupport()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: support)
        }
        try ReplacementsStore.write(ReplacementsSet(), to: support)
        let model = ReplacementsSettingsModel(repository: repository)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)

        #expect(!model.add(heard: "recieve", replace: "receive", regex: false))
        model.reload()

        #expect(model.notice?.title == "Replacement wasn’t saved")
    }

    @Test func existingEntriesAreSaidToWorkOnlyWhenTheAppStillHasThem() throws {
        let (_, support) = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try ReplacementsStore.write(ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)]), to: support)
        let cache = ConfigCache(supportDir: support)
        let tracked = ConfigRepository(supportDir: support, config: cache)
        _ = cache.replacements
        try broken.write(to: support.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        cache.invalidate()
        let model = ReplacementsSettingsModel(repository: tracked)

        #expect(!model.add(heard: "recieve", replace: "receive", regex: false))

        #expect(model.notice?.message == "replacements.toml needs fixing. Your existing replacements are still working.")
    }
}
