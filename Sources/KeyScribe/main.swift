import AppKit
import Foundation

// Headless dev mode: `KeyScribe --reset <onboarding|modes|config|all>` clears local state and exits.
if let i = CommandLine.arguments.firstIndex(of: "--reset") {
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
    guard let target = ResetTarget(rawValue: arg) else {
        FileHandle.standardError.write(Data("""
        Usage: KeyScribe --reset <target>
          onboarding  Clear the first-run flag (replays the wizard only if a TCC permission is missing).
          modes       Re-seed the starter modes (discards edits to default modes).
          config      Wipe config/modes/fragments but keep downloaded models, and clear the first-run flag.
          all         Remove the whole support dir (including models) and clear the first-run flag.\n
        """.utf8))
        exit(2)
    }
    let actions = ResetTool(supportDir: KeyScribePaths.supportDir, defaults: .standard).run(target)
    for line in actions { print(line) }
    if target != .modes {
        let granted = Permissions.microphoneStatus() == .granted
            && Permissions.accessibilityStatus() == .granted
        if granted {
            print("Note: TCC permissions are all granted, so the first-run wizard will be skipped. "
                + "To replay it, revoke a permission first: tccutil reset Accessibility com.keyscribe.app")
        }
    }
    exit(0)
}

// Headless dev mode: `KeyScribe --benchmark <dir>` runs the STT benchmark and exits without launching
// the menu-bar app. Anything else is a normal app launch.
if let i = CommandLine.arguments.firstIndex(of: "--benchmark"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var only: Set<String>?
    if let e = CommandLine.arguments.firstIndex(of: "--engines"), e + 1 < CommandLine.arguments.count {
        only = Set(CommandLine.arguments[e + 1].split(separator: ",").map(String.init))
    }
    let raw = CommandLine.arguments.contains("--raw")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await BenchmarkRunner.run(dir: dir, only: only, raw: raw)
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
