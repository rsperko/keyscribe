import SwiftUI

struct VoiceCommandNotices {
    enum Kind: String, CaseIterable {
        case apps, places, sidebars, scripts, shortcuts

        var title: String {
            switch self {
            case .apps: "Using Voice Commands"
            case .places: "A misheard name can open the wrong place"
            case .sidebars: "A misheard name can open the wrong item"
            case .scripts: "Scripts can change your files"
            case .shortcuts: "Check what this shortcut does"
            }
        }

        var message: String {
            switch self {
            case .apps:
                "Use your assigned shortcut to switch apps and windows by voice. You can also add commands that run scripts or Shortcuts.\n\nSpeech recognition can get a name or input wrong. A command may bring an unintended window into view, including during screen sharing, or start a saved action you did not intend.\n\nScripts and Shortcuts you run by voice may act without asking for confirmation. Depending on their steps, they can change files, send messages, or share information."
            case .places:
                "A misheard command can open this place when you meant another. Its app or browser window comes forward, which may reveal its contents during screen sharing. Check which app is active before typing."
            case .sidebars:
                "A misheard item name can open a different channel, person, or mailbox in the app\u{2019}s sidebar. The app\u{2019}s window comes forward, which may reveal its contents during screen sharing."
            case .scripts:
                "Saying this command starts the script with your account’s permissions. A misheard name or input can start the wrong action. Use a script that asks for confirmation before changing or deleting anything you cannot recover."
            case .shortcuts:
                "Saying this command starts the shortcut. A misheard name or input can start the wrong action. Its steps may send messages, change or delete files, or send your words to online services. Add a confirmation step for actions you cannot undo."
            }
        }
    }

    static var actionPermissions: String {
        "Actions start without an extra confirmation from \(Branding.appName). Some run immediately. Others may wait for a dialog:\n\n• macOS may ask for permission the first time an action controls another app or accesses protected data. The dialog may name \(Branding.appName), even when a script caused it. Permission given through Terminal may not apply here.\n\n• Shortcuts may offer Allow Once or Always Allow. Allow Once can ask again next time; Always Allow remembers that permission.\n\n• A script or shortcut may include its own confirmation on every run.\n\nIf an action seems to be waiting, check for an approval dialog."
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
