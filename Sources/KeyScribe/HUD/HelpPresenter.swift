import AppKit

@MainActor
final class EscapeClaim {
    static let keyCode = 53

    private let registrar: any ChordRegistering

    init(registrar: any ChordRegistering = CarbonHotKeys()) {
        self.registrar = registrar
    }

    @discardableResult
    func claim(onPress: @escaping () -> Void) -> Bool {
        registrar.update([CarbonHotKeys.Registration(keyCode: Self.keyCode, modifiers: [], onPressed: onPress, onReleased: nil)])
    }

    func release() {
        registrar.update([])
    }
}

@MainActor
final class HelpPresenter {
    var escape: EscapeClaim
    var seconds: Double = 15
    private(set) var duration: Double = 15
    static let rowsPerBase = 10
    static let maxStretch: Double = 3
    var voiceOverRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    private(set) var showing = false
    private var timer: Task<Void, Never>?
    private let hide: () -> Void

    init(escape: EscapeClaim, hide: @escaping () -> Void) {
        self.escape = escape
        self.hide = hide
    }

    static func duration(base: Double, rows: Int) -> Double {
        base * min(maxStretch, max(1, Double(rows) / Double(rowsPerBase)))
    }

    func shown(rows: Int = 0) {
        duration = Self.duration(base: seconds, rows: rows)
        showing = true
        escape.claim { [weak self] in self?.dismiss() }
        scheduleHide()
    }

    func hover(_ hovering: Bool) {
        guard showing else { return }
        if hovering { timer?.cancel() } else { scheduleHide() }
    }

    func dismiss() {
        guard showing else { return }
        release()
        hide()
    }

    func release() {
        guard showing else { return }
        showing = false
        timer?.cancel()
        escape.release()
    }

    private func scheduleHide() {
        timer?.cancel()
        guard !voiceOverRunning() else { return }
        let duration = duration
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}
