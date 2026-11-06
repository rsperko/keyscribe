import Foundation
import KeyScribeKit

enum FrontProbe {
    @MainActor
    static func run(after delay: Double, samples: Int) async -> Int32 {
        try? await Task.sleep(for: .seconds(delay))
        for sample in 0..<max(samples, 1) {
            if sample > 0 { try? await Task.sleep(for: .seconds(1)) }
            let started = DispatchTime.now()
            let app = AgentFront.frontmost()
            let reading = await AgentFront().reading()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            var line = "front=\(app?.bundle ?? "none") ms=\(String(format: "%.0f", ms)) "
            switch reading {
            case .unknown(let why):
                line += "unknown=\(why)"
            case .pane(let pane):
                let facts = SystemTerminalFacts()
                let processes = (pane.tty.flatMap(facts.processes(onTTY:)) ?? []).map { "\($0.pid):\(($0.executable as NSString).lastPathComponent)" }.joined(separator: ",")
                line += "tty=\(pane.tty ?? "none") via=\(pane.multiplexers.joined(separator: ">")) processes=\(processes)"
                if let view = pane.view { line += " view=\(view.host):\(view.server):\(view.pane)" }
            }
            print(line)
            fflush(stdout)
        }
        return 0
    }
}
