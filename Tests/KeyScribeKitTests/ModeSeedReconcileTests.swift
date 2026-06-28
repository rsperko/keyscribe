import Foundation
import Testing
@testable import KeyScribeKit

struct ModeSeedReconcileTests {
    private func tempDirs() -> (support: URL, modes: URL, ledger: URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-reconcile-\(UUID().uuidString)", isDirectory: true)
        return (support,
                support.appendingPathComponent("modes", isDirectory: true),
                support.appendingPathComponent("lkg", isDirectory: true))
    }

    // Build a legacy on-disk file by taking the new catalog seed for `newId` and stamping the old
    // identity onto it (so an unedited old install is byte-shaped like the catalog modulo identity).
    private func writeLegacy(
        newId: String, oldId: String, oldName: String,
        connection: String = "", enabled: Bool = true, editPrompt: Bool = false, to modesDir: URL
    ) throws {
        var mode = try #require(ModeStore.starterModes().first { $0.id == newId })
        mode.id = oldId
        mode.seedId = oldId
        mode.name = oldName
        mode.enabled = enabled
        mode.aiRewrite?.connection = connection
        if editPrompt { mode.aiRewrite?.prompt = "totally custom prompt the user wrote" }
        try ModeStore.write(mode, to: modesDir)
    }

    @Test func freshSeedWritesLedgerThenReconcileIsANoOp() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)

        let ledger = try #require(ModeStore.loadLedger(in: d.ledger))
        #expect(Set(ledger.entries.map(\.seedId)) == Set(ModeStore.starterModes().map(\.id)))
        #expect(ledger.entries.allSatisfy { $0.fingerprint != nil })

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.isEmpty)
        #expect(ModeStore.loadAll(in: d.modes).count == 9)
    }

    @Test func renamesUneditedSeedPreservingConnectionAndEnabled() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "polish", oldId: "polished-dictation", oldName: "Polished Dictation",
                        connection: "conn-1", enabled: true, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.renamed.contains("polish"))

        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("polished-dictation.toml").path))
        let polish = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        #expect(polish.name == "Polish")
        #expect(polish.seedId == "polish")
        #expect(polish.aiRewrite?.connection == "conn-1")
        #expect(polish.enabled == true)
    }

    @Test func editedRenameSeedIsLeftAtItsOldIdentity() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "polish", oldId: "polished-dictation", oldName: "Polished Dictation",
                        editPrompt: true, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(!outcome.renamed.contains("polish"))
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("polished-dictation.toml").path))
        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("polish.toml").path))
    }

    @Test func additiveAddsGenuinelyNewCatalogMode() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        // A minimal existing install: only plain-dictation survives. No ledger (pre-ledger install).
        let plain = try #require(ModeStore.starterModes().first { $0.id == "plain-dictation" })
        try ModeStore.write(plain, to: d.modes)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("code.toml").path))
    }

    @Test func preLedgerDeletedModesAreNotResurrected() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        // Existing install that kept only plain-dictation (everything else deleted under the old build).
        let plain = try #require(ModeStore.starterModes().first { $0.id == "plain-dictation" })
        try ModeStore.write(plain, to: d.modes)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        for resurrected in ["markdown", "shell", "message", "email"] {
            #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("\(resurrected).toml").path))
        }
    }

    @Test func renameDoesNotCreateADuplicateForAnEditedOldFile() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "ai-prompt", oldId: "prompt", oldName: "AI Prompt",
                        editPrompt: true, to: d.modes)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        // The edited old file stays; additive must NOT seed a second "ai-prompt" alongside it.
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("prompt.toml").path))
        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("ai-prompt.toml").path))
    }

    @Test func defaultModeIdFollowsARename() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "edit-selection", oldId: "work-on-selection", oldName: "Work on Selection",
                        to: d.modes)
        var settings = Settings.defaults
        settings.defaultModeId = "work-on-selection"
        try SettingsStore.write(settings, to: d.support)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        let loaded = try SettingsStore.loadOrCreate(supportDir: d.support)
        #expect(loaded.defaultModeId == "edit-selection")
    }

    // A copy of the real catalog with one starter's prompt rewritten and its seed_version bumped —
    // the exact change a contributor makes when revising a seed (config_schema.md seed reconcile).
    private func catalog(bumping id: String, prompt: String, to version: Int) -> [Mode] {
        ModeStore.starterModes().map { mode in
            guard mode.id == id else { return mode }
            var revised = mode
            revised.aiRewrite?.prompt = prompt
            revised.seedVersion = version
            return revised
        }
    }

    @Test func versionBumpRefreshesAnUneditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)

        let v2 = catalog(bumping: "message", prompt: "revised message prompt", to: 2)
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: v2)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(ModeStore.loadLedger(in: d.ledger)?.entry("message")?.version == 2)
    }

    // The headline guarantee: a starter the user connected (and onboarding enabled) is NOT shielded from
    // a silent update by its own connection/enable write. Pre-fix this regressed — onboarding's rewrite
    // changed the file's raw bytes, the seed-time fingerprint no longer matched, and the update was
    // skipped forever for exactly the starters most users keep (polish/message/email/edit-selection).
    @Test func versionBumpRefreshesAConnectedSeedPreservingConnectionAndEnabled() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)
        // Simulate FirstRunController.connectStarterModes: attach a connection + enable.
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.connection = "conn-1"
        message.enabled = true
        try ModeStore.write(message, to: d.modes)

        let v2 = catalog(bumping: "message", prompt: "revised message prompt", to: 2)
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: v2)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(after.aiRewrite?.connection == "conn-1")
        #expect(after.enabled == true)
    }

    @Test func versionBumpSkipsAnEditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)
        // The user edited message.toml — its template no longer matches, so the update must skip it.
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.prompt = "my own message prompt"
        try ModeStore.write(message, to: d.modes)

        let v2 = catalog(bumping: "message", prompt: "revised message prompt", to: 2)
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: v2)

        #expect(!outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "my own message prompt")
    }

    // A pre-fix install carries a raw-byte fingerprint in its ledger; reconcile must re-baseline it to a
    // template fingerprint so the very next version bump is not silently missed.
    @Test func reconcileReBaselinesALegacyFingerprintForAConnectedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.connection = "conn-1"
        message.enabled = true
        try ModeStore.write(message, to: d.modes)
        // Stale fingerprint, as a pre-fix install (or a post-onboarding drift) would hold.
        var ledger = try #require(ModeStore.loadLedger(in: d.ledger))
        let i = try #require(ledger.entries.firstIndex { $0.seedId == "message" })
        ledger.entries[i].fingerprint = "deadbeef"
        ModeStore.saveLedger(ledger, in: d.ledger)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        let healed = try #require(ModeStore.loadLedger(in: d.ledger)?.entry("message")?.fingerprint)
        #expect(healed == ModeStore.seedTemplateFingerprint(message))
    }

    // Discipline tripwire (config_schema.md seed reconcile): pins each starter's (seed_version, template
    // fingerprint). Changing a starter's template (prompt, fragments, shape) flips its fingerprint and
    // fails this test ON PURPOSE — the fix is to BUMP that starter's seed_version in starterModes() and
    // update its entry here. The version bump is the only thing that carries the revision to existing
    // installs (reconcileSeeds step 3); without it the change ships but no one already running receives
    // it. The connection/enabled user-knobs are excluded, so onboarding never trips this.
    @Test func revisingAStarterTemplateRequiresAVersionBump() throws {
        let pinned: [String: (version: Int, fingerprint: String)] = [
            "plain-dictation": (1, "33c1c108ae0c08f2"),
            "polish": (1, "9627d08e9098ec1e"),
            "message": (1, "9975c76120898009"),
            "email": (1, "5022830f085e4508"),
            "edit-selection": (1, "9f949cdaf462f4e6"),
            "ai-prompt": (1, "f6e8880e163379b3"),
            "code": (1, "89e8d9dd1fa90de6"),
            "markdown": (1, "bebc8b4e4f506f1"),
            "shell": (1, "24b3cce80e1b4b86"),
        ]
        let catalog = ModeStore.starterModes()
        #expect(Set(catalog.map(\.id)) == Set(pinned.keys),
                "starter catalog ids changed — add/remove the matching pinned entry")
        for mode in catalog {
            let snap = try #require(pinned[mode.id], "no pinned snapshot for starter '\(mode.id)'")
            #expect(mode.seedVersion == snap.version, "starter '\(mode.id)' seed_version != pinned \(snap.version)")
            #expect(ModeStore.seedTemplateFingerprint(mode) == snap.fingerprint,
                    "starter '\(mode.id)' template changed — bump its seed_version in starterModes() and update this snapshot")
        }
    }

    @Test func reconcileIsIdempotent() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "polish", oldId: "polished-dictation", oldName: "Polished Dictation",
                        connection: "conn-1", to: d.modes)
        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        let second = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(second.isEmpty)
    }
}
