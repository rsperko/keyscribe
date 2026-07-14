import AppKit
import CoreGraphics

// The dictation trigger is a bare `flagsChanged` session event tap, so a modifier used to wake/unlock
// the machine (e.g. Fn/Globe) reaches the tap around the moment the login window still owns the
// console — starting a dictation while locked. This lets the start path refuse, and cancels an
// in-flight dictation the instant the screen locks.
@MainActor
final class SessionLockMonitor {
    // Absent dictionary/key ⇒ assume unlocked, so a machine that can't report never wedges dictation;
    // the distributed-notification flag below is the live secondary signal.
    static func isSessionLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        if let locked = info["CGSSessionScreenIsLocked" as String] as? Bool, locked { return true }
        return false
    }

    private(set) var locked: Bool
    private let onLock: () -> Void
    // Written only in init, read only in deinit — safe to reach from the nonisolated deinit without
    // tripping strict-concurrency isolation.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(onLock: @escaping () -> Void) {
        self.onLock = onLock
        self.locked = SessionLockMonitor.isSessionLocked()
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(center.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLocked(true) }
            })
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            observers.append(center.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLocked(false) }
            })
        }
    }

    private func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value { onLock() }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
    }
}
