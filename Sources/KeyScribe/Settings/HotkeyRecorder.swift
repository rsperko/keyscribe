import AppKit
import KeyScribeKit
import SwiftUI

// Shared while any HotkeyRecorder is capturing. The selection Lists in Settings disable themselves on
// it so SwiftUI's keyboard type-select can't grab the chord's keystroke before the recorder sees it.
final class HotkeyRecordingState: ObservableObject {
    // Lets the app suspend the global hotkey monitor while a recorder captures (set by AppDelegate).
    var onChange: ((Bool) -> Void)?
    @Published var isRecording = false { didSet { onChange?(isRecording) } }
}

// Stable identities for the two global shortcuts in the app-wide hotkey namespace (alongside Mode ids).
enum GlobalHotkey {
    static let dictionaryId = "global:add_dictionary"
    static let replacementId = "global:add_replacement"
    static let pasteLastId = "global:paste_last"
}

struct HotkeyRecorder: View {
    @Binding var key: String
    var autostart = false
    var onCancel: () -> Void = {}
    @EnvironmentObject private var recordingState: HotkeyRecordingState
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            RecorderButton(
                key: $key, hint: $hint,
                recordingState: recordingState, autostart: autostart, onCancel: onCancel)
                .frame(width: 200, height: 24)
            if !key.isEmpty && !recordingState.isRecording {
                Button("Clear") { key = "" }
                    .buttonStyle(.borderless)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { recordingState.isRecording = false }
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

private struct RecorderButton: NSViewRepresentable {
    @Binding var key: String
    @Binding var hint: String?
    let recordingState: HotkeyRecordingState
    let autostart: Bool
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButtonView {
        let view = RecorderButtonView()
        view.onCapture = { key = $0 }
        view.onHint = { hint = $0 }
        view.recordingState = recordingState
        view.onCancel = onCancel
        view.autostart = autostart
        view.syncKey(key)
        return view
    }

    func updateNSView(_ view: RecorderButtonView, context: Context) {
        view.recordingState = recordingState
        view.onCancel = onCancel
        view.syncKey(key)
    }
}

// A focusable button that captures the chord in performKeyEquivalent(with:), which AppKit dispatches
// before a focused List's keyDown type-select — so recording a shortcut never navigates the sidebar.
final class RecorderButtonView: NSButton {
    var onCapture: ((String) -> Void)?
    var onHint: ((String?) -> Void)?
    var recordingState: HotkeyRecordingState?
    var onCancel: (() -> Void)?
    var autostart = false

    private var recording = false
    private var captured = false
    private var currentKey = ""
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if autostart, window != nil, !recording, currentKey.isEmpty { start() }
    }

    func syncKey(_ key: String) {
        guard !recording, key != currentKey else { return }
        currentKey = key
        refreshTitle()
    }

    @objc private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        captured = false
        recordingState?.isRecording = true
        onHint?(nil)
        window?.makeFirstResponder(self)
        // The load-bearing fix: a local monitor sees the keystroke before SwiftUI's List type-select
        // (which runs ahead of performKeyEquivalent and ignores first responder). Returning nil here
        // swallows the event, so recording a shortcut never navigates the mode/sidebar list.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.recording, event.window === self.window else { return event }
            if event.type == .keyDown { _ = self.capture(event) }
            else if event.type == .otherMouseDown { _ = self.captureMouse(event) }
            return nil
        }
        refreshTitle()
    }

    private func stop() {
        guard recording else { return }
        recording = false
        recordingState?.isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
        if !captured { onCancel?() }
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard recording, capture(event) else { super.keyDown(with: event); return }
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return true
        }
        let modifiers = HotkeyRecorder.modifierSet(event.modifierFlags)
        if let descriptor = KeyDescriptor(eventKeyCode: Int(event.keyCode), modifiers: modifiers) {
            captured = true
            currentKey = descriptor.canonical
            onCapture?(descriptor.canonical)
            window?.makeFirstResponder(nil)
        } else if modifiers.isEmpty {
            onHint?("Hold a modifier (⌃⌥⇧⌘) with the key")
        } else {
            onHint?("That key can't be recorded")
        }
        return true
    }

    private func captureMouse(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if let descriptor = KeyDescriptor(eventButtonNumber: event.buttonNumber) {
            captured = true
            currentKey = descriptor.canonical
            onCapture?(descriptor.canonical)
            window?.makeFirstResponder(nil)
        }
        return true
    }

    private func refreshTitle() {
        title = label
    }

    private var label: String {
        if recording { return "Press keys or a mouse button…  Esc cancels" }
        if let descriptor = try? KeyDescriptor(parsing: currentKey) { return descriptor.displayString }
        return "Set Shortcut"
    }
}
