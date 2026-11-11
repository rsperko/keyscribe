import Foundation
import KeyScribeKit

enum WarmupProbeRunner {
    static func run(only: Set<String>?) async {
        guard let clip = EngineKeeper.bundledWarmupClip else {
            print("warmup-probe: the warm-up clip is not in this bundle; run the built app.")
            return
        }
        let engines = EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
            .filter { only?.contains($0.id) ?? true }
        print("engine                  warmup-clip  load     first    second   third")
        for engine in engines {
            await engine.evict()
            let loadStart = ProcessInfo.processInfo.systemUptime
            do { try await engine.loadIfNeeded() } catch {
                print("\(pad(engine.id))  not installed / load failed")
                continue
            }
            let load = ProcessInfo.processInfo.systemUptime - loadStart
            var runs: [Double] = []
            for _ in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try? await engine.transcribe(wavURL: clip, biasTerms: [])
                runs.append(ProcessInfo.processInfo.systemUptime - start)
            }
            await engine.evict()
            print("\(pad(engine.id))  \(engine.benefitsFromWarmupClip ? "yes" : "no ")          \(ms(load))  \(runs.map(ms).joined(separator: "  "))")
        }
    }

    private static func pad(_ id: String) -> String { id.padding(toLength: 22, withPad: " ", startingAt: 0) }
    private static func ms(_ seconds: Double) -> String { String(format: "%5.0fms", seconds * 1000) }
}
