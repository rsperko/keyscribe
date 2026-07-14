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

    // Builds from the FROZEN pre-rename template (what a real v0.1.x build wrote), never today's catalog —
    // today's starters have drifted, so a fixture derived from them would look "edited" to the reconciler
    // and would (correctly) not rename.
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

    // Pins the frozen pre-rename template fingerprints (bytes v0.1.0–v0.1.6 actually wrote). Never
    // "fix" these to match the live catalog — an accidental edit here would silently break the rename
    // migration for real upgraders.
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
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)

        let ledger = try #require(ModeStore.loadLedger(in: d.ledger))
        #expect(Set(ledger.entries.map(\.seedId)) == Set(ModeStore.starterModes().map(\.id)))
        #expect(ledger.entries.allSatisfy { $0.fingerprint != nil })

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.isEmpty)
        #expect(ModeStore.loadAll(in: d.modes).count == 8)
    }

    // A rename whose new-file write fails must not delete the old file or record the new id — an
    // unconditional delete-then-record would strand the mode (old gone, new never written).
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

    @Test func renamesUneditedSeedPreservingConnectionAndEnabled() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try writeLegacy(newId: "polish", oldId: "polished-dictation", oldName: "Polished Dictation",
                        connection: "conn-1", enabled: true, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.renamed.contains("polish"))

        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("polished-dictation.toml").path))
        let polish = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        #expect(polish.name == "Cleanup")
        #expect(polish.seedId == "polish")
        #expect(polish.aiRewrite?.connection == "conn-1")
        #expect(polish.enabled == true)
    }

    // Matches against the frozen OLD template, not the current catalog, so a genuine pre-rename file (old
    // prompt, no trigger) upgrades to today's polish. Trigger bindings still carry forward as-is (P2-16:
    // a migration never silently binds a hotkey the user didn't choose) — renamed polish stays keyless.
    @Test func preRenameFileWithOldPromptIsUpgradedToCurrentTemplate() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        let old = try #require(ModeStore.preRenameTemplate(for: "polished-dictation"))
        try ModeStore.write(old, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        #expect(outcome.renamed.contains("polish"))

        let polish = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        let currentPolish = try #require(ModeStore.starterModes().first { $0.id == "polish" })
        #expect(polish.aiRewrite?.prompt == currentPolish.aiRewrite?.prompt)
        #expect(polish.seedVersion == currentPolish.seedVersion)
        #expect(polish.triggerKeys.isEmpty)   // preserves the old file's absent trigger binding
    }

    // A file shaped like TODAY's polish sitting at the old id is not a pre-rename file — no old build
    // ever wrote today's template there — so it must be left alone rather than overwritten.
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

    // UX2 phase 4c: a genuinely new catalog id is OFFERED (gallery/menu template), never auto-written as
    // a file — a legacy install shouldn't sprout an unrequested disabled row.
    @Test func additiveOffersAGenuinelyNewCatalogModeWithoutWritingAFile() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        // Pre-ledger install: only email survives, no ledger file yet.
        let survivor = try #require(ModeStore.starterModes().first { $0.id == "email" })
        try ModeStore.write(survivor, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("code.toml").path))
        #expect(outcome.added.contains("code"))
        let ledger = ModeStore.loadLedger(in: d.ledger)
        #expect(ledger?.contains("code") == true)
        #expect(ledger?.entry("code")?.fingerprint == nil)
    }

    // An offer record (nil fingerprint) marks the id as "known to the ledger", so reconcile never
    // materializes a file for it.
    @Test func anOfferRecordSuppressesTheAdditiveStep() {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.recordStarterOffersIfFresh(in: d.modes, ledgerDir: d.ledger)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(outcome.added.isEmpty)
        #expect(ModeStore.loadAll(in: d.modes).isEmpty)
    }

    // UX2 phase 4c: reconcile only touches files whose seedId equals the catalog id, so a hand-placed
    // seedId-nil file at a catalog id is never re-baselined or updated.
    @Test func aSeedlessFileAtACatalogIdSurvivesAVersionBumpUntouched() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        var handcrafted = try #require(ModeStore.starterModes().first { $0.id == "message" })
        handcrafted.seedId = nil
        handcrafted.seedVersion = nil
        handcrafted.aiRewrite?.prompt = "a user's own message mode at this id"
        try ModeStore.write(handcrafted, to: d.modes)

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(!outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "a user's own message mode at this id")
    }

    // Fingerprint recorded at materialization + still matching → the bump updates it, carrying forward
    // connection/enabled/triggerKeys.
    @Test func aMaterializedUneditedSeedIsUpdatedByAVersionBump() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        let template = try #require(ModeStore.templates().first { $0.id == "message" })
        guard case .seed(var mode) = ModeTemplateInstantiation.materialize(template: template, existing: [], connections: []) else {
            Issue.record("expected .seed"); return
        }
        mode.aiRewrite?.connection = "conn-1"
        mode.enabled = true   // starters ship disabled; enabling here must survive the bump
        try ModeStore.write(mode, to: d.modes)
        ModeStore.recordMaterializedSeed(mode, ledgerDir: d.ledger)

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(after.aiRewrite?.connection == "conn-1")
        #expect(after.enabled)
    }

    @Test func aMaterializedThenEditedSeedIsLeftAloneByAVersionBump() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        let template = try #require(ModeStore.templates().first { $0.id == "message" })
        guard case .seed(var mode) = ModeTemplateInstantiation.materialize(template: template, existing: [], connections: []) else {
            Issue.record("expected .seed"); return
        }
        try ModeStore.write(mode, to: d.modes)
        ModeStore.recordMaterializedSeed(mode, ledgerDir: d.ledger)
        // edit after materializing breaks the fingerprint match
        mode.aiRewrite?.prompt = "my own edited message prompt"
        try ModeStore.write(mode, to: d.modes)

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(!outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "my own edited message prompt")
    }

    @Test func preLedgerDeletedModesAreNotResurrected() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        // old build where everything but email was deleted
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
        // edited old file stays; additive must not seed a duplicate "ai-prompt"
        #expect(FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("prompt.toml").path))
        #expect(!FileManager.default.fileExists(atPath: d.modes.appendingPathComponent("ai-prompt.toml").path))
    }

    // Catalog copy with one starter's prompt + seed_version bumped — the change shape a contributor
    // makes when revising a seed (config_schema.md seed reconcile).
    private func catalog(bumping id: String, prompt: String, to version: Int) -> [Mode] {
        ModeStore.starterModes().map { mode in
            guard mode.id == id else { return mode }
            var revised = mode
            revised.aiRewrite?.prompt = prompt
            revised.seedVersion = version
            return revised
        }
    }

    // One past the current shipped version — smallest bump that exercises the update path; derived so
    // tests don't go stale as seed_version rises.
    private func nextVersion(_ id: String) -> Int {
        (ModeStore.starterModes().first { $0.id == id }?.seedVersion ?? 1) + 1
    }

    @Test func versionBumpRefreshesAnUneditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)

        let future = nextVersion("message")
        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: future)
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "revised message prompt")
        #expect(ModeStore.loadLedger(in: d.ledger)?.entry("message")?.version == future)
    }

    // Regression guard: onboarding's connection/enable write must not desync the fingerprint and
    // permanently block future updates — this broke pre-fix for exactly the starters most users keep.
    @Test func versionBumpRefreshesAConnectedSeedPreservingConnectionAndEnabled() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)
        // simulates FirstRunController.connectStarterModes
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

    // P2-16: a seed_version bump must never silently push a new trigger key onto an upgrading install —
    // triggers are user-owned like connection/enabled, so carryForward preserves the on-disk keys (here,
    // none) while still updating prompt/behavior. A fresh install still gets the default via the
    // additive path, which never calls carryForward.
    @Test func versionBumpDoesNotPushANewTriggerKeyOntoAnUneditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)
        // enabled but unedited; message ships with no trigger key
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(message.triggerKeys.isEmpty)
        message.enabled = true
        try ModeStore.write(message, to: d.modes)

        // version bump + new trigger — the shape of the v0.1.17 change that added right_option/
        // right_command to polish/edit-selection
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
        #expect(after.enabled == true)
        #expect(after.seedVersion == future)
    }

    @Test func versionBumpSkipsAnEditedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)
        // edited message.toml no longer matches the template, so the update skips it
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.prompt = "my own message prompt"
        try ModeStore.write(message, to: d.modes)

        let bumped = catalog(bumping: "message", prompt: "revised message prompt", to: nextVersion("message"))
        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support, catalog: bumped)

        #expect(!outcome.updated.contains("message"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        #expect(after.aiRewrite?.prompt == "my own message prompt")
    }

    // Reconstructs an install seeded before replacement-example rules existed: same starters, no rules,
    // previous seed_version, ledger fingerprinted from that older template. One mode's connection/enabled
    // edit stands in for onboarding.
    private func seedPreExampleInstall(modes: URL, ledger ledgerDir: URL) throws {
        var ledger = ModeStore.SeedLedger()
        for mode in ModeStore.starterModes() {
            var old = mode
            if !mode.replacements.rules.isEmpty {
                old.replacements.rules = []
                old.seedVersion = (mode.seedVersion ?? 1) - 1
            }
            if old.id == "markdown" {
                old.aiRewrite?.connection = "conn-1"
                old.enabled = true
            }
            try ModeStore.write(old, to: modes)
            ledger.upsert(old.id, version: old.seedVersion ?? 1, fingerprint: ModeStore.seedTemplateFingerprint(old))
        }
        ModeStore.saveLedger(ledger, in: ledgerDir)
    }

    @Test func versionBumpDeliversTheReplacementExamplesToAPreExampleInstall() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try seedPreExampleInstall(modes: d.modes, ledger: d.ledger)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(Set(outcome.updated) == ["markdown", "code", "message", "email"])
        let after = ModeStore.loadAll(in: d.modes)
        let markdown = try #require(after.first { $0.id == "markdown" })
        #expect(markdown.replacements.rules.count == 8)
        #expect(markdown.aiRewrite?.connection == "conn-1")
        #expect(markdown.enabled == true)
        let email = try #require(after.first { $0.id == "email" })
        #expect(email.replacements.rules.count == 1)
        #expect(email.aiRewrite?.prompt.contains("already contains a closing or signature") == true)
    }

    // A user-authored rule is an edit like any other — fingerprint mismatch skips the update, so the
    // catalog's rule never overwrites it.
    @Test func versionBumpNeverClobbersUserAuthoredModeRules() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        try seedPreExampleInstall(modes: d.modes, ledger: d.ledger)
        var markdown = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "markdown" })
        markdown.replacements.rules = [.init(heard: "my own rule", replace: "custom", regex: false)]
        try ModeStore.write(markdown, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(!outcome.updated.contains("markdown"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "markdown" })
        #expect(after.replacements.rules == [.init(heard: "my own rule", replace: "custom", regex: false)])
    }

    // A pre-fix install's ledger holds a raw-byte fingerprint; reconcile must re-baseline it to a
    // template fingerprint or the next version bump is silently missed.
    @Test func reconcileReBaselinesALegacyFingerprintForAConnectedSeed() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        ModeStore.seedStarterFilesAndLedgerForTesting(in: d.modes, ledgerDir: d.ledger)
        var message = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "message" })
        message.aiRewrite?.connection = "conn-1"
        message.enabled = true
        try ModeStore.write(message, to: d.modes)
        // stale fingerprint, as a pre-fix install or post-onboarding drift would hold
        var ledger = try #require(ModeStore.loadLedger(in: d.ledger))
        let i = try #require(ledger.entries.firstIndex { $0.seedId == "message" })
        ledger.entries[i].fingerprint = "deadbeef"
        ModeStore.saveLedger(ledger, in: d.ledger)

        ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)
        let healed = try #require(ModeStore.loadLedger(in: d.ledger)?.entry("message")?.fingerprint)
        #expect(healed == ModeStore.seedTemplateFingerprint(message))
    }

    // Discipline tripwire (config_schema.md seed reconcile): pins each starter's (seed_version,
    // fingerprint). A template edit flips the fingerprint and fails this ON PURPOSE — fix by bumping
    // seed_version in starterModes() and updating the entry here; the bump is what carries the revision
    // to existing installs (reconcileSeeds step 3).
    @Test func revisingAStarterTemplateRequiresAVersionBump() throws {
        let pinned: [String: (version: Int, fingerprint: String)] = [
            "polish": (5, "f69ef368dd964eed"),
            "message": (4, "4ed26688a8e2db27"),
            "email": (3, "dcb65eb2acecbd9d"),
            "edit-selection": (4, "8a301c3a95672266"),
            "ai-prompt": (5, "bce63766ad4c94fd"),
            "code": (4, "cf077d166866bfc"),
            "markdown": (4, "a55b54483bc21549"),
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

    // "Polish" → "Cleanup" (seed_version 4 → 5) reaches an unedited install: name updates while
    // connection/enabled/trigger are preserved.
    @Test func polishRenameMigratesAnUnmodifiedInstall() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        var old = try #require(ModeStore.starterModes().first { $0.id == "polish" })
        old.name = "Polish"
        old.seedVersion = 4
        old.aiRewrite?.connection = "conn-1"
        old.enabled = true
        old.triggerKeys = [.init(key: "right_command")]
        try ModeStore.write(old, to: d.modes)
        ModeStore.recordMaterializedSeed(old, ledgerDir: d.ledger)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(outcome.updated.contains("polish"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        #expect(after.name == "Cleanup")
        #expect(after.aiRewrite?.connection == "conn-1")
        #expect(after.enabled == true)
        #expect(after.triggerKeys.map(\.key) == ["right_command"])
    }

    @Test func polishRenameSkipsAnEditedInstall() throws {
        let d = tempDirs()
        defer { try? FileManager.default.removeItem(at: d.support) }
        var old = try #require(ModeStore.starterModes().first { $0.id == "polish" })
        old.name = "Polish"
        old.seedVersion = 4
        try ModeStore.write(old, to: d.modes)
        ModeStore.recordMaterializedSeed(old, ledgerDir: d.ledger)
        // edit after seeding breaks the fingerprint match
        old.aiRewrite?.prompt = "my own custom cleanup prompt"
        try ModeStore.write(old, to: d.modes)

        let outcome = ModeStore.reconcileSeeds(modesDir: d.modes, ledgerDir: d.ledger, settingsDir: d.support)

        #expect(!outcome.updated.contains("polish"))
        let after = try #require(ModeStore.loadAll(in: d.modes).first { $0.id == "polish" })
        #expect(after.name == "Polish")
        #expect(after.aiRewrite?.prompt == "my own custom cleanup prompt")
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
