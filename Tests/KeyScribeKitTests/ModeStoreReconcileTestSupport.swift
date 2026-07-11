import Foundation
@testable import KeyScribeKit

extension ModeStore {
    // Test fixture reproducing a pre-UX2 "existing install": every starter written as a mode FILE plus a seed
    // ledger fingerprinted from those templates. Production no longer writes starter files (fresh installs
    // record ledger offers via `recordStarterOffersIfFresh`); the reconcile tests still need the legacy
    // on-disk shape to exercise rename/update/re-baseline behavior.
    static func seedStarterFilesAndLedgerForTesting(in dir: URL, ledgerDir: URL) {
        var ledger = SeedLedger()
        for mode in starterModes() {
            try? write(mode, to: dir)
            ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: seedTemplateFingerprint(mode))
        }
        saveLedger(ledger, in: ledgerDir)
    }
}
