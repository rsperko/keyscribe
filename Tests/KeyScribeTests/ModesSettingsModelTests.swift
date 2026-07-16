import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct ModesSettingsModelTests {
    private func makeModel() throws -> (ModesSettingsModel, URL, URL) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-modes-\(UUID().uuidString)")
        let modesDir = support.appendingPathComponent("modes")
        try fm.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("fragments"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return (ModesSettingsModel(repository: repository), support, modesDir)
    }

    // Excludes the system Direct floor (`_direct`), which is always seeded.
    private func tomls(in dir: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "toml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix(Mode.systemIdPrefix) })
    }

    // A ghost ledger entry would mark a mode as materialized when it isn't on disk, so the one-shot
    // seed migration would never re-run for it — a failed save must not record one.
    @Test func aTemplateThatFailsToSaveRecordsNoSeedLedgerEntry() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }
        let template = try #require(ModeStore.templates().first)

        // Forces the write to fail: a directory sits where the mode's .toml must be written.
        try FileManager.default.createDirectory(
            at: modesDir.appendingPathComponent("\(template.id).toml"), withIntermediateDirectories: true)

        model.materializeTemplate(template.id)

        #expect(model.selectedID != template.id)   // never persisted, so never selected
        let ledger = ModeStore.loadLedger(in: support.appendingPathComponent("lkg", isDirectory: true))
        #expect(ledger?.contains(template.id) != true)
    }

    @Test func namingAFreshModeReslugsTheFile() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        #expect(tomls(in: modesDir) == ["new-mode"])

        var renamed = try #require(model.selected)
        renamed.name = "Email Reply"
        model.update(renamed)

        #expect(tomls(in: modesDir) == ["email-reply"])
        #expect(model.modes.filter { !$0.isSystem }.map(\.id) == ["email-reply"])
        #expect(model.selectedID == "email-reply")
        #expect(model.selected?.name == "Email Reply")
    }

    // Adding an EXISTING fragment by name writes nothing, so it must not record a self-write — else an
    // external edit made just before the add would be swallowed (the watcher would see a stamp the app
    // "wrote" and skip the reload the real edit needed).
    @Test func addingAnExistingFragmentByNameDoesNotSwallowAnExternalEdit() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-frag-\(UUID().uuidString)")
        let fragments = support.appendingPathComponent("fragments")
        try fm.createDirectory(at: fragments, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: support) }
        let file = fragments.appendingPathComponent("my-voice.md")
        try "---\nname: My Voice\n---\nOriginal.".write(to: file, atomically: true, encoding: .utf8)

        let gate = ConfigSelfWriteGate()
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support), selfWriteGate: gate)
        let model = ModesSettingsModel(repository: repository)
        // Baseline must be taken AFTER init, since init's reload() seeds _direct.toml — otherwise the
        // delta below wouldn't isolate the external fragment edit, and the test could pass for the wrong reason.
        gate.adopt(ConfigTreeSnapshot.capture(supportDir: support))

        try "---\nname: My Voice\n---\nExternally rewritten, much longer body.".write(to: file, atomically: true, encoding: .utf8)
        _ = model.addFragmentFile(named: "My Voice")

        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: support)) == true)
    }

    @Test func renamingAfterInitialNamingDoesNotReslug() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var first = try #require(model.selected)
        first.name = "Email"
        model.update(first)
        #expect(tomls(in: modesDir) == ["email"])

        var second = try #require(model.selected)
        second.name = "Slack Reply"
        model.update(second)

        #expect(tomls(in: modesDir) == ["email"])
        #expect(model.selected?.name == "Slack Reply")
        #expect(model.selectedID == "email")
    }

    @Test func editingOtherFieldsBeforeNamingKeepsReslugPending() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var toggled = try #require(model.selected)
        toggled.enabled = false
        model.update(toggled)
        #expect(tomls(in: modesDir) == ["new-mode"])

        var named = try #require(model.selected)
        named.name = "Notes"
        model.update(named)

        #expect(tomls(in: modesDir) == ["notes"])
        #expect(model.selected?.enabled == false)
    }

    @Test func duplicateCopiesAModeWithANewIdClearedTriggerAndNoSeedIdentity() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var email = try #require(model.selected)
        email.name = "Email"
        email.seedId = "email"
        email.triggerKeys = [Mode.TriggerKey(key: "right_option")]
        email.constraints = [Mode.Constraint(bundleId: "com.apple.mail")]
        model.update(email)
        let original = try #require(model.modes.first { $0.id == "email" })

        model.duplicate(original)

        #expect(tomls(in: modesDir) == ["email", "email-copy"])
        let copy = try #require(model.modes.first { $0.id == "email-copy" })
        #expect(copy.name == "Email copy")
        #expect(copy.seedId == nil)
        #expect(copy.triggerKeys.isEmpty)                              // no shortcut clash with the original
        #expect(copy.constraints == original.constraints)
        #expect(model.selectedID == "email-copy")
    }

    // The Start-from-a-Template chooser always shows the full catalog, even after every template has
    // been materialized, so a user can add any template again.
    @Test func templatesStayAvailableAfterMaterialization() throws {
        let (model, support, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        #expect(model.allTemplates.map(\.id) == ModeStore.templates().map(\.id))

        for id in ModeStore.templates().map(\.id) { model.materializeTemplate(id) }

        #expect(model.allTemplates.map(\.id) == ModeStore.templates().map(\.id))
    }

    @Test func materializingATemplateWritesADisabledSeedAndSelectsIt() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.materializeTemplate("polish")

        #expect(tomls(in: modesDir) == ["polish"])
        let polish = try #require(model.modes.first { $0.id == "polish" })
        #expect(polish.seedId == "polish")
        #expect(polish.enabled == false)   // added Disabled; user enables after reviewing the seeded editor
        #expect(model.selectedID == "polish")
        // A real fingerprint means this entry participates in future seed updates.
        let ledger = ModeStore.loadLedger(in: support.appendingPathComponent("lkg", isDirectory: true))
        #expect(ledger?.entry("polish")?.fingerprint != nil)
    }

    @Test func createWithConnectionWritesAModeCarryingTheConnectionAndSelectsIt() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.createWithConnection(connectionId: "fast")

        #expect(tomls(in: modesDir) == ["new-mode"])
        let created = try #require(model.modes.first { $0.id == "new-mode" })
        #expect(created.aiRewrite?.connection == "fast")
        #expect(created.enabled == false)   // disabled until configured — no silent cloud rewrite
        #expect(model.selectedID == "new-mode")
    }

    @Test func materializingATemplateRepeatedlyYieldsDistinctSeedlessCopies() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.materializeTemplate("email")
        model.materializeTemplate("email")
        model.materializeTemplate("email")

        #expect(tomls(in: modesDir) == ["email", "email-2", "email-3"])

        let first = try #require(model.modes.first { $0.id == "email" })
        #expect(first.name == "Email")
        #expect(first.seedId == "email")
        #expect(first.seedVersion != nil)

        let second = try #require(model.modes.first { $0.id == "email-2" })
        #expect(second.name == "Email 2")
        #expect(second.seedId == nil)
        #expect(second.seedVersion == nil)

        let third = try #require(model.modes.first { $0.id == "email-3" })
        #expect(third.name == "Email 3")
        #expect(third.seedId == nil)
        #expect(third.seedVersion == nil)

        #expect(model.selectedID == "email-3")
    }

    @Test func duplicateRefusesTheSystemDirectFloor() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.duplicate(.direct)
        #expect(tomls(in: modesDir).isEmpty)
    }

    @Test func reslugDedupesAgainstAnExistingMode() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var first = try #require(model.selected)
        first.name = "Email"
        model.update(first)

        model.create()
        var second = try #require(model.selected)
        second.name = "Email"
        model.update(second)

        #expect(tomls(in: modesDir) == ["email", "email-2"])
        #expect(model.selectedID == "email-2")
    }

    @Test func flushHandleRunsThePendingCommit() {
        let flush = PromptEditorFlush()
        var ran = 0
        flush.commit = { ran += 1 }
        flush.flush()
        #expect(ran == 1)
    }

    // Replays closeFragmentEditor's ordering. The PromptEditor's 300 ms debounce has NOT fired, so its
    // pending body edit lives only in the flush handle; flushing before the close lands the body on
    // disk, so closeFragment's empty-check keeps the instruction instead of discarding it.
    @Test func flushingBeforeCloseSavesTheStillPendingBodyAndKeepsTheInstruction() throws {
        let (model, support, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        let id = try #require(model.addFragmentFile(named: "My Voice"))
        var mode = try #require(model.selected)
        mode.aiRewrite = .init(connection: "", prompt: "p", fragments: [id])
        model.update(mode)

        let flush = PromptEditorFlush()
        flush.commit = { model.saveFragmentBody(id, "keep it terse") }
        #expect(model.fragmentBody(id).isEmpty)   // debounce not fired: nothing on disk yet

        flush.flush()
        model.closeFragment(id, fromMode: try #require(model.selectedID))

        #expect(model.fragmentIds.contains(id))
        #expect(model.fragmentBody(id) == "keep it terse")
        #expect(model.selected?.aiRewrite?.fragments == [id])
    }

    // Regression: closing while the body edit is still pending (never flushed) used to read an empty
    // body and discard the instruction — this is what the flush in the test above prevents.
    @Test func closingWithoutFlushingAPendingBodyDiscardsAndDetachesIt() throws {
        let (model, support, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        let id = try #require(model.addFragmentFile(named: "Empty"))
        var mode = try #require(model.selected)
        mode.aiRewrite = .init(connection: "", prompt: "p", fragments: [id])
        model.update(mode)

        model.closeFragment(id, fromMode: try #require(model.selectedID))

        #expect(!model.fragmentIds.contains(id))
        #expect(model.selected?.aiRewrite?.fragments == [])
    }
}
