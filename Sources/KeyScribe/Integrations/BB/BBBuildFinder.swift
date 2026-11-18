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
        let app = BBBuilds.app(runtime: runtime, launcher: script).map { ConnectorFolders.canonical(URL(fileURLWithPath: $0)).path }
        let info = app.flatMap { NSDictionary(contentsOfFile: ($0 as NSString).appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
        return BBBuild(folder: folder, app: app, bundle: info?["CFBundleIdentifier"] as? String, name: BBBuilds.name(info: info, app: app))
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

    nonisolated static func declaredFolder(app: String, home: String) -> String? {
        let info = NSDictionary(contentsOfFile: (app as NSString).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return BBBuilds.dataFolder(environment: info?["LSEnvironment"] as? [String: Any], home: home)
            .map { ConnectorFolders.canonical(URL(fileURLWithPath: $0)).path }
    }

    nonisolated static func isDataFolder(_ folder: String) -> Bool {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: (folder as NSString).appendingPathComponent(BBBuilds.launcherPath)) else { return false }
        return [BBBuilds.runtimeFile, BBBuilds.threadStorage].contains { files.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
    }

    @MainActor static var runningApps: [URL] { NSWorkspace.shared.runningApplications.compactMap(\.bundleURL) }

    @MainActor private static var declared: [String: (modified: Date?, folder: String?)] = [:]

    @MainActor private static func declaredFolder(cachedFor app: String, home: String) -> String? {
        let plist = (app as NSString).appendingPathComponent("Contents/Info.plist")
        let modified = (try? FileManager.default.attributesOfItem(atPath: plist))?[.modificationDate] as? Date
        if let known = declared[app], known.modified == modified { return known.folder }
        let found = declaredFolder(app: app, home: home)
        declared[app] = (modified, found)
        return found
    }

    @MainActor static func runningApp(_ build: BBBuild) -> NSRunningApplication? {
        guard let bundle = build.bundle else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        guard let app = build.app else { return running.first }
        let paths = running.map { ($0, $0.bundleURL.map { ConnectorFolders.canonical($0).path }) }
        if let exact = paths.first(where: { $0.1 == app }) { return exact.0 }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual = ConnectorFolders.canonical(URL(fileURLWithPath: (home as NSString).appendingPathComponent(BBBuilds.usualFolder))).path
        return paths.first { _, path in path.map { (declaredFolder(cachedFor: $0, home: home) ?? usual) == build.folder } ?? false }?.0
    }

    @MainActor static func isOpen(_ build: BBBuild) -> Bool { runningApp(build) != nil }

    @MainActor static func bringForward(_ build: BBBuild) {
        guard let running = runningApp(build) else { return }
        _ = AppActivation.bringForward(pid: running.processIdentifier)
    }

    @MainActor static func frontApp() -> AgentHostApp? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        return AgentHostApp(
            bundle: running.bundleIdentifier ?? "", pid: Int(running.processIdentifier), name: running.localizedName ?? "",
            path: running.bundleURL.map { ConnectorFolders.canonical($0).path })
    }

    @MainActor static func frontmost(among bundles: Set<String>) -> AgentHostApp? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        let path = running.bundleURL.map { ConnectorFolders.canonical($0).path }
        guard let bundle = running.bundleIdentifier, bundles.contains(bundle) else {
            return AgentHostApp(bundle: running.bundleIdentifier ?? "", pid: Int(running.processIdentifier), name: running.localizedName ?? "", path: path)
        }
        return AgentFront.frontmost().map { AgentHostApp(bundle: $0.bundle, pid: $0.pid, name: $0.name, window: $0.window, path: path) }
    }
}
