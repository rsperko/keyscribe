import AppKit
import Foundation

// Headless dev mode: `KeyScribe --benchmark <dir>` runs the STT benchmark and exits without launching
// the menu-bar app. Anything else is a normal app launch.
if let i = CommandLine.arguments.firstIndex(of: "--benchmark"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await BenchmarkRunner.run(dir: dir, only: only)
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
