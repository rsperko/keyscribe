import Foundation
@testable import KeyScribeKit

extension ModeStore {
    // Test fixture: write the starter catalog as real mode files. Production no longer writes starter files
    // (fresh installs record ledger offers instead — `recordStarterOffersIfFresh`); tests that need starter
    // modes on disk as a fixture write them explicitly.
    static func seedStarterFilesForTesting(in dir: URL) {
        for mode in starterModes() {
            try? write(mode, to: dir)
        }
    }
}
