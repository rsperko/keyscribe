import KeyScribeKit

struct ShortcutMoveCopy {
    let title: String
    let message: String
    let done: String

    init(_ move: ShortcutMove, notice: String?) {
        let key = Self.display(move.claimedKey)
        let destination = move.destination.name
        let losers = Self.list(move.losses.map(\.before.name))
        title = "Use \(key) for \(destination)?"
        var sentences = ["\(losers) \(move.losses.count == 1 ? "uses" : "use") this shortcut."]
        sentences.append(move.destination.runsVoiceCommands
            ? "After the move, pressing \(key) runs voice commands instead of typing your speech."
            : "After the move, pressing \(key) types your speech with \(destination) instead of running voice commands.")
        for loss in move.losses {
            let removed = loss.removed.map { Self.display($0.key) }.filter { $0 != key }
            if !removed.isEmpty { sentences.append("\(loss.before.name) gives up \(Self.list(removed)).") }
            if loss.after.triggerKeys.isEmpty { sentences.append("\(loss.before.name) will have no shortcut.") }
        }
        message = sentences.joined(separator: " ") + (notice.map { "\n\n\($0)" } ?? "")
        done = "Moved \(key) to \(destination) from \(losers)."
    }

    private static func display(_ key: String) -> String {
        (try? KeyDescriptor(parsing: key))?.displayString ?? key
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: names.first ?? ""
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
