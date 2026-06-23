import AppKit

@MainActor
enum InstalledApps {
    struct Info: Identifiable, Hashable {
        let bundleId: String
        let name: String
        var id: String { bundleId }
    }

    static func running() -> [Info] {
        var seen = Set<String>()
        var apps: [Info] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleId = app.bundleIdentifier, seen.insert(bundleId).inserted else { continue }
            apps.append(Info(bundleId: bundleId, name: app.localizedName ?? bundleId))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Bundle id → name/icon barely changes while Settings is open, but a constraint row re-resolves
    // both via LaunchServices + a fresh NSImage on every re-render. Memoize per bundle id.
    private static var nameCache: [String: String?] = [:]
    private static var iconCache: [String: NSImage?] = [:]

    static func name(forBundleId bundleId: String) -> String? {
        if let cached = nameCache[bundleId] { return cached }
        let resolved = resolveName(forBundleId: bundleId)
        nameCache[bundleId] = resolved
        return resolved
    }

    private static func resolveName(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.localizedName
        }
        let display = FileManager.default.displayName(atPath: url.path)
        let trimmed = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        return trimmed.isEmpty ? nil : trimmed
    }

    static func icon(forBundleId bundleId: String) -> NSImage? {
        if let cached = iconCache[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleId] = icon
        return icon
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
        let display = FileManager.default.displayName(atPath: url.path)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        return Info(bundleId: bundleId, name: name.isEmpty ? bundleId : name)
    }
}
