import Foundation
import KeyScribeKit

extension ExtensionAgent {
    static let omp = ExtensionAgent(
        kind: .omp,
        rule: .omp,
        toolProgram: "omp",
        extensionName: { "\($0)-omp" },
        defaultFolder: { $0.appendingPathComponent(".omp/agent", isDirectory: true) },
        extraFolders: { [$0.appendingPathComponent(".bun/bin").path] },
        minimumVersion: OmpCLI.minimumVersion,
        version: { OmpCLI.version(in: $0) },
        turnedOff: { query in
            let ran = await query.run(["config", "get", "disabledExtensions", "--json"])
            guard case .exited(0) = ran.end, let disabled = OmpCLI.disabledModules(ran.text) else { return .unknown(unreadableConfig(ran)) }
            return disabled.contains(query.pluginDir.lastPathComponent) ? .yes : .no
        },
        recognizedFiles: ["config.yml", "models.yml", "agent.db", "extensions", "sessions"],
        copy: AgentConnectorCopy(
            help: "\(Branding.appName) reaches omp through a small extension installed in the folder omp loads its configuration from. Installed means the extension is in place; each conversation using this folder then connects on its own, unless you disconnect it.",
            reloadHint: "Already running omp here? Restart each open conversation to connect it.",
            uninstallTitle: "Uninstall the omp connector from this folder?",
            uninstallMessage: "omp conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you restart it. Other folders stay connected. The folder, its conversations, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
            toolNotFoundLabel: "omp not found",
            toolNotFoundAdvice: "Install omp, or choose the omp command yourself. \(Branding.appName) looked for it in a running conversation, your login shell\u{2019}s PATH, its own PATH, and the usual install folders.",
            toolNotWorkingLabel: "omp not working",
            unavailable: "This copy of \(Branding.appName) is missing its omp connector. Reinstall \(Branding.appName) to connect omp.",
            disabledLabel: "Turned off in omp",
            disabledAdvice: "Turn the extension back on in omp\u{2019}s /extensions.",
            removalUnfinishedAdvice: "The connector was uninstalled in \(Branding.appName), but its folder is still in omp\u{2019}s extensions. Its conversations no longer connect. Finish uninstalling it, then install it again if you want it back.",
            listUnreadable: "omp\u{2019}s extensions folder could not be read.",
            noReason: "omp did not say why.",
            manualUninstallLead: "To remove the connector from omp, delete its folder in a terminal, then restart each open conversation:",
            manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Delete the connector\u{2019}s folder in a terminal to finish uninstalling, then restart each open conversation:",
            stillConnected: { count in
                count == 1
                    ? "The connector was removed outside \(Branding.appName), so 1 open conversation is still connected and keeps receiving what you say until you restart it."
                    : "The connector was removed outside \(Branding.appName), so \(count) open conversations are still connected and keep receiving what you say until you restart them."
            },
            toolTooOldLabel: "omp too old",
            toolTooOldAdvice: { found in
                "omp \(found) is older than \(ExtensionAgent.describe(OmpCLI.minimumVersion)), the first version the connector works with. Run omp update, then come back here."
            },
            foldersHelp: "A configuration folder is where omp loads its settings from: ~/.omp/agent, or the folder \(AgentProcesses.Rule.omp.setupVariable) names. \(Branding.appName) lists the default folder, the folders its connector is installed in, the folders open conversations use, and the one your login shell sets. A conversation started with --profile uses that profile\u{2019}s own folder, which \(Branding.appName) learns once the conversation connects; choose Add Folder\u{2026} to install the connector there. If another agent reads the same folder, each agent\u{2019}s connector works only in that agent."))
}

private func unreadableConfig(_ ran: ToolCLI.Ran) -> String {
    let lead = "omp couldn\u{2019}t say whether the connector is turned off"
    let said = ran.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
    return switch ran.end {
    case .exited(0): "\(lead): omp config get disabledExtensions gave an answer \(Branding.appName) can\u{2019}t read."
    case .exited(let status): "\(lead): omp config get disabledExtensions stopped with exit code \(status)" + (said.isEmpty ? "." : ": \(said)")
    case .signaled(let signal): "\(lead): omp config get disabledExtensions was stopped by signal \(signal)."
    case .timedOut(let seconds): "\(lead): omp config get disabledExtensions did not finish within \(seconds) seconds."
    case .couldNotStart(let reason): "\(lead): \(reason)"
    }
}
