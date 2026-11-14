import Darwin
import Foundation
import KeyScribeKit

enum ProcessStart {
    enum Reading: Equatable {
        case started(milliseconds: Int)
        case gone
        case unknown
    }

    static func read(pid: Int) -> Reading {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .unknown }
        guard size > 0 else { return .gone }
        return .started(milliseconds: milliseconds(info.kp_proc.p_starttime))
    }

    static func milliseconds(_ start: timeval) -> Int {
        Int(start.tv_sec) * 1000 + Int(start.tv_usec) / 1000
    }

    static func isRunning(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    static func stillRunning(_ remembered: RememberedName, lead: TimeInterval, reading: (Int) -> Reading = read(pid:)) -> Bool {
        guard let pid = remembered.pid else { return false }
        switch reading(pid) {
        case .unknown: return true
        case .gone: return false
        case .started(let started):
            return started <= remembered.startedAt + 1000 && started >= remembered.startedAt - Int(lead * 1000)
        }
    }
}
