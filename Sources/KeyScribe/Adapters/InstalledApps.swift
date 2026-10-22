import AppKit
import KeyScribeKit

@MainActor
enum InstalledApps {
    struct Info: Identifiable, Hashable {
        let bundleId: String
        let name: String
        var id: String { bundleId }
    }

    static func running() -> [Info] {
        runningApps().map { Info(bundleId: $0.bundleId, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func runningApps() -> [VoiceCommandCatalog.App] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        var copies: [String: [NSRunningApplication]] = [:]
        var order: [String] = []
        for app in regular {
            guard let bundleId = app.bundleIdentifier else { continue }
            if copies[bundleId] == nil { order.append(bundleId) }
            copies[bundleId, default: []].append(app)
        }
        return order.compactMap { bundleId in copies[bundleId].flatMap(preferredCopy).map(app(for:)) }
    }

    static func runningBundleURLs() -> [String: URL] {
        var copies: [String: [NSRunningApplication]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleId = app.bundleIdentifier else { continue }
            copies[bundleId, default: []].append(app)
        }
        return copies.compactMapValues { preferredCopy($0)?.bundleURL }
    }

    static func app(forBundleId bundleId: String) -> VoiceCommandCatalog.App? {
        if let running = preferredCopy(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)) {
            return app(for: running)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return AppNames.app(at: url, bundleId: bundleId)
    }

    private static func app(for running: NSRunningApplication) -> VoiceCommandCatalog.App {
        let bundleId = running.bundleIdentifier ?? ""
        return running.bundleURL.flatMap { AppNames.app(at: $0, bundleId: bundleId) }
            ?? AppNaming.app(bundleId: bundleId, names: [running.localizedName])
    }

    private static func preferredCopy(_ copies: [NSRunningApplication]) -> NSRunningApplication? {
        copies.filter { !$0.isTerminated }.min { a, b in
            let (pathA, pathB) = (a.bundleURL?.path ?? "", b.bundleURL?.path ?? "")
            return pathA != pathB ? pathA < pathB : a.processIdentifier < b.processIdentifier
        }
    }

    private static let nameTTL: TimeInterval = 60
    private static var nameCache: [String: (name: String?, loadedAt: Date)] = [:]
    private static var iconCache: [String: NSImage?] = [:]

    static func name(forBundleId bundleId: String) -> String? {
        if let cached = nameCache[bundleId], Date().timeIntervalSince(cached.loadedAt) < nameTTL { return cached.name }
        let resolved = app(forBundleId: bundleId)?.name
        nameCache[bundleId] = (resolved, Date())
        return resolved
    }

    static func icon(forBundleId bundleId: String) -> NSImage? {
        if let cached = iconCache[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleId] = icon
        return icon
    }

    private static var menuIconCache: [String: NSImage?] = [:]

    static func menuIcon(forBundleId bundleId: String) -> NSImage? {
        if let cached = menuIconCache[bundleId] { return cached }
        let small = icon(forBundleId: bundleId).flatMap { $0.copy() as? NSImage }
        small?.size = NSSize(width: 16, height: 16)
        menuIconCache[bundleId] = small
        return small
    }

    static func chooseFromApplications() -> Info? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleId = Bundle(url: url)?.bundleIdentifier else { return nil }
        let app = self.app(forBundleId: bundleId) ?? AppNames.app(at: url, bundleId: bundleId)
            ?? AppNaming.app(bundleId: bundleId, names: [url.deletingPathExtension().lastPathComponent])
        return Info(bundleId: bundleId, name: app.name)
    }
}

enum AppNames {
    private struct Key: Hashable {
        let path: String
        let bundleId: String
        let preferences: [String]
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: (stamp: Date, app: VoiceCommandCatalog.App?)] = [:]

        func app(_ key: Key, stamp: Date, read: () -> VoiceCommandCatalog.App?) -> VoiceCommandCatalog.App? {
            if let hit = lock.withLock({ entries[key] }), hit.stamp == stamp { return hit.app }
            let app = read()
            lock.withLock { entries[key] = (stamp, app) }
            return app
        }
    }

    nonisolated private static let cache = Cache()

    nonisolated static func app(
        at url: URL, bundleId: String, preferences: [String] = Locale.preferredLanguages
    ) -> VoiceCommandCatalog.App? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date else {
            return nil
        }
        return cache.app(Key(path: url.path, bundleId: bundleId, preferences: preferences), stamp: stamp) {
            read(at: url, bundleId: bundleId, preferences: preferences)
        }
    }

    nonisolated private static func read(at url: URL, bundleId: String, preferences: [String]) -> VoiceCommandCatalog.App? {
        let contents = url.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return nil
        }
        let localized = localizedInfo(
            in: contents.appendingPathComponent("Resources"), preferences: preferences,
            developmentRegion: info["CFBundleDevelopmentRegion"] as? String)
        func value(_ key: String) -> String? {
            AppNaming.usable(localized[key] as? String) ?? AppNaming.usable(info[key] as? String)
        }
        let finder = FileManager.default.displayName(atPath: url.path)
        return AppNaming.app(bundleId: bundleId, names: [
            finder.hasSuffix(".app") ? String(finder.dropLast(4)) : finder,
            value("CFBundleDisplayName"), value("CFBundleName"), url.deletingPathExtension().lastPathComponent,
        ])
    }

    nonisolated static func localization(available: [String], preferences: [String], developmentRegion: String?) -> String? {
        var keys: [String: String] = [:]
        for key in available.sorted() {
            let parts = key.split(separator: "~", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if parts[1] == "mac" { keys[parts[0]] = key }
            } else if keys[key] == nil {
                keys[key] = key
            }
        }
        func language(_ identifier: String) -> Locale.Language {
            Locale.Language(identifier: Locale.canonicalLanguageIdentifier(from: identifier))
        }
        func likely(_ language: Locale.Language) -> Locale.Language {
            Locale.Language(identifier: language.maximalIdentifier)
        }
        for preference in preferences + [developmentRegion ?? "en"] {
            let wanted = language(preference)
            guard let code = wanted.languageCode else { continue }
            let region = wanted.region ?? likely(wanted).region
            let compatible = keys.keys.sorted().filter { identifier in
                let offered = language(identifier)
                return offered.languageCode == code && likely(offered).script == likely(wanted).script
                    && (offered.region == nil || offered.region == region)
            }
            if let match = Bundle.preferredLocalizations(from: compatible, forPreferences: [preference]).first,
               compatible.contains(match) {
                return keys[match]
            }
        }
        return nil
    }

    nonisolated private static func localizedInfo(
        in resources: URL, preferences: [String], developmentRegion: String?
    ) -> [String: Any] {
        let fm = FileManager.default
        let lproj = ((try? fm.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasSuffix(".lproj") && fm.fileExists(atPath: "\(resources.path)/\($0)/InfoPlist.strings") }
            .map { String($0.dropLast(6)) }
        let table = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any] ?? [:]
        let available = Array(Set(lproj).union(table.keys))
        guard let language = localization(available: available, preferences: preferences, developmentRegion: developmentRegion)
        else { return [:] }
        if lproj.contains(language),
           let strings = NSDictionary(contentsOf: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")) as? [String: Any] {
            return strings
        }
        return table[language] as? [String: Any] ?? [:]
    }
}
