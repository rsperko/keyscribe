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
        let tty = Self.tty(info.kp_eproc.e_tdev)
        let foreground = tty == nil || (info.kp_eproc.e_pgid == info.kp_eproc.e_tpgid && Int32(info.kp_proc.p_stat) != SSTOP)
        return TerminalProcess(
            pid: pid, parent: Int(info.kp_eproc.e_ppid), tty: tty, arguments: arguments,
            environment: environment, executable: executable, app: Self.app(pid), foreground: foreground)
    }

    func processes(named name: String) -> [TerminalProcess]? {
        guard let count = Self.listed({ proc_listallpids(nil, 0) }) else { return nil }
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count * 2)
        guard let filled = Self.listed({ proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)) }) else { return nil }
        return pids.prefix(filled).filter { $0 > 0 && Self.name(of: $0) == name }.compactMap { process(Int($0)) }
    }

    static func listed(_ list: () -> Int32) -> Int? {
        errno = 0
        let count = list()
        guard count > 0 || (count == 0 && errno == 0) else { return nil }
        return Int(count)
    }

    func processes(onTTY tty: String) -> [TerminalProcess]? {
        var status = stat()
        guard stat(tty, &status) == 0, (status.st_mode & S_IFMT) == S_IFCHR else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(status.st_rdev))]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        guard size > 0 else { return [] }
        size += size / 2
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return nil }
        var found: [TerminalProcess] = []
        for entry in entries.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = entry.kp_proc.p_pid
            if let process = process(Int(pid)) {
                if process.tty == tty { found.append(process) }
            } else if kill(pid, 0) == 0 || errno == EPERM {
                return nil
            }
        }
        return found
    }

    func children(of pid: Int) -> [TerminalProcess]? {
        guard let count = Self.listed({ proc_listchildpids(pid_t(pid), nil, 0) }) else { return nil }
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count * 2)
        guard let filled = Self.listed({ proc_listchildpids(pid_t(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)) }) else { return nil }
        var found: [TerminalProcess] = []
        for child in pids.prefix(filled) where child > 0 {
            if let process = process(Int(child)) {
                if process.parent == pid { found.append(process) }
            } else if kill(child, 0) == 0 || errno == EPERM {
                return nil
            }
        }
        return found
    }

    func socketOwners(in directory: String) -> [String: Int]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        var owners: [String: Int] = [:]
        for name in names {
            if let pid = Self.listener(at: (directory as NSString).appendingPathComponent(name)) { owners[name] = pid }
        }
        return owners
    }

    private static func listener(at path: String) -> Int? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return Int(pid)
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
