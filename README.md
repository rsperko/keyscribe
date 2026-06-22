# KeyScribe

Privacy-first, local-first voice dictation for macOS. Speech recognition always runs on-device.

See `AGENTS.md` for orientation and `docs/` for the full design spec.

## Build & run

No Apple Developer account, certificate, or password required — just the Swift toolchain.
**Prerequisites:** macOS 26+ on Apple silicon, Xcode installed and selected
(`sudo xcode-select -s /Applications/Xcode.app`), and — one-time, for the Qwen3-ASR engine —
`xcodebuild -downloadComponent MetalToolchain`.

```bash
swift build            # build everything
swift test             # run KeyScribeKit unit tests (pure logic)
./make-app.sh          # build + assemble + sign KeyScribe.app (ad-hoc by default)
open ./KeyScribe.app     # launch (menu-bar app — look for the waveform glyph)
```

Ad-hoc builds get a new signature each rebuild, so macOS may re-prompt for permissions. To make
the Microphone / Input Monitoring / Accessibility grants survive rebuilds, create a self-signed
`KeyScribe Local` certificate (`make-app.sh` auto-detects it). **Full instructions, prerequisites,
signing options, and troubleshooting are in [`BUILD.md`](BUILD.md).**

Logs: `log stream --predicate 'process == "KeyScribe"' --level debug`

## First-run verification (needs a person + a microphone)

The live dictation loop can only be verified by a human:

1. Launch `KeyScribe.app`. The first-run window appears.
2. **Download** the English speech model (progress shown). It stays on your Mac.
3. **Grant** Microphone, then Input Monitoring, then Accessibility when prompted.
4. Focus any text field, **hold Fn (Globe)**, say a sentence, **release**.
5. Confirm: the text is inserted, and a single **⌘Z** removes the whole dictation.
6. Move focus to another app mid-dictation → result is **copied** instead, with a HUD notice.

> If the Globe key is mapped to a system action (Emoji, Dictation, Input Source) it may fire
> alongside KeyScribe. Set it to "Do Nothing" in System Settings ▸ Keyboard, or pick **Right Option**
> in KeyScribe ▸ Settings as the conflict-free alternative.

## Layout

- `Sources/KeyScribeKit/` — pure, OS-free logic (unit-tested).
- `Sources/KeyScribe/` — the menu-bar app: OS adapters + SwiftUI/AppKit.
- `Tests/KeyScribeKitTests/` — pure-logic tests.
- `docs/` — design spec. `spikes/` — throwaway M0 de-risk spikes.

License: GPLv3 (file added at release, M7).
