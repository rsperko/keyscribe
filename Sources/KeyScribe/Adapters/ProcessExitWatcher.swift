import Darwin
import Foundation

@MainActor
final class ProcessExitWatcher {
    private var watched: [Int: DispatchSourceProcess?] = [:]
    private let exited: @MainActor () -> Void

    init(exited: @escaping @MainActor () -> Void) {
        self.exited = exited
    }

    func watch(_ pids: Set<Int>) {
        for (pid, source) in watched where !pids.contains(pid) {
            source?.cancel()
            watched[pid] = nil
        }
        var gone = false
        for pid in pids where pid > 0 && watched[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.ended(pid) } }
            source.resume()
            watched[pid] = source
            if kill(pid_t(pid), 0) != 0, errno == ESRCH {
                ended(pid, reporting: false)
                gone = true
            }
        }
        if gone { exited() }
    }

    private func ended(_ pid: Int, reporting: Bool = true) {
        guard let source = watched[pid], let source else { return }
        source.cancel()
        watched[pid] = .some(nil)
        if reporting { exited() }
    }

    isolated deinit {
        for source in watched.values { source?.cancel() }
    }
}
