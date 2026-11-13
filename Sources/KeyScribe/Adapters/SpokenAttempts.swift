import CoreAudio
import Foundation
import KeyScribeKit

@MainActor
final class SpokenAttempts {
    private var log = SpokenAttemptLog()
    private var entries: [String: String] = [:]
    private var awaiting: [String: Int] = [:]
    private var finished: Set<String> = []
    private var parts: [String: (sampleRate: Int, sentences: [[Float]])] = [:]
    private let now: () -> Date
    private let wait: @Sendable (Duration) async -> Void
    private var expiry: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(now: @escaping () -> Date = Date.init, wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.now = now
        self.wait = wait
    }

    func begin(text: String, voice: String) -> String {
        let attempt = SpokenAttempt(at: now(), text: text, voice: voice)
        log.begin(attempt)
        changed()
        scheduleExpiry()
        return attempt.id
    }

    func update(_ id: String, _ change: (inout SpokenAttempt) -> Void) {
        log.update(id, now: now(), change)
        changed()
    }

    func discard(_ ids: some Sequence<String>) {
        log.discard(ids)
        changed()
    }

    func addSegment(_ id: String?, text: String, audio: SpokenAudio) {
        guard let id, log.attempt(id, now: now()) != nil else { return }
        let sentences = (parts[id]?.sentences ?? []) + [audio.samples]
        parts[id] = (audio.sampleRate, sentences)
        update(id) {
            if sentences.count == 1 { $0.audio = audio.wav }
            if let synthesis = audio.synthesis { $0.segments.append(.init(text: text, synthesis: synthesis)) }
        }
    }

    private func joinSentences(_ id: String) {
        guard let held = parts.removeValue(forKey: id), held.sentences.count > 1,
              let wav = SpokenAudio.wav(held.sentences, sampleRate: held.sampleRate) else { return }
        update(id) { $0.audio = wav }
    }

    func attempt(_ id: String) -> SpokenAttempt? {
        log.attempt(id, now: now())
    }

    var heldCount: Int { log.attempts.count }
    var linkedEntries: Int { entries.count }

    func ended(_ id: String?) {
        guard let id else { return }
        finished.insert(id)
        if awaiting[id] == nil, !entries.values.contains(id) { return discard([id]) }
        joinSentences(id)
    }

    func awaitLink(_ id: String?) {
        guard let id else { return }
        awaiting[id, default: 0] += 1
        log.keep(id)
    }

    func link(_ attempt: String?, to entry: String?) {
        guard let attempt else { return }
        let pending = (awaiting[attempt] ?? 1) - 1
        awaiting[attempt] = pending > 0 ? pending : nil
        guard let entry else {
            guard !entries.values.contains(attempt), pending <= 0 else { return }
            log.release(attempt)
            if finished.contains(attempt) { discard([attempt]) }
            return
        }
        entries[entry] = attempt
        log.keep(attempt)
        changed()
    }

    func attempt(forEntry entry: String) -> SpokenAttempt? {
        guard let held = entries[entry].flatMap({ attempt($0) }) else {
            entries[entry] = nil
            return nil
        }
        return held
    }

    func entry(forAttempt attempt: String) -> String? {
        entries.first { $0.value == attempt }?.key
    }

    func forget(entries removed: some Sequence<String>) {
        let unlinked = removed.compactMap { entries.removeValue(forKey: $0) }
        discard(unlinked.filter { !entries.values.contains($0) })
    }

    private func changed() {
        let held = Set(log.attempts.map(\.id))
        entries = entries.filter { held.contains($0.value) }
        awaiting = awaiting.filter { held.contains($0.key) }
        finished.formIntersection(held)
        parts = parts.filter { held.contains($0.key) }
        let lines = log.attempts.suffix(Self.diagnosed).map(\.diagnosticLine)
        DiagnosticsCollector.spokenReplies.withLock { $0 = lines }
        onChange?()
    }

    private static let diagnosed = 5

    private func scheduleExpiry() {
        guard expiry == nil else { return }
        expiry = Task { [weak self] in
            while let self, let next = self.log.nextExpiry {
                let delay = next.timeIntervalSince(self.now())
                if delay > 0 { await self.wait(.milliseconds(Int((delay * 1000).rounded(.up)))) }
                guard !Task.isCancelled else { return }
                self.log.expire(now: self.now())
                self.changed()
            }
            self?.expiry = nil
        }
    }

    nonisolated static func environment(includingOutput: Bool) -> [SpokenAttempt.Detail] {
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]].compactMap { $0 as? String }
        var details = [
            SpokenAttempt.Detail(label: "App", value: "\(Branding.appName) \(version.joined(separator: " build "))"),
            SpokenAttempt.Detail(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString),
            SpokenAttempt.Detail(label: "FluidAudio", value: info?["FluidAudioRevision"] as? String ?? "unknown"),
            SpokenAttempt.Detail(label: "Voice route", value: KokoroVoice.route),
        ]
        let output = includingOutput
            ? SystemOutputAudio.defaultOutputDescription() ?? "couldn\u{2019}t be read"
            : "not read: the natural voice\u{2019}s audio didn\u{2019}t play"
        details.append(SpokenAttempt.Detail(label: "Output", value: output))
        return details
    }
}
