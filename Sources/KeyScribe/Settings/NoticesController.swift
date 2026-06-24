import AppKit
import SwiftUI

@MainActor
final class NoticesController {
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: NoticesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About & Notices"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct NoticesView: View {
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("KeyScribe").font(.largeTitle.bold())
                Text(versionLine)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Privacy-first, local-first voice dictation for macOS. Speech recognition always runs on this Mac.")
                    .foregroundStyle(.secondary)
                Divider()
                Text("License").font(.headline)
                Text("KeyScribe is open source under the GNU General Public License v3.")
                    .font(.callout)
                Text("Open-source notices").font(.headline)
                Text("""
                Speech-recognition model weights (downloaded at runtime, not part of this app's source):
                • Parakeet TDT v3 / TDT-CTC 110M — NVIDIA, CC-BY-4.0.
                • pyannote segmentation/speaker models — CC-BY-4.0.
                • Whisper — OpenAI, MIT.
                • Qwen3-ASR 0.6B / 1.7B — Alibaba Cloud (Qwen), Apache-2.0.
                • Moonshine Base (English) — Moonshine AI, MIT.
                • Apple on-device speech — macOS system framework.

                Bundled libraries: FluidAudio, swift-transformers, swift-jinja (Apache-2.0); WhisperKit, \
                moonshine-swift, ONNX Runtime, MLX Swift, TOMLKit (MIT). See THIRD-PARTY-NOTICES for the full list.
                """)
                .font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 420)
    }
}
