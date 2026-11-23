import Foundation
import KeyScribeKit

extension ExtensionAgent {
    static let omp = ExtensionAgent(
        kind: .omp,
        rule: .omp,
        extraFolders: { [$0.appendingPathComponent(".bun/bin").path] },
        minimumVersion: OmpCLI.minimumVersion,
        version: { OmpCLI.version(in: $0) },
        turnedOff: { query in
            let ran = await query.run(["config", "get", "disabledExtensions", "--json"])
            guard case .exited(0) = ran.end, let disabled = OmpCLI.disabledModules(ran.text) else { return .unknown(unreadableConfig(ran)) }
            return disabled.contains(query.pluginDir.lastPathComponent) ? .yes : .no
        },
        recognizedFiles: ["config.yml", "models.yml", "agent.db", "extensions", "sessions"],
        wording: .init(
            disabledAdvice: "Turn the extension back on in omp\u{2019}s /extensions.", updateStep: "Run omp update",
            minimumReason: "no older omp has been checked with it",
            foldersHelp: "A configuration folder is where omp loads its settings from: \(AgentProcesses.Rule.omp.defaultSetup), or the folder \(AgentProcesses.Rule.omp.setupVariable) names. \(Branding.appName) lists the default folder, the folders its connector is installed in, the folders open conversations use, and the one your login shell sets. A conversation started with --profile uses that profile\u{2019}s own folder, which \(Branding.appName) learns once the conversation connects; choose Add Folder\u{2026} to install the connector there. If another agent reads the same folder, each agent\u{2019}s connector works only in that agent."))
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
