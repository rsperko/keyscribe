import Darwin
import Foundation
import KeyScribeKit
import os

enum HardwareActivity {
    private static let log = OSAllocatedUnfairLock(initialState: ActivityLog())

    static func begin(_ kind: ActivityLog.Kind) -> Int {
        log.withLock { $0.begin(kind, at: Date()) }
    }

    static func end(_ id: Int) {
        log.withLock { $0.end(id, at: Date()) }
    }

    static func overlaps(from start: Date, to end: Date) -> [ActivityLog.Kind: TimeInterval] {
        log.withLock { $0.overlaps(from: start, to: end, now: Date()) }
    }
}

enum SystemConditions {
    private static let pressure = OSAllocatedUnfairLock(initialState: "normal")

    private static let watching: Void = {
        let watcher = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        watcher.setEventHandler {
            let event = watcher.data
            let level = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            pressure.withLock { $0 = level }
        }
        watcher.resume()
    }()

    static func start() {
        watching
    }

    static var memoryPressure: String { pressure.withLock { $0 } }

    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static var appMemoryMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    static var loadAverage: Double? {
        var loads = [Double](repeating: 0, count: 1)
        return getloadavg(&loads, 1) == 1 ? loads[0] : nil
    }

    static var appUptime: TimeInterval {
        guard case .started(let milliseconds) = ProcessStart.read(pid: Int(getpid())) else { return 0 }
        return Date().timeIntervalSince1970 - Double(milliseconds) / 1000
    }
}
