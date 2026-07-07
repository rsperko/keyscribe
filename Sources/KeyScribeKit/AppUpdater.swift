import Foundation

// Optional, injected update mechanism. The UI is wired to a passive update affordance; builds that
// do not inject an updater keep it inert.
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
