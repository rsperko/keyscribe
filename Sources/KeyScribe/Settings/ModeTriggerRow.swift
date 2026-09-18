import AppKit
import SwiftUI
import KeyScribeKit

struct ModeTriggerRow: View {
    let mode: Mode
    let onUpdate: (Mode) -> Void
    var label: String = "Start this mode with"
    var accessibilityID: String = AccessibilityID.Mode.Editor.shortcutWell
    @State private var remembered: Mode.TriggerKey?

    var body: some View {
        LabeledContent(label) {
            ShortcutWell(key: triggerKey, profile: .modeTrigger, accessibilityID: accessibilityID)
        }
    }

    private var triggerKey: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.key ?? "" },
            set: { key in
                var updated = mode
                if let removed = updated.setPrimaryTriggerKey(key, restoring: remembered) { remembered = removed }
                onUpdate(updated)
            })
    }
}

// Pairs with the recorder row but sits in a different container per editor (top-level in the system
// editor, inside the routing disclosure in a normal mode), so callers compose it themselves.
struct PressStyleRow: View {
    let selection: Binding<String>
    let disabled: Bool

    var body: some View {
        Picker("Press behavior", selection: selection) {
            Text(PressStyle.holdOrTap.title).tag(PressStyle.holdOrTap.rawValue)
            Text(PressStyle.holdOnly.title).tag(PressStyle.holdOnly.rawValue)
            Text(PressStyle.tapToToggle.title).tag(PressStyle.tapToToggle.rawValue)
        }
        .disabled(disabled)
        .accessibilityIdentifier(AccessibilityID.Mode.Editor.pressStyle)
        Text(disabled
            ? "Add a shortcut to choose how it starts."
            : (PressStyle(rawValue: selection.wrappedValue) ?? .holdOrTap).instruction)
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct TriggerConflictLabel: View {
    let conflict: TriggerKeyConflict?
    let mode: Mode

    @ViewBuilder var body: some View {
        if let conflict {
            switch conflict.kind {
            case .collision:
                IssueText(prefix(conflict) + "Also used by \(conflict.modeName) in an overlapping context. When both could apply, the more specific mode wins, then the one listed first.",
                          severity: .advisory)
            case .unreachable:
                IssueText(prefix(conflict) + "This shortcut never fires: \(conflict.modeName) already claims the same press, written a different way. Give this mode a different shortcut, or write both the same way.",
                          severity: .failure)
            case .triggerUnreachable:
                IssueText(prefix(conflict) + "This shortcut never fires: \(conflict.modeName) already claims the same press, written a different way. This mode's other shortcuts still start it.",
                          severity: .failure)
            case .masking:
                IssueText(prefix(conflict) + "Pressed on the way into \(conflict.modeName)'s shortcut. Press that one as a single motion, or this mode starts first.",
                          severity: .advisory)
            }
        }
    }

    private func prefix(_ conflict: TriggerKeyConflict) -> String {
        guard !conflict.triggerKey.isEmpty,
              conflict.triggerKey != mode.triggerKeys.first?.key,
              let descriptor = try? KeyDescriptor(parsing: conflict.triggerKey)
        else { return "" }
        return "\(descriptor.displayString): "
    }
}

struct ExtraTriggersNote: View {
    let mode: Mode

    @ViewBuilder var body: some View {
        if let note = ModeSummary.extraTriggersNote(mode) {
            Label(note, systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.extraTriggersNote)
        }
    }
}

@MainActor
struct ModeTrigger {
    let mode: Mode
    let allModes: [Mode]
    let onUpdate: (Mode) -> Void

    var conflict: TriggerKeyConflict? {
        TriggerKeyConflicts.conflict(for: mode, in: allModes)
    }

    var usesMouseShortcut: Bool {
        ModeSummary.triggerDescriptors(mode).contains {
            if case .mouseButton = $0 { return true }
            return false
        }
    }

    var pressStyle: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.pressStyle ?? Mode.TriggerKey.defaultPressStyle },
            set: { style in
                guard !mode.triggerKeys.isEmpty else { return }
                var updated = mode
                updated.setPrimaryPressStyle(style)
                onUpdate(updated)
            })
    }
}
