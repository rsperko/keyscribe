import AVFoundation
import Darwin
import Foundation
import KeyScribeKit

// Measures the real in-memory footprint of each installed SpeechEngine on the exact code paths that ship,
// so the Settings model list can show honest RAM figures instead of disk size (which overstates it —
// CoreML memory-maps weights and runs on the ANE). The number reported is
// `phys_footprint` (the value Activity Monitor's "Memory" column shows), read from mach TASK_VM_INFO; plain
// resident_size undercounts because it ignores compressed pages. On Apple Silicon this also captures MLX's
// unified-memory buffers (Qwen), so no engine-specific counter is needed.
//
// Per engine it walks four phases and reports the deltas — deltas isolate each cost far better than the
// contaminated absolute footprint of a shared process:
//   baseline → load (warm) → unbiased transcribe → biased transcribe.
// The biased→unbiased delta is the recognition-bias cost. No shipping engine loads a separate bias model
// anymore (Qwen3's native context and Whisper's prompt tokens both reuse the loaded model), so the delta is
// ~0 for every installed engine. For pristine absolute numbers run one engine per invocation (`--engines
// <id>`): a shared process retains MLX/CoreML pages across engines, so a later engine's baseline is inflated
// by an earlier one.
enum MemProbeRunner {
    private struct Sample {
        var phys: Int64 = 0   // phys_footprint (Activity Monitor "Memory"): dirty + compressed, NOT clean mmap'd
        var rss: Int64 = 0    // resident_size: all resident pages incl. paged-in file-backed model weights
        // System-wide (host) page counts — reveal where model memory lands beyond this process's accounting:
        // wired = unswappable; fileBacked = evictable page-cache (soft); anon = committed app memory (hard).
        var wired: Int64 = 0
        var fileBacked: Int64 = 0
        var anon: Int64 = 0
        var compressed: Int64 = 0
    }

    private struct Phases {
        var baseline = Sample()
        var afterLoad = Sample()
        var afterUnbiased = Sample()
        var afterBiased = Sample()
        var afterEvict = Sample()
        var peakPhys: Int64 = 0
        var peakRSS: Int64 = 0
        var status = "ok"
    }

    // Arbitrary terms just have to be non-empty to route through the biased path (native context / prompt
    // tokens on the engines that bias); whether they actually match the audio is irrelevant to the footprint.
    private static let probeBiasTerms = ["Kubernetes", "Postgres", "ChargeBee"]

    static func run(only: Set<String>? = nil, clip: URL? = nil, seconds: Double = 5) async {
        let engines = InstalledEngineFilter.filter(makeEngines())
            .filter { only == nil || only!.contains($0.id) }
        guard !engines.isEmpty else {
            print("mem-probe: no installed engines to measure (install one, or check --engines).")
            return
        }

        let wav: URL
        if let clip {
            wav = clip
        } else {
            guard let synth = try? makeToneWav(seconds: seconds) else {
                print("mem-probe: could not synthesize a probe clip.")
                return
            }
            wav = synth
        }

        print("== mem-probe (phys_footprint) ==")
        print("clip: \(clip?.lastPathComponent ?? "synthetic \(String(format: "%.0f", seconds))s tone")  ·  engines: \(engines.count)")
        if engines.count > 1 {
            print("note: run one engine per invocation (--engines <id>) for clean absolute numbers.\n")
        } else {
            print("")
        }

        var results: [String: Phases] = [:]
        for engine in engines {
            var p = Phases()
            p.baseline = sample()
            p.peakPhys = p.baseline.phys
            p.peakRSS = p.baseline.rss
            do {
                try await engine.loadIfNeeded()
            } catch {
                p.status = "not installed / load failed"
                results[engine.id] = p
                print("· \(engine.id): \(p.status)")
                continue
            }
            p.afterLoad = await settle(&p)

            _ = try? await engine.transcribe(wavURL: wav, biasTerms: [])
            p.afterUnbiased = await settle(&p)

            if engine.supportsRecognitionBias {
                _ = try? await engine.transcribe(wavURL: wav, biasTerms: probeBiasTerms)
                p.afterBiased = await settle(&p)
            } else {
                p.afterBiased = p.afterUnbiased
            }

            await engine.evict()
            p.afterEvict = await settle(&p)
            results[engine.id] = p
            FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
        }

        printTable(results, order: engines.map(\.id))
    }

    // Let deferred frees / async cleanup land before sampling, so a delta reflects steady state, not a
    // transient. Updates the running peaks and returns the sample.
    private static func settle(_ p: inout Phases) async -> Sample {
        try? await Task.sleep(for: .milliseconds(250))
        let s = sample()
        p.peakPhys = max(p.peakPhys, s.phys)
        p.peakRSS = max(p.peakRSS, s.rss)
        return s
    }

    private static func sample() -> Sample {
        let h = hostVM()
        return Sample(phys: physFootprint(), rss: residentSize(),
                      wired: h.wired, fileBacked: h.fileBacked, anon: h.anon, compressed: h.compressed)
    }

    // System-wide page counts via host_statistics64. Noisy (every process contributes), but a model load of
    // hundreds of MB dominates the noise, so the baseline→peak delta shows whether the weights land as
    // file-backed cache (soft/evictable) or anonymous committed memory (hard).
    private static func hostVM() -> (wired: Int64, fileBacked: Int64, anon: Int64, compressed: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0, 0) }
        let page = Int64(sysconf(Int32(_SC_PAGESIZE)))
        return (Int64(stats.wire_count) * page,
                Int64(stats.external_page_count) * page,
                Int64(stats.internal_page_count) * page,
                Int64(stats.compressor_page_count) * page)
    }

    // TASK_VM_INFO.phys_footprint — the same figure Activity Monitor reports under "Memory". Counts dirty
    // + compressed pages; does NOT count clean, file-backed memory-mapped weights (how CoreML loads models).
    private static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MACH_TASK_BASIC_INFO.resident_size — all resident physical pages including paged-in file-backed model
    // weights. Reveals the mmap'd CoreML weight cost that phys_footprint hides (weights the ANE holds may
    // still sit outside this).
    private static func residentSize() -> Int64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private static func makeToneWav(seconds: Double) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(16000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.05 * sinf(2 * .pi * 220 * Float(i) / 16000)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-memprobe-\(ProcessInfo.processInfo.processIdentifier).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func printTable(_ results: [String: Phases], order: [String]) {
        printMetric("phys_footprint (Activity Monitor \"Memory\") — dirty+compressed, excludes clean mmap'd weights",
                    results, order, \.phys, peak: \.peakPhys)
        printMetric("resident_size (RSS) — all resident pages incl. paged-in mmap'd model weights",
                    results, order, \.rss, peak: \.peakRSS)
        printHostDelta(results, order)
        print("\nbase(load) = warm model in memory · +bias = recognition-bias cost (no separate model, ~0)")
        print("· peak = max seen · deltas isolate each cost. Run one engine per")
        print("invocation for clean absolute numbers.")
    }

    // System-wide RAM movement (noisy, but a model load dominates). wired = pinned/unswappable RAM the
    // ANE/GPU needs the weights to occupy — the true accelerator memory cost, invisible to this process's
    // footprint. anon = committed CPU/host memory. Split by phase: load = main model, +bias = the
    // recognition-bias path (no separate model, ~0). This is where the on-disk↔RAM gap resolves.
    private static func printHostDelta(_ results: [String: Phases], _ order: [String]) {
        print("\n── system-wide RAM Δ — wired = pinned accelerator RAM · anon = committed host RAM")
        print("engine                  wired(load)  wired(+bias) anon(load)   anon(+bias)")
        print(String(repeating: "─", count: 78))
        for id in order {
            guard let p = results[id], p.status == "ok" else { continue }
            let wLoad = p.afterUnbiased.wired - p.baseline.wired
            let wBias = p.afterBiased.wired - p.afterUnbiased.wired
            let aLoad = p.afterUnbiased.anon - p.baseline.anon
            let aBias = p.afterBiased.anon - p.afterUnbiased.anon
            print("\(pad(id))  \(col(wLoad, signed: true))  \(col(wBias, signed: true))  \(col(aLoad, signed: true))  \(col(aBias, signed: true))")
        }
    }

    private static func printMetric(
        _ title: String, _ results: [String: Phases], _ order: [String],
        _ key: KeyPath<Sample, Int64>, peak: KeyPath<Phases, Int64>
    ) {
        print("\n── \(title)")
        print("engine                  base(load)   +transcribe   +bias        peak")
        print(String(repeating: "─", count: 78))
        for id in order {
            guard let p = results[id] else { continue }
            guard p.status == "ok" else {
                print("\(pad(id))  \(p.status)")
                continue
            }
            let base = p.afterLoad[keyPath: key] - p.baseline[keyPath: key]
            let transcribe = p.afterUnbiased[keyPath: key] - p.afterLoad[keyPath: key]
            let bias = p.afterBiased[keyPath: key] - p.afterUnbiased[keyPath: key]
            print("\(pad(id))  \(col(base))  \(col(transcribe, signed: true))  \(col(bias, signed: true))  \(col(p[keyPath: peak]))")
        }
    }

    private static func pad(_ s: String) -> String { s.padding(toLength: 22, withPad: " ", startingAt: 0) }

    private static func col(_ bytes: Int64, signed: Bool = false) -> String {
        let s = fmt(bytes)
        let cell = (signed && bytes > 0 ? "+" + s : s)
        return cell.padding(toLength: 11, withPad: " ", startingAt: 0)
    }

    private static func fmt(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if abs(mb) >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }

    private static func makeEngines() -> [any SpeechEngine] {
        EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
    }
}
