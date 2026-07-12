import AppKit
import SwiftUI
import KeyScribeKit

struct ModeTriggerRow: View {
    let mode: Mode
    let onUpdate: (Mode) -> Void
    var label: String = "Start this mode with"
    var accessibilityID: String = AccessibilityID.Mode.Editor.shortcutWell
    @State private var rememberedStyle: String?
    @State private var rememberedThreshold: Int?

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
                if key.isEmpty {
                    if let existing = mode.triggerKeys.first {
                        rememberedStyle = existing.pressStyle
                        rememberedThreshold = existing.tapThresholdMs
                    }
                    updated.triggerKeys = []
                } else {
                    let existing = mode.triggerKeys.first
                    updated.triggerKeys = [.init(
                        key: key,
                        pressStyle: existing?.pressStyle ?? rememberedStyle ?? "hold-or-tap",
                        tapThresholdMs: existing?.tapThresholdMs ?? rememberedThreshold ?? 250)]
                }
                onUpdate(updated)
            })
    }
}

// The press-style picker and conflict notice pair with the recorder row but sit in different
// containers per editor (top-level in the system editor, inside the routing disclosure in a normal
// mode), so callers compose them; the shared trigger state lives in ModeTrigger.
struct PressStyleRow: View {
    let selection: Binding<String>
    let disabled: Bool

    var body: some View {
        Picker("How the shortcut works", selection: selection) {
            Text("Hold or tap").tag("hold-or-tap")
            Text("Hold only").tag("hold-only")
            Text("Tap to toggle").tag("tap-to-toggle")
        }
        .disabled(disabled)
        .accessibilityIdentifier(AccessibilityID.Mode.Editor.pressStyle)
        Text((PressStyle(rawValue: selection.wrappedValue) ?? .holdOrTap).instruction)
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct TriggerConflictLabel: View {
    let conflict: TriggerKeyConflict?

    @ViewBuilder var body: some View {
        if let conflict {
            IssueText("Also used by \(conflict.modeName) in an overlapping context. When both could apply, the more specific mode wins, then the one listed first.",
                      severity: .advisory)
        }
    }
}

// A Hyper trigger fires the instant all four modifiers are held, so a ⌃⌥⇧⌘ chord or action shortcut
// starts this mode too, from a single press. The right-side modifier triggers are disambiguated at
// runtime ("chord wins"), so only Hyper still surfaces this warning (see TriggerKeyConflicts.modifierOverlap).
struct TriggerOverlapLabel: View {
    let overlap: TriggerOverlap?

    @ViewBuilder var body: some View {
        if let overlap {
            IssueText("Pressing \(overlap.rivalLabel) also starts this mode — its keys include this shortcut’s modifiers. Give one of them different keys so a single press doesn’t fire both.",
                      severity: .advisory)
        }
    }
}

@MainActor
struct ModeTrigger {
    let mode: Mode
    let allModes: [Mode]
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    let onUpdate: (Mode) -> Void

    var conflict: TriggerKeyConflict? {
        TriggerKeyConflicts.conflict(for: mode, in: allModes)
    }

    // Every enabled rival binding whose modifiers could subsume one of this mode's modifier-only
    // triggers: other enabled modes' trigger keys plus the global action shortcuts.
    var overlap: TriggerOverlap? {
        let rivals = allModes
            .filter { $0.id != mode.id && $0.enabled }
            .flatMap { other in other.triggerKeys.map {
                TriggerKeyConflicts.RivalBinding(key: $0.key, label: "the \(other.name) mode’s shortcut") } }
            + actionShortcuts
        for trigger in mode.triggerKeys {
            if let overlap = TriggerKeyConflicts.modifierOverlap(triggerKey: trigger.key, with: rivals) {
                return overlap
            }
        }
        return nil
    }

    var pressStyle: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.pressStyle ?? "hold-or-tap" },
            set: { style in
                guard let existing = mode.triggerKeys.first else { return }
                var updated = mode
                updated.triggerKeys = [.init(
                    key: existing.key, pressStyle: style, tapThresholdMs: existing.tapThresholdMs)]
                onUpdate(updated)
            })
    }
}
