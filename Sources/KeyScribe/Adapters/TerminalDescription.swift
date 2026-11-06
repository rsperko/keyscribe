import AppKit
import KeyScribeKit

enum TerminalDescription {
    static func describe(pid: Int) -> String? {
        let (app, multiplexers) = TerminalRoutes.layers(of: TerminalRoutes.plan(agent: pid, facts: SystemTerminalFacts()))
        let name = app.flatMap { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent
        }
        let parts = [name].compactMap(\.self) + multiplexers
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
