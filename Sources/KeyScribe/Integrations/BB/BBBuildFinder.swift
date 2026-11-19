import AppKit
import Foundation
import os
import KeyScribeKit

enum BBBuildFinder {
    private struct Declaration {
        var modified: timespec?
        var folder: String?
    }

    nonisolated static func describe(folder: String, home: String) -> BBBuild? { describe(folder: folder, apps: runningApps, home: home) }

    nonisolated static func describe(folder: String, apps: [URL], home: String) -> BBBuild? {
        let files = FileManager.default
        let launcher = (folder as NSString).appendingPathComponent(BBBuilds.launcherPath)
        guard files.isExecutableFile(atPath: launcher) else { return nil }
        let target = canonical(folder)
        let running = apps.map { canonical($0.path) }
        let recordedApp = {
            let runtime = files.contents(atPath: (folder as NSString).appendingPathComponent(BBBuilds.runtimeFile))
            let script = files.contents(atPath: launcher).map { String(decoding: $0.prefix(16_384), as: UTF8.self) }
            return BBBuilds.app(runtime: runtime, launcher: script).map(canonical)
        }
        let app = declarer(of: target, among: running.sorted(), home: home) ?? {
            let recorded = recordedApp()
            return recorded.flatMap { running.contains($0) ? $0 : nil }
                ?? declarer(of: target, among: remembered(declaring: target).subtracting(running).sorted(), home: home)
                ?? recorded
        }()
        let info = app.flatMap { NSDictionary(contentsOfFile: ($0 as NSString).appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
        return BBBuild(folder: folder, app: app, bundle: info?["CFBundleIdentifier"] as? String, name: BBBuilds.name(info: info, app: app))
    }

    nonisolated private static func declarer(of folder: String, among apps: [String], home: String) -> String? {
        apps.first { declaration(of: $0, home: home).folder == folder }
    }

    nonisolated private static func remembered(declaring folder: String) -> Set<String> {
        Set(declarations.withLock { $0.filter { $0.value.folder == folder }.map(\.key.app) })
    }

    nonisolated private static let canonicalPaths = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    nonisolated private static func canonical(_ path: String) -> String {
        if let known = canonicalPaths.withLock({ $0[path] }) { return known }
        let resolved = ConnectorFolders.canonical(URL(fileURLWithPath: path)).path
        canonicalPaths.withLock { $0[path] = resolved }
        return resolved
    }

    nonisolated static func find(home: String, apps: [URL], also: [String] = []) -> [BBBuild] {
        let usual = (home as NSString).appendingPathComponent(BBBuilds.usualFolder)
        let declared = apps.compactMap { declaredFolder(app: canonical($0.path), home: home) }
        let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".") }.sorted().map { (home as NSString).appendingPathComponent($0) }
        var seen: Set<String> = []
        return ([usual] + declared + also + hidden).compactMap { path in
            let folder = ConnectorFolders.canonical(URL(fileURLWithPath: path)).path
            guard seen.insert(folder).inserted, isDataFolder(folder) else { return nil }
            return describe(folder: folder, apps: apps, home: home)
        }
    }

    nonisolated static func declaredFolder(app: String, home: String) -> String? { declaration(of: app, home: home).folder }

    nonisolated static func isDataFolder(_ folder: String) -> Bool {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: (folder as NSString).appendingPathComponent(BBBuilds.launcherPath)) else { return false }
        return [BBBuilds.runtimeFile, BBBuilds.threadStorage].contains { files.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
    }

    nonisolated static var runningApps: [URL] { NSWorkspace.shared.runningApplications.compactMap(\.bundleURL) }

    private struct DeclarationKey: Hashable {
        var app: String
        var home: String
    }

    nonisolated private static let declarations = OSAllocatedUnfairLock<[DeclarationKey: Declaration]>(initialState: [:])

    nonisolated private static func declaration(of app: String, home: String) -> Declaration {
        let plist = (app as NSString).appendingPathComponent("Contents/Info.plist")
        var info = stat()
        let modified = stat(plist, &info) == 0 ? info.st_mtimespec : nil
        let key = DeclarationKey(app: app, home: home)
        if let known = declarations.withLock({ $0[key] }),
           known.modified?.tv_sec == modified?.tv_sec, known.modified?.tv_nsec == modified?.tv_nsec { return known }
        let contents = NSDictionary(contentsOfFile: plist) as? [String: Any]
        let found = Declaration(
            modified: modified,
            folder: BBBuilds.dataFolder(environment: contents?["LSEnvironment"] as? [String: Any], home: home).map(canonical))
        declarations.withLock { $0[key] = found }
        return found
    }

    @MainActor static func runningApp(_ build: BBBuild) -> NSRunningApplication? {
        sharingIdentity(build) ?? declaring(build.folder)
    }

    @MainActor private static func declaring(_ folder: String) -> NSRunningApplication? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = canonical(folder)
        return NSWorkspace.shared.runningApplications
            .compactMap { app in app.bundleURL.map { (app, canonical($0.path)) } }
            .sorted { $0.1 < $1.1 }
            .first { declaredFolder(app: $0.1, home: home) == target }?.0
    }

    nonisolated static func environment(folder: String, home: String) -> [String: String] {
        BBBuilds.environment(folder: folder, home: home, runtime: runtime(of: folder), started: started)
    }

    nonisolated static func serves(folder: String) -> Bool { BBBuilds.serves(runtime: runtime(of: folder), started: started) }

    nonisolated private static func runtime(of folder: String) -> Data? {
        FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(BBBuilds.runtimeFile))
    }

    nonisolated static func started(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    @MainActor private static func sharingIdentity(_ build: BBBuild) -> NSRunningApplication? {
        guard let bundle = build.bundle else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        guard let app = build.app else { return running.first }
        let paths = running.map { ($0, $0.bundleURL.map { ConnectorFolders.canonical($0).path }) }
        if let exact = paths.first(where: { $0.1 == app }) { return exact.0 }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual = ConnectorFolders.canonical(URL(fileURLWithPath: (home as NSString).appendingPathComponent(BBBuilds.usualFolder))).path
        let target = canonical(build.folder)
        return paths.first { _, path in path.map { (declaredFolder(app: $0, home: home) ?? usual) == target } ?? false }?.0
    }

    @MainActor static func isOpen(_ build: BBBuild) -> Bool { runningApp(build) != nil }

    @MainActor static func watchLaunches(_ changed: @escaping @MainActor (_ app: String, _ launched: Bool) -> Void) -> BBHost.StopWatching {
        let center = NSWorkspace.shared.notificationCenter
        let observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL else { return }
                let path = canonical(url.path)
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { changed(path, launched) }
            }
        }
        nonisolated(unsafe) let tokens = observers
        return { tokens.forEach(center.removeObserver) }
    }

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
