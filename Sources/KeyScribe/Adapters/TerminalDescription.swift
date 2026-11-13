import AppKit
import KeyScribeKit

enum TerminalDescription {
    static func describe(pid: Int, surfaces: ResolvedSurfaces) -> String? {
        let facts = SystemTerminalFacts(environmentKeys: surfaces.environmentKeys)
        let (app, multiplexers) = TerminalRoutes.layers(of: TerminalRoutes.plan(agent: pid, facts: facts, routes: surfaces.routes))
        let name = app.flatMap { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent
        }
        let parts = [name].compactMap(\.self) + multiplexers
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
