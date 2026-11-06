import Darwin
import Foundation
import KeyScribeKit

enum ProcessStart {
    enum Reading: Equatable {
        case started(TimeInterval)
        case gone
        case unknown
    }

    static func read(pid: Int) -> Reading {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .unknown }
        guard size > 0 else { return .gone }
        let start = info.kp_proc.p_starttime
        return .started(TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    static func isRunning(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    static func stillRunning(_ remembered: RememberedName, lead: TimeInterval, reading: (Int) -> Reading = read(pid:)) -> Bool {
        switch reading(remembered.pid) {
        case .unknown: return true
        case .gone: return false
        case .started(let started):
            let recorded = TimeInterval(remembered.startedAt) / 1000
            return started <= recorded + 1 && started >= recorded - lead
        }
    }
}
