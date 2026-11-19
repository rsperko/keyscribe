import AppKit
import Foundation
import KeyScribeKit

enum HostFront {
    @MainActor static func app() -> AgentHostApp? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        return AgentHostApp(
            bundle: running.bundleIdentifier ?? "", pid: Int(running.processIdentifier), name: running.localizedName ?? "",
            path: running.bundleURL.map { ConnectorFolders.canonical($0).path })
    }

    @MainActor static func window() -> (app: AgentHostApp, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              let title = ContextProbe.focusedWindowTitle(pid: app.processIdentifier)
        else { return nil }
        let window = ContextProbe.focusedState(pid: app.processIdentifier).windowId
        return (AgentHostApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle, window: window), title)
    }
}
