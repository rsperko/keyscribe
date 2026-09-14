import Foundation
import KeyScribeKit
import Sparkle

// The public build's auto-updater. Linked only by the public app target (App/project.yml) and constructed
// only for the .production variant (Sources/KeyScribeMain/main.swift). The feed URL is set programmatically
// here, never as SUFeedURL in Info.plist, so a copied plist cannot point a downstream build at KeyScribe's feed.
@MainActor
public final class SparkleUpdater: NSObject, AppUpdater {
    // Served from the default branch (raw), NOT a GitHub Release asset: pre-1.0 releases are marked
    // --prerelease, and GitHub's /releases/latest/ path excludes prereleases, so a release-asset feed
    // would 404 until 1.0. The raw-branch feed is prerelease-agnostic and needs no extra infra.
    public static let defaultFeedURL = "https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml"

    public var onUpdateAvailable: (@MainActor () -> Void)?

    private let feedURL: String
    private var controller: SPUStandardUpdaterController!

    public init(feedURL: String = SparkleUpdater.defaultFeedURL) {
        self.feedURL = feedURL
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    public func performUpdate() {
        controller.checkForUpdates(nil)
    }

    // Sparkle's own scheduler drives the update cadence; the per-dictation lifecycle hook is a no-op.
    public func dictationDidFinish() {}
}

extension SparkleUpdater: SPUUpdaterDelegate {
    public nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURL }
    }

    public nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { onUpdateAvailable?() }
    }
}
