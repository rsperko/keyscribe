public enum ClipboardKeystrokeError: Error, Equatable {
    case notAChord(String)
}

/// The chord a mode posts to copy or paste, written in the same grammar as `trigger_keys[].key`.
/// Only a chord is meaningful here — the grammar's trigger-only descriptors (fn, hyper, mouse buttons)
/// are rejected rather than silently treated as some default.
public struct ClipboardKeystroke: Equatable, Sendable {
    private let descriptor: KeyDescriptor

    private init(descriptor: KeyDescriptor) { self.descriptor = descriptor }

    public init(parsing string: String) throws {
        let parsed = try KeyDescriptor(parsing: string)
        guard case .chord = parsed else { throw ClipboardKeystrokeError.notAChord(string) }
        descriptor = parsed
    }

    public var modifiers: Set<Modifier> { descriptor.requiredModifiers }
    public var canonical: String { descriptor.canonical }

    public func keyCode(in layout: KeyboardLayoutIndex) -> Int? {
        descriptor.chordKeyCode(in: layout)
    }

    /// A chord without ⌘ is aimed at a target that forwards raw keystrokes instead of handling them as
    /// macOS events — a VM guest, a remote session. That drives two things: the modifiers must go out as
    /// real key events (a hypervisor reads key codes, not CGEvent flags), and the clipboard defaults to
    /// sync semantics. The second is overridable per mode, because a client can translate ⌘V for a remote
    /// session while still needing the foreign clipboard handling.
    public var isForeignTarget: Bool { !modifiers.contains(.command) }

    public static let paste = ClipboardKeystroke(descriptor: .chord(modifiers: [.command], key: .character("v")))
    public static let copy = ClipboardKeystroke(descriptor: .chord(modifiers: [.command], key: .character("c")))
}
