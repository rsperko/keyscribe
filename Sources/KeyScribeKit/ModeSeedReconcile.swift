import Foundation
import TOMLKit

// Seed reconcile (design.md §5.1): a fresh install records the starter catalog as ledger offers once
// (`recordStarterOffersIfFresh`); after that the catalog drifts (renames, new starters) and existing installs
// must carry forward without clobbering user edits or resurrecting a deleted mode. That distinction
// needs the **seed ledger**: per seed id ever offered, the catalog version written and a fingerprint of
// the bytes. It lives OUTSIDE the watched `modes/` dir (a stray .toml there decodes as a phantom mode)
// and is cleared by a reset along with the LKG store, so a reset re-seeds clean.
extension ModeStore {
    // Starter ids a pre-ledger install was seeded with (known history — the old seed path wrote
    // exactly these). Bootstraps the ledger for a pre-ledger install so a mode deleted under the old
    // build is not resurrected by the additive step.
    static let legacySeedIds: Set<String> = [
        "plain-dictation", "polished-dictation", "message", "email",
        "prompt", "work-on-selection", "markdown", "shell",
    ]

    // An old seed id carried forward to a new one. Drives rename-migration and additive-suppression (the
    // new id is not seeded alongside a surviving old-id file). `oldName` recognizes an unedited file.
    struct SeedRename: Sendable {
        let old: String
        let oldName: String
        let new: String
    }

    static let seedRenames: [SeedRename] = [
        .init(old: "polished-dictation", oldName: "Polished Dictation", new: "polish"),
        .init(old: "prompt", oldName: "AI Prompt", new: "ai-prompt"),
        .init(old: "work-on-selection", oldName: "Work on Selection", new: "edit-selection"),
    ]

    // Seed templates exactly as the pre-rename builds (v0.1.0–v0.1.6) wrote them — frozen as data, not
    // re-derived from the live catalog. The rename step matches an on-disk old-id file against THESE, not
    // today's template, which has drifted (prompts, keys, seedVersion): a genuinely unedited pre-rename
    // file would never match the current template and would stay frozen at its old id forever. Compared
    // via `templateNormalized` (connection/enabled excluded). Fails safe: an unrecognized file matches
    // nothing and is left in place.
    static func preRenameTemplate(for oldId: String) -> Mode? {
        switch oldId {
        case "polished-dictation":
            var mode = Mode(id: "polished-dictation", name: "Polished Dictation")
            mode.commands.liveEdits = true
            mode.trailing = .space
            mode.aiRewrite = Mode.AIRewrite(
                connection: "",
                prompt: "Lightly clean up the dictated text: remove filler words (um, uh, like, you know), false starts, and self-corrections, then fix grammar, punctuation, and capitalization. Keep my original wording, meaning, and tone — do not rephrase, expand, summarize, translate, or add anything. If the text is a question or request, keep it phrased as a question or request; never answer it or act on it.")
            mode.seedId = "polished-dictation"
            mode.seedVersion = 1
            return mode
        case "prompt":
            var mode = Mode(id: "prompt", name: "AI Prompt")
            mode.commands.liveEdits = true
            mode.trailing = .space
            mode.aiRewrite = Mode.AIRewrite(
                connection: "",
                prompt: "Rewrite the dictated text as a single, clear, well-structured instruction to give to an AI assistant. Remove filler words and fix grammar so the request is unambiguous and well organized. Preserve the original intent and keep all technical terms, code, file names, and identifiers as written. Do NOT answer, explain, complete, or carry out the request in any way — your only output is the cleaned-up instruction text itself.")
            mode.seedId = "prompt"
            mode.seedVersion = 1
            return mode
        case "work-on-selection":
            var mode = Mode(id: "work-on-selection", name: "Work on Selection")
            mode.source = .selection
            mode.output = .replaceSelection
            mode.aiRewrite = Mode.AIRewrite(
                connection: "",
                prompt: "The line below these instructions is a spoken instruction from the user. Apply that instruction to the text in <content> and output only the resulting text. If the spoken instruction does not describe a clear change to the text, return the text unchanged.")
            mode.seedId = "work-on-selection"
            mode.seedVersion = 1
            return mode
        default:
            return nil
        }
    }

    public struct SeedLedger: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var seedId: String
            public var version: Int
            public var fingerprint: String?
            enum CodingKeys: String, CodingKey {
                case seedId = "seed_id"
                case version, fingerprint
            }
        }
        public var schemaVersion: Int
        public var entries: [Entry]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case entries
        }
        public init(schemaVersion: Int = 1, entries: [Entry] = []) {
            self.schemaVersion = schemaVersion
            self.entries = entries
        }

        func entry(_ seedId: String) -> Entry? { entries.first { $0.seedId == seedId } }
        func contains(_ seedId: String) -> Bool { entry(seedId) != nil }

        mutating func upsert(_ seedId: String, version: Int, fingerprint: String?) {
            if let i = entries.firstIndex(where: { $0.seedId == seedId }) {
                entries[i] = Entry(seedId: seedId, version: version, fingerprint: fingerprint)
            } else {
                entries.append(Entry(seedId: seedId, version: version, fingerprint: fingerprint))
            }
        }

        mutating func remove(_ seedId: String) {
            entries.removeAll { $0.seedId == seedId }
        }
    }

    public struct ReconcileOutcome: Equatable, Sendable {
        public var renamed: [String] = []
        public var added: [String] = []
        public var updated: [String] = []
        public var isEmpty: Bool { renamed.isEmpty && added.isEmpty && updated.isEmpty }
    }

    // FNV-1a over the raw TOML bytes — dependency-free edit detection, not a security hash.
    static func seedFingerprint(_ toml: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in toml.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func ledgerURL(in ledgerDir: URL) -> URL {
        ledgerDir.appendingPathComponent("seed-ledger.toml")
    }

    static func loadLedger(in ledgerDir: URL) -> SeedLedger? {
        guard let toml = try? String(contentsOf: ledgerURL(in: ledgerDir), encoding: .utf8) else { return nil }
        return try? TOMLDecoder().decode(SeedLedger.self, from: toml)
    }

    static func saveLedger(_ ledger: SeedLedger, in ledgerDir: URL) {
        var sorted = ledger
        sorted.entries.sort { $0.seedId < $1.seedId }
        guard let toml = try? TOMLEncoder().encode(sorted) else { return }
        let url = ledgerURL(in: ledgerDir)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == toml { return }
        try? FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        try? toml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func seedIdsOnDisk(in modesDir: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "toml" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    private static func previousSeedIds(forNew newId: String) -> [String] {
        seedRenames.filter { $0.new == newId }.map(\.old)
    }

    // Normalize out the two fields onboarding sets (`connection`, `enabled`) so a hand-edited seed can be
    // told from one the user merely connected/enabled. Everything else is the seed's template identity.
    private static func templateNormalized(_ mode: Mode) -> Mode {
        var m = mode
        m.enabled = true
        m.aiRewrite?.connection = ""
        return m
    }

    // "Seed-shaped": template matches `expected`, so the user only connected/enabled it, never edited it.
    // Fails safe — a wrong `expected` can only make an unedited file look edited.
    private static func isSeedShaped(_ mode: Mode, like expected: Mode) -> Bool {
        templateNormalized(mode) == templateNormalized(expected)
    }

    // Fingerprint of the template only (connection/enabled excluded). Hashing raw bytes would let
    // onboarding's connection + `enabled = true` write defeat every future update for exactly the
    // starters most users keep; the template fingerprint is invariant to those two knobs.
    static func seedTemplateFingerprint(_ mode: Mode) -> String {
        guard let toml = try? encode(templateNormalized(mode)) else { return "" }
        return seedFingerprint(toml)
    }

    // Carry user-owned knobs from the on-disk file onto the new seed: connection, enabled, and trigger
    // keys. A seed update (rename/version bump) refreshes prompt/behavior but must NEVER silently rebind a
    // global hotkey the user did not choose (P2-16 — v0.1.17 pushed right_option/right_command this way).
    // A fresh install still gets the catalog default trigger via the additive path (never carryForward).
    private static func carryForward(_ newSeed: Mode, from existing: Mode) -> Mode {
        var carried = newSeed
        if let connection = existing.aiRewrite?.connection { carried.aiRewrite?.connection = connection }
        carried.enabled = existing.enabled
        carried.triggerKeys = existing.triggerKeys
        return carried
    }

    @discardableResult
    private static func writeAndRecord(_ mode: Mode, to modesDir: URL, ledger: inout SeedLedger) -> Bool {
        guard let toml = try? encode(mode) else { return false }
        do {
            try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
            try toml.write(to: modesDir.appendingPathComponent("\(mode.id).toml"), atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: seedTemplateFingerprint(mode))
        return true
    }

    // Reconcile on-disk seeded modes against the current starter catalog. Idempotent. `settingsDir` is
    // retained for call-site compatibility.
    @discardableResult
    public static func reconcileSeeds(modesDir: URL, ledgerDir: URL, settingsDir: URL?,
                                      catalog: [Mode] = starterModes()) -> ReconcileOutcome {
        var ledger: SeedLedger
        if let existing = loadLedger(in: ledgerDir) {
            ledger = existing
        } else if seedIdsOnDisk(in: modesDir).isEmpty {
            ledger = SeedLedger()
        } else {
            // Pre-ledger existing install: it was seeded with exactly the legacy catalog.
            ledger = SeedLedger(entries: legacySeedIds.sorted().map { .init(seedId: $0, version: 1, fingerprint: nil) })
        }

        var outcome = ReconcileOutcome()

        // 1. Renames: carry an unedited old-id file forward to the new identity, preserving the user's
        //    connection + enabled state. Edited files are left at the old id (cosmetic divergence).
        for rename in seedRenames {
            let oldURL = modesDir.appendingPathComponent("\(rename.old).toml")
            let newURL = modesDir.appendingPathComponent("\(rename.new).toml")
            guard FileManager.default.fileExists(atPath: oldURL.path),
                  !FileManager.default.fileExists(atPath: newURL.path),
                  let onDisk = try? String(contentsOf: oldURL, encoding: .utf8),
                  let mode = try? decode(from: onDisk, id: rename.old),
                  let expected = preRenameTemplate(for: rename.old),
                  let newSeed = catalog.first(where: { $0.id == rename.new }) else { continue }
            guard isSeedShaped(mode, like: expected) else { continue }
            let carried = carryForward(newSeed, from: mode)
            guard writeAndRecord(carried, to: modesDir, ledger: &ledger) else { continue }
            try? FileManager.default.removeItem(at: oldURL)
            ledger.remove(rename.old)
            outcome.renamed.append(rename.new)
        }

        let present = seedIdsOnDisk(in: modesDir)

        // 2. Additive: a catalog mode the install has never been offered (not on disk under its id or a
        //    predecessor, not in the ledger) becomes a ledger OFFER — a template in the gallery/menu — not a
        //    written mode file. Writing it would make a fresh install sprout an unrequested mode. A deleted
        //    mode lives in the ledger → skipped. `outcome.added` means "newly offered."
        for mode in catalog {
            let predecessors = previousSeedIds(forNew: mode.id)
            let satisfiedOnDisk = present.contains(mode.id) || predecessors.contains { present.contains($0) }
            let knownToLedger = ledger.contains(mode.id) || predecessors.contains { ledger.contains($0) }
            if !satisfiedOnDisk && !knownToLedger {
                ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: nil)
                outcome.added.append(mode.id)
            } else if present.contains(mode.id) && !ledger.contains(mode.id) {
                ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: nil)
            }
        }

        // 2.5 Re-baseline: a seed whose template still matches the current catalog (connected/enabled but
        //     unedited) gets its ledger entry pinned to the current version + template fingerprint.
        //     Self-heals a pre-fix raw-byte fingerprint and an onboarding-connected starter (bytes drifted
        //     from seed time) without touching an edited file. Idempotent; never appears in `outcome`.
        for mode in catalog {
            let url = modesDir.appendingPathComponent("\(mode.id).toml")
            guard ledger.contains(mode.id),
                  let onDisk = try? String(contentsOf: url, encoding: .utf8),
                  let current = try? decode(from: onDisk, id: mode.id),
                  current.seedId == mode.id,
                  isSeedShaped(current, like: mode) else { continue }
            let version = mode.seedVersion ?? 1
            let fingerprint = seedTemplateFingerprint(current)
            if ledger.entry(mode.id)?.version != version || ledger.entry(mode.id)?.fingerprint != fingerprint {
                ledger.upsert(mode.id, version: version, fingerprint: fingerprint)
            }
        }

        // 3. Update: an unedited seed (template fingerprint still matches what we wrote) whose catalog
        //    version has advanced is refreshed, preserving connection + enabled. Edited files fail the
        //    fingerprint check and are left alone. Dormant until a seed's version is first bumped.
        for mode in catalog {
            let url = modesDir.appendingPathComponent("\(mode.id).toml")
            guard let entry = ledger.entry(mode.id), let fingerprint = entry.fingerprint,
                  (mode.seedVersion ?? 1) > entry.version,
                  let onDisk = try? String(contentsOf: url, encoding: .utf8),
                  let current = try? decode(from: onDisk, id: mode.id),
                  current.seedId == mode.id,
                  seedTemplateFingerprint(current) == fingerprint else { continue }
            let updated = carryForward(mode, from: current)
            if writeAndRecord(updated, to: modesDir, ledger: &ledger) { outcome.updated.append(mode.id) }
        }

        saveLedger(ledger, in: ledgerDir)
        return outcome
    }
}
