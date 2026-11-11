import CoreGraphics

enum KeyReplay {
    static let marker: Int64 = 0x4B53_5250

    static func isReplayed(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func marked(_ event: CGEvent) -> CGEvent? {
        guard let copy = event.copy() else { return nil }
        copy.setIntegerValueField(.eventSourceUserData, value: marker)
        return copy
    }

    static func post(_ events: [CGEvent], to pid: pid_t) {
        for event in events { marked(event)?.postToPid(pid) }
    }
}
