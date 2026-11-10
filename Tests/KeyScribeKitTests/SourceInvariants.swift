import Foundation

struct SourceRule: Sendable {
    let pattern: String
    let allowed: [String: Int]
    let reason: String
    var exempt: @Sendable (String) -> Bool = { _ in false }

    func violations(in files: [String: String]) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return files.keys.sorted().filter { !exempt($0) }.flatMap { path -> [String] in
            let hits = files[path]!.components(separatedBy: "\n").enumerated().compactMap { index, line -> String? in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
                let range = NSRange(line.startIndex..., in: line)
                return regex.firstMatch(in: line, range: range) == nil ? nil : "\(path):\(index + 1): \(line)"
            }
            return hits.count > allowed[path, default: 0] ? hits : []
        }
    }
}

enum SourceInvariants {
    static let rules = [
        SourceRule(
            pattern: #"\b(ReplacementsStage|FuzzyStage|NumbersStage|LiveEditsStage)\(|TokenizingStage\.(verbatim|clipboard|redaction)\("#,
            allowed: [
                "Sources/KeyScribeKit/TakeStages.swift": 9,
                "Sources/KeyScribeKit/ReplacementPreview.swift": 2,
            ],
            reason: "Every stage list is assembled by TakeStages, so the lists a take, a preview, and the "
                + "commands check run cannot drift apart; ReplacementPreview compares single rule sets, not a "
                + "pipeline (docs/development/design.md §4.2.1)."
        ),
        SourceRule(
            pattern: #"\bsetSystemDefaultInput\b"#,
            allowed: [
                "Sources/KeyScribe/Adapters/AudioInputDevices.swift": 1,
                "Sources/KeyScribe/Adapters/SystemAudioStateRestorer.swift": 1,
            ],
            reason: "Capture pins its device on its own unit and never changes the macOS default input; only the "
                + "legacy crash-recovery restorer may set it (docs/development/areas/audio-capture.md)."
        ),
        SourceRule(
            pattern: #"\bCGEvent\.tapCreate\("#,
            allowed: [
                "Sources/KeyScribe/Adapters/HotkeyMonitor.swift": 1,
                "Sources/KeyScribe/Adapters/MouseEventTap.swift": 1,
            ],
            reason: "Event taps are created only behind the Accessibility gate in HotkeyMonitor and MouseEventTap; "
                + "a tap created before the grant leaves a denied TCC record "
                + "(docs/development/areas/hotkeys-and-permissions.md)."
        ),
        SourceRule(
            pattern: #"\bhud\??\.render\("#,
            allowed: [
                "Sources/KeyScribe/Take/HUDChannel.swift": 1,
                "Sources/KeyScribe/AppDelegate.swift": 1,
            ],
            reason: "Every HUD draw goes through HUDChannel.present so a pending voice-command question "
                + "stays readable; AppDelegate's one draw is the HUD preview mode (AGENTS.md)."
        ),
        SourceRule(
            pattern: #""[^"]*\bKeyScribe\b[^"]*""#,
            allowed: [
                "Sources/KeyScribeKit/AppVariant.swift": 1,
                "Sources/KeyScribe/ConfigRepository.swift": 1,
            ],
            reason: "User-facing copy interpolates Branding.appName; the literal product name lives only in "
                + "AppVariant.production.displayName, or a downstream rebrand shows the wrong name (AGENTS.md)."
        ),
        SourceRule(
            pattern: #"(?<!self)\.(summary|facts|steps)\s*=[^=]|HistoryEntry\.(Fact|Step)\("#,
            allowed: [
                "Sources/KeyScribe/DictationController.swift": 2,
                "Sources/KeyScribe/Take/AgentOutput.swift": 2,
                "Sources/KeyScribeKit/AgentHistoryFacts.swift": 1,
                "Sources/KeyScribeKit/LiveEditsStage.swift": 1,
            ],
            reason: "History shows summary, facts and steps without vetting them, so only reviewed writers fill them, with "
                + "fixed local strings and names: never an agent reply, a secret, or an environment value."
        ),
        SourceRule(
            pattern: #"(?i)herdr|tmux|zellij|ghostty|iterm|cmux|warp"#,
            allowed: [
                "Sources/KeyScribe/AgentHub.swift": 1,
                "Sources/KeyScribe/DevCLI.swift": 1,
                "Sources/KeyScribeKit/TerminalRoutes/ScriptedTerminalRoute.swift": 1,
                "Sources/KeyScribeKit/TerminalRoutes/TerminalRoutes.swift": 2,
            ],
            reason: "Everything one terminal or multiplexer needs, to focus a conversation or to read the names the user "
                + "gave its place, lives in that surface's files (named for it); shared code speaks Route, PlaceRoute, "
                + "AgentPlace and AgentPlaceReading, so another surface is another adapter, never a branch "
                + "(docs/development/areas/voice-commands.md). The registries and the composition root list the adapters.",
            exempt: { name in
                let file = (name as NSString).lastPathComponent
                return ["Herdr", "Tmux", "Zellij", "Ghostty", "ITerm", "Cmux", "Warp", "TerminalApp"].contains { file.hasPrefix($0) }
            }
        ),
        SourceRule(
            pattern: #"(?i)claude"#,
            allowed: [
                "Sources/KeyScribe/AppDelegate.swift": 2,
                "Sources/KeyScribe/HUD/HUDPreview.swift": 1,
                "Sources/KeyScribe/Settings/SettingsController.swift": 1,
                "Sources/KeyScribeKit/AIServiceCatalog.swift": 1,
                "Sources/KeyScribeKit/Features.swift": 1,
            ],
            reason: "Everything one coding agent needs lives in that agent's adapter files (named for the agent); shared "
                + "code speaks AgentKind, AgentSession, AgentDiscovery and AgentConnector, so another agent is another "
                + "adapter, never a branch (docs/development/areas/voice-commands.md). The composition root wires the "
                + "adapters and names the legacy agent for saved names, and the LLM catalog names a model provider.",
            exempt: { ($0 as NSString).lastPathComponent.hasPrefix("Claude") }
        ),
        SourceRule(
            pattern: #""(PI_CODING_AGENT_DIR|CLAUDE_CONFIG_DIR)""#,
            allowed: [
                "Sources/KeyScribe/Adapters/ClaudeConnector.swift": 1,
                "Sources/KeyScribeKit/PiAgent.swift": 1,
                "Sources/KeyScribeKit/ClaudeRegistry.swift": 1,
            ],
            reason: "An agent's setup folder comes from the conversation's own process, an enrolled setup, or a folder the "
                + "user chose; never from the app's own environment, which differs between a Finder and a terminal launch "
                + "(docs/development/areas/voice-commands.md). Each adapter names its variable once."
        ),
        SourceRule(
            pattern: #"environment\[setupVariable\]"#,
            allowed: [
                "Sources/KeyScribe/Adapters/ClaudeConnector.swift": 1,
                "Sources/KeyScribeKit/AgentProcesses.swift": 1,
            ],
            reason: "A setup variable is read only from a scanned process's environment and written only into the "
                + "environment of a command run for one chosen setup; the app's own environment never picks a setup."
        ),
        SourceRule(
            pattern: #"(?<![.\w])Pi(?![a-z])"#,
            allowed: [
                "Sources/KeyScribe/AppDelegate.swift": 1,
                "Sources/KeyScribe/Settings/SettingsController.swift": 1,
                "Sources/KeyScribeKit/Features.swift": 1,
            ],
            reason: "Everything Pi needs lives in its adapter files (named for it); shared code never names an agent "
                + "(docs/development/areas/voice-commands.md). The composition root wires the adapter, and the feature "
                + "summary names the agents it works with.",
            exempt: { ($0 as NSString).lastPathComponent.hasPrefix("Pi") }
        ),
    ]

    static func swiftFiles(under root: URL, in directory: String) throws -> [String: String] {
        let base = root.appendingPathComponent(directory).resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var files: [String: String] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1))
            files["\(directory)/\(relative)"] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }
}
