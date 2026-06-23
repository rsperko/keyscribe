import Accelerate
import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject {
    func start(levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL
    func stop() -> URL?
}

final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var levelHandler: (@Sendable (Float) -> Void)?

    func start(levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.lock()
        self.file = file
        self.currentURL = url
        self.levelHandler = levelHandler
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            if let url = stop() { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return url
    }

    func stop() -> URL? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        let url = currentURL
        file = nil
        currentURL = nil
        levelHandler = nil
        return url
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = self.file
        let handler = self.levelHandler
        lock.unlock()

        try? file?.write(from: buffer)

        guard let handler else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        let level = Self.perceptualLevel(rms)
        handler(level)
    }

    // RMS is linear, so speech-range energy clusters near zero and a linear meter barely moves.
    // Map to dB and rescale a [floor, ceiling] window to 0...1 so normal speech spans most of the bar.
    private static func perceptualLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -52
        let ceiling: Float = -12
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }
}
