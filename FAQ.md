# KeyScribe FAQ & Troubleshooting

## Using KeyScribe

### Does any of my speech or text get sent anywhere?

Speech recognition is always on-device — your audio is never sent anywhere. The only thing that can
leave your Mac is an optional, you-keyed LLM cleanup over a redacted payload, and it is off unless
you enable it. See [PRIVACY.md](PRIVACY.md) for the full picture.

### Which speech engine should I pick?

All seven run fully on-device; the trade-off is accuracy vs. speed vs. footprint:

- **Best accuracy:** Qwen3-ASR 1.7B.
- **Best balance of accuracy and speed:** Qwen3-ASR 0.6B — a good default.
- **Smaller / faster footprint:** Parakeet TDT-CTC 110M, Moonshine Base.
- Apple and Whisper are also available.

You can switch engines anytime in **Settings ▸ Speech Models**; each is downloaded on first use.

### Why is one engine badged "no dictionary bias"?

Dictionary bias teaches the engine your names, jargon, and acronyms so they transcribe correctly. Six
of the seven engines support it. Moonshine has no on-device bias path, so it's badged so you know the
dictionary won't influence its output.

### How do I make KeyScribe spell my names and jargon correctly?

Add them to the **Dictionary** (Settings ▸ Vocabulary, or the on-the-spot correction shortcut). For
text you always want swapped (expansions, fixes), add a **Replacement**. When KeyScribe mishears
something, the global correction shortcut lets you add a dictionary entry or replacement without
leaving what you're doing — and the fix sticks for next time.

### Can I edit text I've already written?

Yes — select the text, trigger an edit-in-place mode, and speak an instruction. KeyScribe rewrites
the selection in place.

### Where are my settings and history stored?

Everything is a plain file under `~/Library/Application Support/KeyScribe/` — TOML config, JSONL
history (one file per day), and downloaded model weights under `models/`. You can inspect, back up,
or delete any of it. Removing that folder resets KeyScribe.

## Permissions

### Which permissions does KeyScribe need, and why?

Two, granted in **System Settings ▸ Privacy & Security**:

- **Microphone** — on-device speech recognition.
- **Accessibility** — detecting a modifier-key trigger (Fn / right-⌥ / right-⌘) and inserting
  transcribed text into the focused app. (A key+modifier trigger like ⌃⌥E is registered as a system
  hotkey and needs no permission.)

KeyScribe does **not** request Input Monitoring.

### I toggled a permission on, but KeyScribe still says it's missing.

macOS caches permission verdicts for the life of a running process, so **quit and relaunch
KeyScribe** after changing a toggle. If it still doesn't take effect, the grant may be bound to an old
build signature — remove KeyScribe from that permission's list and re-add it, or reset it with
`tccutil reset <Service> com.keyscribe.app`.

## Troubleshooting

### The Globe (Fn) key triggers Emoji or Dictation instead of (or alongside) KeyScribe.

The Globe key is mapped to a system action. Either set it to **"Do Nothing"** in **System Settings ▸
Keyboard**, or pick **Right Option** as the trigger key in **KeyScribe ▸ Settings** — a conflict-free
alternative. Trigger keys are per-mode.

### My dictation went to the clipboard instead of being typed in.

That's by design: if you move focus to another app mid-dictation, KeyScribe copies the result to the
clipboard (with a HUD notice) rather than inserting it into the wrong place. Paste it where you want
it.

### Background audio cuts out while I dictate.

With **Settings ▸ General ▸ Mute system audio while dictating** on, playback is muted for the
duration. If start/end sounds are also on, the mute begins *after* the start sound so the cue isn't
swallowed — turn the start sound off if you want an instant mute.

### Selecting a Qwen3-ASR engine crashes with "Failed to load the default metallib."

This only affects builds from source: the Metal Toolchain wasn't installed at build time. Run
`xcodebuild -downloadComponent MetalToolchain`, then rebuild with `./make-app.sh`. See
[BUILD.md](BUILD.md).

### macOS re-prompts for permissions on every rebuild (building from source).

Ad-hoc signatures change each build, so macOS treats every rebuild as a new app. Create the
`KeyScribe Local` self-signed certificate (one-time) so the signature is stable across rebuilds —
steps in [BUILD.md](BUILD.md).
