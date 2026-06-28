import Foundation
import TOMLKit

// Seed reconcile (design.md §5.1): a fresh install seeds the whole starter catalog once
// (`seedStartersIfEmpty`). After that, the catalog can drift — modes get renamed, new starters are
// added — and existing installs must carry forward *without* clobbering a user's edits or
// resurrecting a mode they deleted. That distinction needs persistent state: the **seed ledger**
// records, per seed id this install has ever been offered, the catalog version it was written at and
// a fingerprint of the exact bytes written. The ledger lives OUTSIDE the watched `modes/` dir (a
// stray .toml there would decode as a phantom mode) and is cleared by a reset along with the LKG
// store, so a reset re-seeds clean.
extension ModeStore {
    // The starter ids any pre-ledger install was seeded with (the catalog before the ledger existed).
    // Known history, not a guess — `seedStartersIfEmpty` wrote exactly these. Used to bootstrap the
    // ledger for an install that predates it, so a mode the user deleted under the old build is not
    // resurrected by the additive step.
    static let legacySeedIds: Set<String> = [
        "plain-dictation", "polished-dictation", "message", "email",
        "prompt", "work-on-selection", "markdown", "shell",
    ]

    // Catalog renames: an old seed id that was carried forward to a new one. Drives both
    // rename-migration and additive-suppression (so the new id is not seeded alongside a surviving
    // old-id file). `oldName` is the old seed's display name, needed to recognize an unedited file.
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

    // FNV-1a over the raw TOML bytes — a dependency-free fingerprint for "did the file change since we
    // wrote it." Not a security hash; edit detection only.
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
        try? FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        try? toml.write(to: ledgerURL(in: ledgerDir), atomically: true, encoding: .utf8)
    }

    private static func seedIdsOnDisk(in modesDir: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: modesDir, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "toml" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    private static func previousSeedIds(forNew newId: String) -> [String] {
        seedRenames.filter { $0.new == newId }.map(\.old)
    }

    // The two fields onboarding sets on a seed for the user: `connection` (which AI service) and
    // `enabled`. The seed's *template* identity is everything else (prompt, fragments, keys, shape).
    // Normalizing these out is how we tell a hand-edited seed from one the user merely connected/enabled.
    private static func templateNormalized(_ mode: Mode) -> Mode {
        var m = mode
        m.enabled = true
        m.aiRewrite?.connection = ""
        return m
    }

    // A mode is "seed-shaped" for `expected` when its template matches — i.e. the user only connected
    // or enabled it, never hand-edited it. Any real edit (prompt, keys, source) fails this and the file
    // is left untouched. Fails safe: a wrong `expected` can only make an unedited file look edited.
    private static func isSeedShaped(_ mode: Mode, like expected: Mode) -> Bool {
        templateNormalized(mode) == templateNormalized(expected)
    }

    // Fingerprint of the seed's *template* only (connection/enabled excluded). Onboarding rewrites a
    // connected starter's file with the user's connection + `enabled = true`; hashing the raw bytes
    // would make that write defeat every future update for exactly the starters most users keep. The
    // template fingerprint is invariant to those two knobs, so a connected-but-unedited seed still
    // matches its seed-time fingerprint and stays eligible for a silent update.
    static func seedTemplateFingerprint(_ mode: Mode) -> String {
        guard let toml = try? encode(templateNormalized(mode)) else { return "" }
        return seedFingerprint(toml)
    }

    private static func carryForward(_ newSeed: Mode, connection: String?, enabled: Bool) -> Mode {
        var carried = newSeed
        if let connection { carried.aiRewrite?.connection = connection }
        carried.enabled = enabled
        return carried
    }

    private static func writeAndRecord(_ mode: Mode, to modesDir: URL, ledger: inout SeedLedger) {
        guard let toml = try? encode(mode) else { return }
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? toml.write(to: modesDir.appendingPathComponent("\(mode.id).toml"), atomically: true, encoding: .utf8)
        ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: seedTemplateFingerprint(mode))
    }

    // Reconcile the on-disk seeded modes against the current starter catalog. Idempotent: a second run
    // changes nothing. Returns what it did (for logging). `settingsDir` is patched only when a rename
    // moves the mode `default_mode_id` points at.
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
        var renamedOldToNew: [String: String] = [:]

        // 1. Renames: carry an unedited old-id file forward to the new identity, preserving the user's
        //    connection + enabled state. Edited files are left at the old id (cosmetic divergence).
        for rename in seedRenames {
            let oldURL = modesDir.appendingPathComponent("\(rename.old).toml")
            let newURL = modesDir.appendingPathComponent("\(rename.new).toml")
            guard FileManager.default.fileExists(atPath: oldURL.path),
                  !FileManager.default.fileExists(atPath: newURL.path),
                  let onDisk = try? String(contentsOf: oldURL, encoding: .utf8),
                  let mode = try? decode(from: onDisk, id: rename.old),
                  var newSeed = catalog.first(where: { $0.id == rename.new }) else { continue }
            var expected = newSeed
            expected.id = rename.old
            expected.seedId = rename.old
            expected.name = rename.oldName
            guard isSeedShaped(mode, like: expected) else { continue }
            newSeed = carryForward(newSeed, connection: mode.aiRewrite?.connection, enabled: mode.enabled)
            writeAndRecord(newSeed, to: modesDir, ledger: &ledger)
            try? FileManager.default.removeItem(at: oldURL)
            ledger.remove(rename.old)
            renamedOldToNew[rename.old] = rename.new
            outcome.renamed.append(rename.new)
        }

        let present = seedIdsOnDisk(in: modesDir)

        // 2. Additive: a catalog mode the install has never been offered (not on disk under its id or a
        //    predecessor, not in the ledger) appears. A deleted mode lives in the ledger → skipped.
        for mode in catalog {
            let predecessors = previousSeedIds(forNew: mode.id)
            let satisfiedOnDisk = present.contains(mode.id) || predecessors.contains { present.contains($0) }
            let knownToLedger = ledger.contains(mode.id) || predecessors.contains { ledger.contains($0) }
            if !satisfiedOnDisk && !knownToLedger {
                writeAndRecord(mode, to: modesDir, ledger: &ledger)
                outcome.added.append(mode.id)
            } else if present.contains(mode.id) && !ledger.contains(mode.id) {
                ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: nil)
            }
        }

        // 2.5 Re-baseline: a seed whose template still matches the *current* catalog (the user only
        //     connected/enabled it, never edited it) has its ledger entry pinned to the current version
        //     and template fingerprint. Self-heals two cases without ever touching an edited file: a
        //     pre-fix ledger that stored a raw-byte fingerprint, and a starter the user connected via
        //     onboarding (whose bytes drifted from seed time). Idempotent; never appears in `outcome`.
        for mode in catalog {
            let url = modesDir.appendingPathComponent("\(mode.id).toml")
            guard ledger.contains(mode.id),
                  let onDisk = try? String(contentsOf: url, encoding: .utf8),
                  let current = try? decode(from: onDisk, id: mode.id),
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
                  seedTemplateFingerprint(current) == fingerprint else { continue }
            let updated = carryForward(mode, connection: current.aiRewrite?.connection, enabled: current.enabled)
            writeAndRecord(updated, to: modesDir, ledger: &ledger)
            outcome.updated.append(mode.id)
        }

        saveLedger(ledger, in: ledgerDir)

        if !renamedOldToNew.isEmpty, let settingsDir,
           var settings = try? SettingsStore.loadOrCreate(supportDir: settingsDir),
           let newId = renamedOldToNew[settings.defaultModeId] {
            settings.defaultModeId = newId
            try? SettingsStore.write(settings, to: settingsDir)
        }

        return outcome
    }
}
