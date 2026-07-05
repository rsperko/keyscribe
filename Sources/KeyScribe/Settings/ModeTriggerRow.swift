import AppKit
import SwiftUI
import KeyScribeKit

private let customTriggerTag = "__custom__"

// The shortcut row: the menu, or — for a custom chord — the recorder in place. Choosing "Custom
// shortcut…" arms it immediately; Esc or clearing reverts to the menu. Shared by the normal and
// system-mode editors.
struct ModeTriggerRow: View {
    let mode: Mode
    let onUpdate: (Mode) -> Void
    @State private var capturingCustom = false

    var body: some View {
        if isCustom {
            LabeledContent("Start this mode with") {
                HotkeyRecorder(
                    key: triggerKey, autostart: capturingCustom,
                    onCancel: { capturingCustom = false })
            }
        } else {
            Picker("Start this mode with", selection: triggerSelection) {
                Text("No mode shortcut").tag("")
                Text("Fn (Globe)").tag("fn")
                Text("Right Option").tag("right_option")
                Text("Right Command").tag("right_command")
                Text("Custom shortcut…").tag(customTriggerTag)
            }
        }
    }

    private var triggerSelection: Binding<String> {
        Binding(
            get: {
                if capturingCustom { return customTriggerTag }
                let key = mode.triggerKeys.first?.key ?? ""
                guard !key.isEmpty else { return "" }
                if let descriptor = try? KeyDescriptor(parsing: key), case .named = descriptor {
                    return descriptor.canonical
                }
                return customTriggerTag
            },
            set: { selection in
                if selection == customTriggerTag {
                    capturingCustom = true
                } else {
                    capturingCustom = false
                    triggerKey.wrappedValue = selection
                }
            })
    }

    private var isCustom: Bool {
        if capturingCustom { return true }
        guard let descriptor = try? KeyDescriptor(parsing: mode.triggerKeys.first?.key ?? "") else { return false }
        if case .chord = descriptor { return true }
        if case .mouseButton = descriptor { return true }
        return false
    }

    private var triggerKey: Binding<String> {
        Binding(
            get: { mode.triggerKeys.first?.key ?? "" },
            set: { key in
                capturingCustom = false
                var updated = mode
                if key.isEmpty {
                    updated.triggerKeys = []
                } else {
                    let existing = mode.triggerKeys.first
                    updated.triggerKeys = [.init(
                        key: key,
                        pressStyle: existing?.pressStyle ?? "hold-or-tap",
                        tapThresholdMs: existing?.tapThresholdMs ?? 250)]
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
    }
}

struct TriggerConflictLabel: View {
    let conflict: TriggerKeyConflict?

    @ViewBuilder var body: some View {
        if let conflict {
            Label("Also used by \(conflict.modeName) in an overlapping context. When both could apply, the more specific mode wins, then the one listed first.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// A modifier-only trigger (Hyper / right ⌥ / right ⌘) fires the instant its modifiers are held, so a
// chord or action shortcut whose modifiers include them starts this mode too, from a single press.
struct TriggerOverlapLabel: View {
    let overlap: TriggerOverlap?

    @ViewBuilder var body: some View {
        if let overlap {
            Label("Pressing \(overlap.rivalLabel) also starts this mode — its keys include this shortcut’s modifiers. Give one of them different keys so a single press doesn’t fire both.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
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
