import Foundation
@testable import KeyScribeKit

extension ModeStore {
    // Production no longer writes starter mode files on fresh install (it records ledger offers via
    // `recordStarterOffersIfFresh` instead), so tests that need them on disk write them explicitly.
    static func seedStarterFilesForTesting(in dir: URL) {
        for mode in starterModes() {
            try? write(mode, to: dir)
        }
    }
}
