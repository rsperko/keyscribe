#if canImport(Sparkle)
import Foundation
import KeyScribeKit
import Sparkle

// Production-only auto-updater. Compiled only when Sparkle is linked (KEYSCRIBE_SPARKLE=1) and
// constructed only for the .production variant (main.swift). The feed URL is set programmatically here,
// never as SUFeedURL in Info.plist, so a copied plist cannot point a downstream build at KeyScribe's feed.
@MainActor
final class SparkleUpdater: NSObject, AppUpdater {
    // Served from the default branch (raw), NOT a GitHub Release asset: pre-1.0 releases are marked
    // --prerelease, and GitHub's /releases/latest/ path excludes prereleases, so a release-asset feed
    // would 404 until 1.0. The raw-branch feed is prerelease-agnostic and needs no extra infra.
    static let defaultFeedURL = "https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml"

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
