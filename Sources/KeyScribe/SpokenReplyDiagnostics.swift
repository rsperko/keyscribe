import Foundation
import KeyScribeKit

@MainActor
final class SpokenReplyDiagnostics {
    enum Rendered: Equatable {
        case rendered(number: Int, wav: Data, note: String?)
        case failed(String)
    }

    enum Checked: Equatable { case checked(SpokenReplyCheck.Result), busy, cancelled, noAudio, failed }

    static let renderBusyWait: Duration = .seconds(20)

    nonisolated static func renderLimit(_ text: String) -> Duration {
        .seconds(20) + .milliseconds(300 * text.split(whereSeparator: { $0.isWhitespace }).count)
    }

    private let attempts: SpokenAttempts
    private let history: () -> HistoryStore?
    private let wait: @Sendable (Duration) async -> Void
    var listen: ((URL) async -> EngineKeeper.Listening)?
    var render: @Sendable (String, String) async throws -> SpokenAudio = { try await KokoroVoice.shared.synthesize($0, voice: $1) }
    var renderLimit: @Sendable (String) -> Duration = SpokenReplyDiagnostics.renderLimit
    var currentVoice: () -> String = { SpokenVoices.recommended }
    var voiceReady: () -> Bool = { true }
    var onChange: (() -> Void)?

    init(
        attempts: SpokenAttempts, history: @escaping () -> HistoryStore?,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.attempts = attempts
        self.history = history
        self.wait = wait
    }

    private enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    func check(_ entry: HistoryEntry, render: URL? = nil) async -> Checked {
        guard let id = entry.id, let reply = entry.spokenReply, let listen, let history = history() else { return .noAudio }
        let held = render == nil ? attempts.attempt(forEntry: id) : nil
        let source: Source
        if let render {
            source = .file(render)
        } else if let audio = held?.audio {
            source = .data(audio)
        } else if let kept = keptOriginal(entry) {
            source = .file(kept)
        } else {
            return .noAudio
        }
        let wav: URL
        switch source {
        case .file(let url): wav = url
        case .data(let data):
            wav = FileManager.default.temporaryDirectory.appendingPathComponent("spoken reply check \(UUID().uuidString).wav")
            guard (try? data.write(to: wav)) != nil else { return .failed }
        }
        defer { if case .data = source { try? FileManager.default.removeItem(at: wav) } }
        let words: String
        let checker: String
        switch await listen(wav) {
        case .heard(let heard, let engine): (words, checker) = (heard, engine)
        case .busy: return .busy
        case .cancelled: return .cancelled
        case .unavailable: return .failed
        }
        let text = reply.rendering.map { $0.sentences.joined(separator: " ") } ?? reply.text
        guard let result = held.flatMap({ Self.compare($0, heard: words, checker: checker) })
            ?? SpokenReplyCheck.compare(text: text, normalized: nil, heard: words, checker: checker) else { return .failed }
        let folder = history.evidence.folder(entry: id, at: entry.timestamp)
        if let render {
            Self.updateReport(folder.appendingPathComponent(render.deletingPathExtension().lastPathComponent + " report.txt"), with: result)
        } else {
            if let held { attempts.update(held.id) { $0.check = result } }
            _ = history.update(id: id, near: entry.timestamp) {
                var updated = $0
                updated.spokenReply?.check = result
                return updated
            }
            Self.updateReport(folder.appendingPathComponent("reply report.txt"), with: result)
        }
        onChange?()
        return .checked(result)
    }

    private static func updateReport(_ url: URL, with check: SpokenReplyCheck.Result) {
        guard let saved = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? SpokenAttempt.report(saved, checked: check).write(to: url, atomically: true, encoding: .utf8)
    }

    static func compare(_ attempt: SpokenAttempt, heard: String, checker: String) -> SpokenReplyCheck.Result? {
        let spoken = attempt.segments.map(\.text).joined(separator: " ")
        return SpokenReplyCheck.compare(
            text: spoken.isEmpty ? attempt.text : spoken, normalized: attempt.normalizedText, heard: heard, checker: checker)
    }

    @discardableResult
    func keep(_ entry: HistoryEntry) -> SessionReturns.KeptReply {
        guard let id = entry.id, let reply = entry.spokenReply, let history = history() else { return .failed }
        let timestamp = entry.timestamp
        let conversation = reply.conversation
        let held = attempts.attempt(forEntry: id)
        var files: [SpokenReplyEvidence.File] = []
        if let wav = held?.audio { files.append(.init(name: "reply.wav", data: wav)) }
        let report: String
        if let held {
            report = held.report(appName: Branding.appName)
        } else {
            var gone = SpokenAttempt(at: reply.at, text: reply.text, voice: reply.rendering?.voice ?? "not recorded")
            gone.check = reply.check
            gone.notes = ["The generated audio was no longer held when this reply was kept."]
            gone.details = SpokenAttempts.environment(includingOutput: false).filter { $0.label != "Output" }
            report = gone.report(appName: Branding.appName)
        }
        if held != nil || !history.evidence.isKept(entry: id, at: timestamp) {
            files.append(.init(name: "reply report.txt", data: Data(report.utf8)))
        }
        let rendering = held.flatMap { $0.segments.isEmpty ? nil : HistoryEntry.SpokenReply.Rendering(voice: $0.voice, sentences: $0.segments.map(\.text)) }
        switch history.keepSpokenReply(id: id, near: timestamp, files: files, rendering: rendering) {
        case .saved:
            onChange?()
            return history.evidence.original(entry: id, at: timestamp) != nil ? .kept(conversation) : .reportOnly(conversation)
        case .entryGone: return .nothingHeard
        case .failed: return .failed
        }
    }

    func folder(_ entry: HistoryEntry) -> URL? {
        guard let id = entry.id, let history = history(), history.evidence.isKept(entry: id, at: entry.timestamp) else { return nil }
        return history.evidence.folder(entry: id, at: entry.timestamp)
    }

    func renders(_ entry: HistoryEntry) -> [URL] {
        guard let id = entry.id, let history = history() else { return [] }
        return history.evidence.renders(entry: id, at: entry.timestamp)
    }

    func keptOriginal(_ entry: HistoryEntry) -> URL? {
        guard let id = entry.id, let history = history() else { return nil }
        return history.evidence.original(entry: id, at: entry.timestamp)
    }

    func renderAgain(_ entry: HistoryEntry) async -> Rendered {
        guard let id = entry.id, let reply = entry.spokenReply, let history = history() else {
            return .failed("This reply can\u{2019}t be rendered again.")
        }
        let held = attempts.attempt(forEntry: id)
        let texts: [String]
        let voice: String
        var note: String?
        if let held, !held.segments.isEmpty {
            texts = held.segments.map(\.text)
            voice = held.voice
        } else if let rendering = reply.rendering, !rendering.sentences.isEmpty {
            texts = rendering.sentences
            voice = rendering.voice
        } else {
            texts = [reply.text]
            voice = currentVoice()
            note = "Rendered with the current voice as one piece; the original voice and sentences weren\u{2019}t recorded."
        }
        var parts: [SpokenAudio] = []
        var notes: [String] = note.map { [$0] } ?? []
        for text in texts {
            switch await renderWaiting(text, voice: voice) {
            case .success(let audio): parts.append(audio)
            case .failure(let unusable as SpokenAudio.Unusable):
                guard let audio = unusable.audio else { return .failed("The natural voice made \(unusable.problem.rawValue).") }
                notes.append("The natural voice made \(unusable.problem.rawValue) for \u{201C}\(text)\u{201D}.")
                parts.append(audio)
            case .failure(is KokoroVoice.NotInstalled):
                return .failed("The natural voice isn\u{2019}t installed.")
            case .failure(is WorkBusy):
                return .failed("The natural voice is busy. Try again in a moment.")
            case .failure(is DeadlineExceeded):
                return .failed("The natural voice took too long to render this reply.")
            case .failure:
                return .failed("The natural voice failed to render this reply.")
            }
        }
        guard let joined = SpokenAudio.joined(parts) else {
            return .failed("The natural voice failed to render this reply.")
        }
        var attempt = SpokenAttempt(at: Date(), text: texts.joined(separator: " "), voice: voice)
        attempt.reader = .natural
        attempt.segments = zip(texts, parts).compactMap { text, part in part.synthesis.map { .init(text: text, synthesis: $0) } }
        attempt.details = SpokenAttempts.environment(includingOutput: false).filter { $0.label != "Output" }
        attempt.notes = ["Rendered again from History; this audio was not played when it was made."] + notes
        let gone = Rendered.failed("This entry was deleted, so the new render wasn\u{2019}t saved.")
        if keep(entry) == .nothingHeard { return gone }
        switch history.addSpokenRender(
            id: id, near: entry.timestamp, wav: joined.wav, report: Data(attempt.report(appName: Branding.appName).utf8)
        ) {
        case .saved(let number):
            onChange?()
            return .rendered(number: number, wav: joined.wav, note: note)
        case .entryGone: return gone
        case .failed: return .failed("The new render couldn\u{2019}t be saved.")
        }
    }

    private func renderWaiting(_ text: String, voice: String) async -> Result<SpokenAudio, any Error> {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.renderBusyWait
        let render = render
        let limit = renderLimit(text)
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        while true {
            do {
                return .success(try await runWithDeadline(seconds: seconds) { try await render(text, voice) })
            } catch is WorkBusy where clock.now < deadline {
                await wait(.milliseconds(200))
            } catch {
                return .failure(error)
            }
        }
    }
}
