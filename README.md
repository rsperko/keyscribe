# KeyScribe

**Local-first voice dictation for macOS. Your voice never leaves your Mac.**

KeyScribe turns speech into text wherever you type: hold a key, say the thought, release, and the
words land in the app you're already using. It feels like system dictation grew power-user muscle:
mode routing, correction shortcuts, edit-in-place, local history, and optional cleanup that uses
your provider and your key.

Speech recognition runs **100% on-device**. There is no cloud STT, no account, no subscription, and
no telemetry. The only thing that can ever leave your Mac is optional BYOK LLM cleanup, over a
payload you control.

KeyScribe is early, open source, and built for people who want a local-first alternative to
Superwhisper, Wispr Flow, Aqua, and MacWhisper without giving up serious workflow control.

---

## Why it feels different

- **Your voice stays local.** Speech recognition is always on-device. Turn off optional cleanup and
  KeyScribe never touches the network after model download.
- **Dictation fits the work.** One mode can write a terse Slack update, another can draft email,
  another can format Markdown, and another can rewrite a selected paragraph in place.
- **Corrections do not break your flow.** Fix a misheard name, command, or acronym from the current
  app or a history item, and future dictations learn it through dictionary bias or replacements.
- **Insertion behaves like a good Mac citizen.** Dictations insert atomically, undo in one **⌘Z**,
  preserve your clipboard when safe, and avoid inserting into the wrong app if focus changes.
- **The files are yours.** Config, modes, replacements, prompt fragments, and history are plain files
  under `~/Library/Application Support/KeyScribe/`; secrets live in macOS Keychain.

Full privacy details are in [PRIVACY.md](PRIVACY.md).

---

## Install

### Homebrew

```bash
brew install rsperko/tap/keyscribe
```

> Homebrew 6+ guards third-party taps, so the first install asks you to trust this one — confirm when
> prompted, or run `brew tap rsperko/tap && brew trust rsperko/tap` beforehand.

### Direct download

Grab the latest notarized `KeyScribe-<version>.dmg` from the [Releases](https://github.com/rsperko/keyscribe/releases)
page, open it, and drag **KeyScribe** to Applications.

KeyScribe is a menu-bar app — after launching, look for the waveform glyph in the menu bar (no Dock
icon, no window).

### Build from source

No Apple Developer account or paid certificate required — just the Swift toolchain:

```bash
git clone https://github.com/rsperko/keyscribe.git
cd keyscribe
KEYSCRIBE_VARIANT=release ./make-app.sh && open ./KeyScribe.app
```

Prerequisites and signing options (so permissions survive rebuilds) are in [BUILD.md](BUILD.md).

---

## First run

1. Launch KeyScribe. The first-run window appears.
2. **Download** an on-device speech model (progress shown). It stays on your Mac.
3. **Grant** Microphone, then Accessibility when prompted.
4. Focus any text field, **hold Fn (Globe)**, say a sentence, **release**.
5. The text is inserted where you're typing — and a single **⌘Z** undoes the whole dictation.

> If the Globe key is mapped to a system action (Emoji, Dictation, Input Source) it may fire
> alongside KeyScribe. Set it to "Do Nothing" in **System Settings ▸ Keyboard**, or pick **Right
> Option** in KeyScribe ▸ Settings as the conflict-free alternative. More in [FAQ.md](FAQ.md).

---

## Features

**Dictate anywhere on the Mac.** Hold-to-talk insertion works in native, Electron/Chromium, and web
apps. The whole dictation lands as one undoable insert, and focus-race protection copies the result
to the clipboard instead of pasting into the wrong place.

**Route by mode, app, URL, or voice.** Modes are reusable pipeline presets, not hardcoded app hacks.
Use one trigger key across multiple contexts, pick a one-shot mode from the menu bar, or end a
dictation with a phrase like "as an email" to route the text through another mode before insertion.

**Edit while speaking.** Say "new line", "new paragraph", "scratch that", or "begin verbatim ... end
verbatim" and KeyScribe applies those instructions before the text lands.

**Fix it once, and it sticks.** Add a dictionary entry or replacement from a global shortcut, a
selection, or a history item. Dictionary entries bias supported engines; replacements auto-substitute
from then on.

**Rewrite selected text in place.** Select a paragraph, trigger an edit mode, and say "make this
shorter", "turn this into bullets", or "make this warmer." KeyScribe replaces the selection in the
app you're already using.

**Choose the local engine.** Seven on-device speech engines are available in-app: Parakeet TDT v3,
Parakeet TDT-CTC 110M, Whisper, Apple, Qwen3-ASR 0.6B, Qwen3-ASR 1.7B, and Moonshine Base (EN).
Trade accuracy, speed, and footprint without sending audio to a server.

**Optional cleanup on your terms.** BYOK LLM cleanup can strip filler, fix grammar, or reformat text
using your OpenAI-compatible provider and key. Best-effort redaction tokenizes recognizable sensitive
spans before rewrite and restores them locally afterward.

**Inspectable history.** Browse and reuse past dictations stored as local JSONL, with processing
details that show what was heard, transformed, rewritten, or kept local.

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
