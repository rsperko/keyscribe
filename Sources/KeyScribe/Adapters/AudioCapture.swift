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
            _ = stop()
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

        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        let level = min(1, max(0, rms * 8))
        if let handler { handler(level) }
    }
}
