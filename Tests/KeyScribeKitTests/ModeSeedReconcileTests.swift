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

    // Build a legacy on-disk file from the FROZEN pre-rename template — the shape a real v0.1.x build
    // wrote, not today's catalog seed. A rename must recognize this (modulo the connection/enabled the
    // user set), which is exactly what a pre-rename upgrade presents. Deliberately NOT derived from the
    // current catalog: today's `polish`/`ai-prompt`/`edit-selection` have drifted, so a fixture built
    // from them would be an EDITED file to the reconciler and would (correctly) not rename.
    private func writeLegacy(
        newId: String, oldId: String, oldName: String,
        connection: String = "", enabled: Bool = true, editPrompt: Bool = false, to modesDir: URL
    ) throws {
        var mode = try #require(ModeStore.preRenameTemplate(for: oldId))
        mode.enabled = enabled
        mode.aiRewrite?.connection = connection
        if editPrompt { mode.aiRewrite?.prompt = "totally custom prompt the user wrote" }
        try ModeStore.write(mode, to: modesDir)
    }

    // The frozen pre-rename templates are the bytes v0.1.0–v0.1.6 wrote (reconstructed verbatim from the
    // starterModes() definitions at the commit before the rename). They must NEVER be "fixed" or refreshed
    // from the live catalog — an install upgrading across the rename presents exactly these, and the whole
    // migration hinges on recognizing them. This pins their template fingerprints so an accidental edit
    // fails here loudly instead of silently breaking the migration for real upgraders.
    @Test func preRenameTemplatesAreFrozen() throws {
        let pinned: [String: String] = [
            "polished-dictation": "51c638201452def4",
            "prompt": "bbd17ef594d95ef9",
            "work-on-selection": "46bf15b15afc60f9",
        ]
        for (id, fingerprint) in pinned {
            let mode = try #require(ModeStore.preRenameTemplate(for: id))
            #expect(ModeStore.seedTemplateFingerprint(mode) == fingerprint,
                    "pre-rename template '\(id)' changed — it must match what old builds wrote, never be refreshed")
        }
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
        #expect(ModeStore.loadAll(in: d.modes).count == 8)
    }

    // A write that fails (disk full, unwritable path) must NOT record the seed in the ledger — otherwise
    // the mode is marked "already offered" and a later healthy run never re-seeds it, so the user
    // permanently loses a starter that was never written.
    @Test func failedSeedWriteDoesNotRecordTheLedger() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try FileManager.default.createDirectory(at: d.support, withIntermediateDirectories: true)
        try Data().write(to: d.modes)

        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)

        let entries = ModeStore.loadLedger(in: d.ledger)?.entries ?? []
        #expect(entries.isEmpty)
    }

    // A rename whose new-file write fails must NOT delete the user's old mode file or record the new id.
    // The unconditional delete-then-record shape would strand the mode entirely: old removed, new never
    // written. Read-only `modes` fails the write; the ledger (separate dir) still records the outcome.
    @Test func failedRenameWritePreservesTheOldFileAndDoesNotRecord() throws {
        let d = tempDirs()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.modes.path)
            try? FileManager.default.removeItem(at: d.support)
        }
        try writeLegacy(newId: "polish", oldId: "polished-dictation", oldName: "Polished Dictation",
                        connection: "conn-1", enabled: true, to: d.modes)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: d.modes.path)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(outcome.renamed.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: d.modes.appendingPathComponent("polished-dictation.toml").path))
        let ledgerIds = (ModeStore.loadLedger(in: d.ledger)?.entries ?? []).map(\.seedId)
        #expect(!ledgerIds.contains("polish"))
    }

    @Test func failedAdditiveReconcileWriteLeavesTheSeedEligible() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try FileManager.default.createDirectory(at: d.support, withIntermediateDirectories: true)
        try Data().write(to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        let entries = ModeStore.loadLedger(in: d.ledger)?.entries ?? []
        #expect(outcome.added.isEmpty)
        #expect(entries.isEmpty)
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

    // A genuine pre-rename file carries the OLD (short) prompt, seed_version 1, and no trigger key. The
    // rename must recognize it and upgrade it to today's polish template. Matching against the CURRENT
    // catalog instead of the frozen old template would miss this file, leaving the mode frozen at its old
    // id forever, with no signal. The prompt/version upgrade to today's template, but the user's trigger
    // bindings (here, their absence) are preserved — a migration never silently binds a global hotkey the
    // user did not choose (P2-16), so the renamed polish does NOT gain today's right_option.
    @Test func preRenameFileWithOldPromptIsUpgradedToCurrentTemplate() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        let old = try #require(ModeStore.preRenameTemplate(for: "polished-dictation"))
        try ModeStore.write(old, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.renamed.contains("polish"))

        let polish = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        let currentPolish = try #require(ModeStore.starterModes().first { $0.id == "polish" })
        #expect(polish.aiRewrite?.prompt == currentPolish.aiRewrite?.prompt)   // upgraded to today's prompt
        #expect(polish.seedVersion == currentPolish.seedVersion)
        #expect(polish.triggerKeys.isEmpty)                                    // keeps the old file's absent binding
    }

    // A file byte-shaped like TODAY's polish but sitting at the old id is NOT a pre-rename file (no old
    // build ever wrote today's template there): its template differs from the frozen old one, so it must
    // be left alone, not silently overwritten. Proves the match is against the frozen old template, not
    // the current catalog.
    @Test func currentShapedFileAtOldIdIsNotTreatedAsARename() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        var current = try #require(ModeStore.starterModes().first { $0.id == "polish" })
        current.id = "polished-dictation"
        current.seedId = "polished-dictation"
        current.name = "Polished Dictation"
        try ModeStore.write(current, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(!outcome.renamed.contains("polish"))
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("polished-dictation.toml").path))
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
        // A minimal existing install: only email survives. No ledger (pre-ledger install).
        let survivor = try #require(ModeStore.starterModes().first { $0.id == "email" })
        try ModeStore.write(survivor, to: d.modes)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("code.toml").path))
    }

    @Test func preLedgerDeletedModesAreNotResurrected() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        // Existing install that kept only email (everything else deleted under the old build).
        let survivor = try #require(ModeStore.starterModes().first { $0.id == "email" })
        try ModeStore.write(survivor, to: d.modes)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        for resurrected in ["markdown", "shell", "message"] {
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

    // One past the starter's current shipped version — the smallest bump that actually exercises the
    // update path, derived so these tests never go stale the next time a starter's seed_version rises.
    private func nextVersion(_ id: String) -> Int {
        (ModeStore.starterModes().first { $0.id == id }?.seedVersion ?? 1) + 1
    }

    @Test func versionBumpRefreshesAnUneditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)

        let future = nextVersion("message")
        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: future)
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(ModeStore.loadLedger(in: d.ledger)?.entry("message")?.version == future)
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

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(after.aiRewrite?.connection == "conn-1")
        #expect(after.enabled == true)
    }

    // P2-16: a seed_version bump must NEVER silently push a new trigger key onto an upgrading install.
    // Trigger bindings are user-owned exactly like connection/enabled — carryForward preserves the
    // on-disk keys (here, their absence), so a version bump carries prompt/behavior forward but leaves
    // the user's global hotkeys untouched. A fresh install still gets the catalog default trigger (it is
    // written whole through the additive path, which never calls carryForward — proven separately).
    @Test func versionBumpDoesNotPushANewTriggerKeyOntoAnUneditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)
        // The user enabled message but never edited it; message ships with no trigger key.
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(message.triggerKeys.isEmpty)
        message.enabled = true
        try ModeStore.write(message, to: d.modes)

        // A revision that bumps the version AND adds a global bare-modifier trigger — the shape of the
        // change that shipped right_option/right_command onto polish/edit-selection in v0.1.17.
        let future = nextVersion("message")
        let bumped = ModeStore.starterModes().map { mode -> Mode in
            guard mode.id == "message" else { return mode }
            var revised = mode
            revised.seedVersion = future
            revised.triggerKeys = [.init(key: "right_option")]
            return revised
        }
        let outcome = ModeStore.reconcileSeeds(
            modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.triggerKeys.isEmpty)   // the pushed right_option is NOT silently bound
        #expect(after.enabled == true)       // user-owned knobs preserved …
        #expect(after.seedVersion == future) // … while the version/behavior update still lands
    }

    @Test func versionBumpSkipsAnEditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStartersIfEmpty(in: d.modes, ledgerDir: d.ledger)
        // The user edited message.toml — its template no longer matches, so the update must skip it.
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.prompt = "my own message prompt"
        try ModeStore.write(message, to: d.modes)

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

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
            "polish": (4, "5f3ef1df08c7f3ed"),
            "message": (3, "ef585b77ce46bf0d"),
            "email": (2, "817ac3f600010afb"),
            "edit-selection": (4, "8a301c3a95672266"),
            "ai-prompt": (5, "bce63766ad4c94fd"),
            "code": (3, "eb67c0911268db8"),
            "markdown": (3, "da1bf73e80b3f2b1"),
            "shell": (1, "debf79feb745f80b"),
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
