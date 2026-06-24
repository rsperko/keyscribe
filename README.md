# KeyScribe

**Privacy-first voice dictation for macOS. Your voice never leaves your Mac.**

KeyScribe turns speech into text wherever you type — a hold-to-talk key, a sentence, a release, and
the words land in the app you're already in. Speech recognition runs **100% on-device**. The only
thing that can ever leave your Mac is an optional, you-keyed LLM cleanup — and only over a payload
you control. Open source, GPLv3. No account, no subscription, no telemetry.

A local-first alternative to Superwhisper / MacWhisper.

<!-- Screenshots and a demo GIF land in a later pass. -->

---

## Why KeyScribe

- **Speech recognition is always on-device.** There is no cloud speech-to-text, ever.
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected or sent.
- **The only outbound call is an optional BYOK LLM cleanup** — using *your* provider and *your* key,
  over a redacted payload. Turn it off and KeyScribe never touches the network after model download.
- **Best-effort redaction wedge:** sensitive spans are tokenized out *before* any LLM call and
  restored locally afterward, so the model never sees them.
- **Your API keys live in the macOS Keychain**, never in plaintext config.
- **Plain files, no hidden database.** Config and history live under
  `~/Library/Application Support/KeyScribe/` — easy to read, back up, or delete.

Full details in [PRIVACY.md](PRIVACY.md).

---

## Install

> **First release packaging is on the way.** The notarized DMG and Homebrew tap below ship with the
> first tagged release — until then, [build from source](#build-from-source) (it's one command).

### Homebrew

```bash
brew install rsperko/tap/keyscribe
```

### Direct download

Grab the latest notarized `KeyScribe.dmg` from the [Releases](https://github.com/rsperko/keyscribe/releases)
page, open it, and drag **KeyScribe** to Applications.

KeyScribe is a menu-bar app — after launching, look for the waveform glyph in the menu bar (no Dock
icon, no window).

### Build from source

No Apple Developer account or paid certificate required — just the Swift toolchain:

```bash
git clone https://github.com/rsperko/keyscribe.git
cd keyscribe
./make-app.sh && open ./KeyScribe.app
```

Prerequisites and signing options (so permissions survive rebuilds) are in [BUILD.md](BUILD.md).

---

## First run

1. Launch KeyScribe. The first-run window appears.
2. **Download** an on-device speech model (progress shown). It stays on your Mac.
3. **Grant** Microphone, then Input Monitoring, then Accessibility when prompted.
4. Focus any text field, **hold Fn (Globe)**, say a sentence, **release**.
5. The text is inserted where you're typing — and a single **⌘Z** undoes the whole dictation.

> If the Globe key is mapped to a system action (Emoji, Dictation, Input Source) it may fire
> alongside KeyScribe. Set it to "Do Nothing" in **System Settings ▸ Keyboard**, or pick **Right
> Option** in KeyScribe ▸ Settings as the conflict-free alternative. More in [FAQ.md](FAQ.md).

---

## Features

**Dictation that works everywhere.** Hold-to-talk insertion into native, Electron/Chromium, and web
apps. The whole dictation inserts atomically — one ⌘Z removes it. Change focus mid-dictation and the
result is safely copied to the clipboard with a HUD notice instead of going to the wrong place.
Per-mode trigger keys (Fn/Globe, Right Option) with configurable tap-vs-hold timing.

**Pick your on-device engine.** Seven speech engines, all fully local, downloaded and installed
in-app — Parakeet TDT v3, Parakeet TDT-CTC 110M, Whisper, Apple, Qwen3-ASR 0.6B, Qwen3-ASR 1.7B, and
Moonshine Base (EN). Trade accuracy against speed against footprint. **Dictionary bias** teaches the
engine your names, jargon, and acronyms so they transcribe correctly (6 of 7 engines support it; the
one that doesn't is clearly badged).

**Modes — configurable, not app-specific.** A Mode is a named, reusable bag of config that a single
generic pipeline executes (no per-app hacks). Modes can activate automatically from context or by a
spoken trigger phrase, or you can pick one for the next dictation from the menu bar. Each mode owns
its trigger keys, cleanup behavior, context sharing, privacy toggle, and prompt.

**Optional text cleanup.** A BYOK LLM rewrite can strip filler, fix grammar, and reformat — using
your own OpenAI-compatible provider and key. **Replacements** auto-substitute text as you dictate.

**Fix it once, and it sticks.** When KeyScribe mishears a name or term, a global shortcut lets you
add a dictionary entry or replacement on the spot — no opening Settings, no breaking flow. Dictionary
entries bias future recognition; replacements auto-substitute from then on. Add corrections from a
standalone panel, a global shortcut, or straight from a history item.

**Edit-in-place.** Select text, speak an instruction, and KeyScribe rewrites the selection in place.
Any mode can be an edit-in-place mode.

**Local history.** Browse and reuse past dictations, stored as plain JSONL files on your Mac — never
uploaded.

---

## Requirements

- macOS 26+ on Apple silicon.

---

## Contributing

KeyScribe is open source under GPLv3. Bug reports, fixes, and new built-in modes are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the build setup and project conventions.

## License

[GPLv3](LICENSE). Third-party libraries and downloaded model weights retain their own licenses — see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Documentation

- [BUILD.md](BUILD.md) — building, signing, and prerequisites from source.
- [PRIVACY.md](PRIVACY.md) — exactly what stays local and what (optionally) leaves.
- [FAQ.md](FAQ.md) — permissions, key conflicts, engine choice, troubleshooting.
- [`docs/`](docs/) — the full design spec (architecture, pipeline, modes, storage).
