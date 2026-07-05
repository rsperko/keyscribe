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

    // User-mode files only — the system Direct floor (`_direct`) is always seeded, so exclude it.
    private func tomls(in dir: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "toml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix(Mode.systemIdPrefix) })
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
    // external edit to that fragment made just before the add would be swallowed (the watcher would see
    // a stamp the app "wrote" and skip the reload that the real edit needed).
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
        // Baseline AFTER init: model init's reload() seeds _direct.toml, so capture it here — the ONLY
        // delta before the final check must be the external fragment edit, or the test could pass for
        // the wrong reason.
        gate.adopt(ConfigTreeSnapshot.capture(supportDir: support))

        // External editor rewrites the fragment (longer content) without the app recording it.
        try "---\nname: My Voice\n---\nExternally rewritten, much longer body.".write(to: file, atomically: true, encoding: .utf8)
        // User references the SAME fragment by name in-app: no file is written, so no self-write.
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
        #expect(copy.constraints == original.constraints)             // everything else carried over
        #expect(model.selectedID == "email-copy")
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

    // P2-19: replays closeFragmentEditor's ordering. The PromptEditor's 300 ms debounce has NOT fired, so
    // its pending body edit lives only in the flush handle. Flushing before the close lands the body on
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

        flush.flush()                             // closeFragmentEditor's flush() step
        model.closeFragment(id, fromMode: try #require(model.selectedID))

        #expect(model.fragmentIds.contains(id))
        #expect(model.fragmentBody(id) == "keep it terse")
        #expect(model.selected?.aiRewrite?.fragments == [id])
    }

    // The old bug: closing while the body edit is still pending (never flushed) reads an empty body and
    // discards the instruction — this is the regression the flush prevents.
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
