import SwiftUI

struct VoiceCommandNotices {
    enum Kind: String, CaseIterable {
        case apps, places, scripts, shortcuts

        var title: String {
            switch self {
            case .apps: "Voice commands can switch apps"
            case .places: "This place opens when its name is heard"
            case .scripts: "This script runs when its name is heard"
            case .shortcuts: "This shortcut runs when its name is heard"
            }
        }

        var message: String {
            switch self {
            case .apps:
                "Voice recognition can make mistakes and open or switch to an unintended app. Its open windows may become visible, and your next keystrokes will go there. Keep this in mind when sharing your screen."
            case .places:
                "Voice recognition can mishear a name and open this place when you meant another. An app comes to the front with its open windows, a web page loads in your browser, and your next keystrokes go there. Keep this in mind when sharing your screen."
            case .scripts:
                "Voice recognition can mishear a name and start this script, or pass it different words than you said. It runs with your account’s permissions and can change or delete your files. For actions that cannot be undone, use a script that asks for confirmation."
            case .shortcuts:
                "Voice recognition can mishear a name and start this shortcut, or give it different words than you said. Depending on its steps, a shortcut can send messages, change or delete files, or send your words to online services. For actions that cannot be undone, add a step that asks for confirmation."
            }
        }
    }

    private let defaults: UserDefaults
    private let key: String

    init(supportDir: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "voiceCommandNotices.\(supportDir.standardizedFileURL.path)"
    }

    func needsAcknowledgment(_ kind: Kind) -> Bool {
        !(defaults.dictionary(forKey: key)?[kind.rawValue] as? Bool ?? false)
    }

    func acknowledge(_ kind: Kind) {
        var acknowledged = defaults.dictionary(forKey: key) ?? [:]
        acknowledged[kind.rawValue] = true
        defaults.set(acknowledged, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

struct VoiceCommandNoticeRow: View {
    let kind: VoiceCommandNotices.Kind
    let needsAcknowledgment: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureSection(isExpanded: $expanded, hasWarning: needsAcknowledgment) {
            Text(kind.title)
        } content: {
            if needsAcknowledgment {
                IssueText(kind.message, severity: .advisory, font: .callout)
            } else {
                Text(kind.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
