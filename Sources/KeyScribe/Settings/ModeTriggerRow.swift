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

// Pairs with the recorder row but sits in a different container per editor (top-level in the system
// editor, inside the routing disclosure in a normal mode), so callers compose it themselves.
struct PressStyleRow: View {
    let selection: Binding<String>
    let disabled: Bool

    var body: some View {
        Picker("Press behavior", selection: selection) {
            Text("Hold or tap").tag("hold-or-tap")
            Text("Hold only").tag("hold-only")
            Text("Tap to toggle").tag("tap-to-toggle")
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

    @ViewBuilder var body: some View {
        if let conflict {
            IssueText("Also used by \(conflict.modeName) in an overlapping context. When both could apply, the more specific mode wins, then the one listed first.",
                      severity: .advisory)
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
