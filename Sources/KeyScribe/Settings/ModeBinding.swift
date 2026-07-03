import SwiftUI
import KeyScribeKit

@MainActor
struct ModeBinding {
    let mode: Mode
    let onUpdate: (Mode) -> Void

    func binding<T>(_ keyPath: WritableKeyPath<Mode, T>) -> Binding<T> {
        Binding(
            get: { mode[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

    func commandsBinding(_ keyPath: WritableKeyPath<Mode.Commands, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.commands[keyPath: keyPath] },
            set: { value in
                var updated = mode
                updated.commands[keyPath: keyPath] = value
                onUpdate(updated)
            })
    }

    func contextBinding(_ keyPath: WritableKeyPath<Mode.ContextOptIn, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode.commands.privacy ? false : (mode.aiRewrite?.context[keyPath: keyPath] ?? false) },
            set: { value in
                guard var rewrite = mode.aiRewrite else { return }
                rewrite.context[keyPath: keyPath] = value
                var updated = mode
                updated.aiRewrite = rewrite
                onUpdate(updated)
            })
    }
}
