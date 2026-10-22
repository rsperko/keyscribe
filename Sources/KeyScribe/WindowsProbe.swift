import AppKit
import ApplicationServices
import KeyScribeKit

@MainActor
enum WindowsProbe {
    static func list() -> Int32 {
        print("trusted: \(AXIsProcessTrusted())")
        let total = DispatchTime.now()
        for process in AppWindows.processes(excluding: ProcessInfo.processInfo.processIdentifier, named: InstalledApps.runningApps()) {
            let started = DispatchTime.now()
            let reply = AppWindows.read(pid: process.pid) { true }
            let ms = milliseconds(since: started)
            switch reply {
            case .noResponse:
                print("\(process.bundleId) pid=\(process.pid) no response \(ms)ms")
            case .notTrusted:
                print("\(process.bundleId) pid=\(process.pid) not trusted \(ms)ms")
            case .windows(let windows):
                print("\(process.bundleId) pid=\(process.pid) windows=\(windows.count) \(ms)ms")
                for window in windows {
                    let id = window.number.map { "cg:\($0)" } ?? "none"
                    print("  \(window.subrole ?? "-") id=\(id) minimized=\(window.isMinimized) "
                          + "document=\(window.document == nil ? "no" : "yes") title=\(window.title ?? "")")
                }
            }
        }
        print("total \(milliseconds(since: total))ms")
        return 0
    }

    static func focus(_ spec: String) async -> Int32 {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pid = Int32(parts[0]), parts[1].hasPrefix("cg:"),
              let app = NSRunningApplication(processIdentifier: pid), let bundleId = app.bundleIdentifier else {
            print("usage: --windows-probe --focus <pid>:cg:<id> (a running app's pid and a window id from the listing)")
            return 2
        }
        let window = VoiceCommandCatalog.Window(
            bundleId: bundleId, appName: app.localizedName ?? bundleId, pid: pid, id: parts[1], title: "")
        let started = DispatchTime.now()
        let result = await LiveVoiceCommandSystem.shared.focusWindow(window) { true }
        print("focus: \(result) \(milliseconds(since: started))ms")
        return result == .focused || result == .alreadyFrontmost ? 0 : 1
    }

    private static func milliseconds(since start: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
