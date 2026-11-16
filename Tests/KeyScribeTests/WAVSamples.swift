import AVFoundation
import Foundation
@testable import KeyScribeApp

func readMonoFloat(_ url: URL, sampleRate: Int = 16_000) throws -> [Float] {
    guard try AVAudioFile(forReading: url).length > 0 else { return [] }
    return try AudioDecoder.pcmMono(url, sampleRate: sampleRate)
}
