#if canImport(Sparkle)
import Foundation
import KeyScribeKit
import Sparkle

// Production-only auto-updater. Compiled only when Sparkle is linked (KEYSCRIBE_SPARKLE=1 in the
// manifest) and constructed only for the .production variant (main.swift). The feed URL is set
// programmatically here, never as SUFeedURL in Info.plist, so a copied plist cannot point a downstream
// build at KeyScribe's feed. See agent_notes/distribution_plan/sparkle.md.
@MainActor
final class SparkleUpdater: NSObject, AppUpdater {
    static let defaultFeedURL = "https://github.com/rsperko/keyscribe/releases/latest/download/appcast.xml"

    var onUpdateAvailable: (@MainActor () -> Void)?

    private let feedURL: String
    private var controller: SPUStandardUpdaterController!

    init(feedURL: String = SparkleUpdater.defaultFeedURL) {
        self.feedURL = feedURL
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func performUpdate() {
        controller.checkForUpdates(nil)
    }

    // Sparkle's own scheduler drives the update cadence; the per-dictation lifecycle hook is a no-op.
    func dictationDidFinish() {}
}

extension SparkleUpdater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURL }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { onUpdateAvailable?() }
    }
}
#endif
