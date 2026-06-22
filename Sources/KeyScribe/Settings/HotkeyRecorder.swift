import AppKit
import KeyScribeKit
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var key: String
    @State private var recording = false
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(label)
                    .frame(minWidth: 150)
                    .foregroundStyle(recording ? .secondary : .primary)
            }
            .buttonStyle(.bordered)
            if !key.isEmpty && !recording {
                Button("Clear") { key = "" }
                    .buttonStyle(.borderless)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Press a shortcut…  (Esc to cancel)" }
        if let descriptor = try? KeyDescriptor(parsing: key) { return descriptor.displayString }
        return "Click to record"
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { stop(); return }
        let modifiers = HotkeyRecorder.modifierSet(event.modifierFlags)
        if let descriptor = KeyDescriptor(eventKeyCode: Int(event.keyCode), modifiers: modifiers) {
            key = descriptor.canonical
            stop()
        } else if modifiers.isEmpty {
            hint = "Hold a modifier (⌃⌥⇧⌘) with the key"
        } else {
            hint = "That key can't be recorded"
        }
    }

    static func modifierSet(_ flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        var set: Set<Modifier> = []
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }
}
