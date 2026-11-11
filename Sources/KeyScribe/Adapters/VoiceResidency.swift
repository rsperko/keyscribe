import Foundation

@MainActor
final class VoiceResidency {
    private let load: @Sendable () async -> Void
    private let unload: @Sendable () async -> Void
    private var last: Task<Void, Never>?

    init(load: @escaping @Sendable () async -> Void, unload: @escaping @Sendable () async -> Void) {
        self.load = load
        self.unload = unload
    }

    func warm() { after(load) }

    func release() { after(unload) }

    private func after(_ work: @escaping @Sendable () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await work()
        }
    }
}

extension VoiceResidency {
    static func kokoro() -> VoiceResidency {
        VoiceResidency(load: { await KokoroVoice.shared.warm() }, unload: { await KokoroVoice.shared.evict() })
    }
}
