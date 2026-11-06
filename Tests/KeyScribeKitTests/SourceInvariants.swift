import Foundation

struct SourceRule {
    let pattern: String
    let allowed: [String: Int]
    let reason: String

    func violations(in files: [String: String]) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return files.keys.sorted().flatMap { path -> [String] in
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
            ],
            reason: "History shows summary, facts and steps without vetting them, so only reviewed writers fill them, with "
                + "fixed local strings and names: never an agent reply, a secret, or an environment value."
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
