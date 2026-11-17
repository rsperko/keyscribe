import AppKit
import Foundation
import KeyScribeKit

enum BBBuildFinder {
    nonisolated static func describe(folder: String) -> BBBuild? {
        let files = FileManager.default
        let launcher = (folder as NSString).appendingPathComponent(BBBuilds.launcherPath)
        guard files.isExecutableFile(atPath: launcher) else { return nil }
        let runtime = files.contents(atPath: (folder as NSString).appendingPathComponent(BBBuilds.runtimeFile))
        let script = files.contents(atPath: launcher).map { String(decoding: $0.prefix(16_384), as: UTF8.self) }
        let app = BBBuilds.app(runtime: runtime, launcher: script)
        let info = app.flatMap { NSDictionary(contentsOfFile: ($0 as NSString).appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
        return BBBuild(folder: folder, app: app, bundle: info?["CFBundleIdentifier"] as? String, name: BBBuilds.name(info: info))
    }

    nonisolated static func find(home: String, apps: [URL], also: [String] = []) -> [BBBuild] {
        let usual = (home as NSString).appendingPathComponent(BBBuilds.usualFolder)
        let declared = apps.compactMap { app in
            BBBuilds.dataFolder(
                environment: (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["LSEnvironment"] as? [String: Any],
                home: home)
        }
        let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".") }.sorted().map { (home as NSString).appendingPathComponent($0) }
        var seen: Set<String> = []
        return ([usual] + declared + also + hidden).compactMap { path in
            let folder = ConnectorFolders.canonical(URL(fileURLWithPath: path)).path
            guard seen.insert(folder).inserted, isDataFolder(folder) else { return nil }
            return describe(folder: folder)
        }
    }

    nonisolated static func isDataFolder(_ folder: String) -> Bool {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: (folder as NSString).appendingPathComponent(BBBuilds.launcherPath)) else { return false }
        return [BBBuilds.runtimeFile, BBBuilds.threadStorage].contains { files.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
    }

    @MainActor static var runningApps: [URL] { NSWorkspace.shared.runningApplications.compactMap(\.bundleURL) }

    @MainActor static func runningApp(_ build: BBBuild) -> NSRunningApplication? {
        guard let bundle = build.bundle else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    @MainActor static func isOpen(_ build: BBBuild) -> Bool { runningApp(build) != nil }

    @MainActor static func bringForward(_ build: BBBuild) {
        guard let running = runningApp(build) else { return }
        _ = AppActivation.bringForward(pid: running.processIdentifier)
    }

    @MainActor static func frontmost(among bundles: Set<String>) -> AgentHostApp? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let bundle = running.bundleIdentifier, bundles.contains(bundle) else {
            return AgentHostApp(bundle: running.bundleIdentifier ?? "", pid: Int(running.processIdentifier), name: running.localizedName ?? "")
        }
        return AgentFront.frontmost().map { AgentHostApp(bundle: $0.bundle, pid: $0.pid, name: $0.name, window: $0.window) }
    }
}
