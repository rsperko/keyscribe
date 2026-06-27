import Foundation

// Optional, injected update mechanism. KeyScribe itself ships no updater (public updates go through
// Homebrew); this is a UI-agnostic seam so a build can run its own update check off the existing
// lifecycle without editing it. Default is no updater injected, in which case nothing here runs.
@MainActor
public protocol AppUpdater: AnyObject {
    // Called after each dictation finishes; the implementation decides whether it is time to check.
    func dictationDidFinish()

    // Set by the host. The updater invokes it when an update becomes available so the host can
    // surface a passive affordance.
    var onUpdateAvailable: (@MainActor () -> Void)? { get set }

    // Invoked when the user activates the host's "Update…" affordance.
    func performUpdate()
}
