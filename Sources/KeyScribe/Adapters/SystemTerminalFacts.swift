import AppKit
import Darwin
import Foundation
import KeyScribeKit

struct SystemTerminalFacts: TerminalFacts {
    func process(_ pid: Int) -> TerminalProcess? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let (executable, arguments, environment) = Self.arguments(of: pid)
        return TerminalProcess(
            pid: pid, parent: Int(info.kp_eproc.e_ppid), tty: Self.tty(info.kp_eproc.e_tdev), arguments: arguments,
            environment: environment, executable: executable, app: Self.app(pid))
    }

    func processes(named name: String) -> [TerminalProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 && Self.name(of: $0) == name }.compactMap { process(Int($0)) }
    }

    func run(_ argv: [String]) -> (status: Int32, output: String) {
        let (status, output) = ClaudeCLI.run(argv, timeout: 3)
        return (status, output)
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func tty(_ device: dev_t) -> String? {
        guard device != -1, device != 0, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func app(_ pid: Int) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular else { return nil }
        return app.bundleIdentifier
    }

    static func arguments(of pid: Int) -> (executable: String, arguments: [String], environment: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ("", [], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return ("", [], [:]) }
        return parse(procargs: Array(buffer.prefix(size)))
    }

    static func parse(
        procargs buffer: [UInt8], keeping keys: Set<String> = TerminalRoutes.environmentKeys
    ) -> (executable: String, arguments: [String], environment: [String: String]) {
        guard buffer.count > MemoryLayout<Int32>.size else { return ("", [], [:]) }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        func string() -> String? {
            guard index < buffer.count else { return nil }
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            defer { index = end + 1 }
            return String(decoding: buffer[index..<end], as: UTF8.self)
        }
        let executable = string() ?? ""
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, let argument = string() { arguments.append(argument) }
        var environment: [String: String] = [:]
        while let entry = string(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "="), keys.contains(String(entry[..<equals])) else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (executable, arguments, environment)
    }
}
