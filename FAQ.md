# KeyScribe FAQ & Troubleshooting

## First-run fixes

### I launched KeyScribe but do not see a window.

KeyScribe is a menu-bar app. Look for the waveform glyph in the macOS menu bar. Open the menu from
there to reach Settings, History, speech models, and mode choices.

### The Globe (Fn) key triggers Emoji or Apple Dictation.

The Globe key is mapped to a system action. Either set it to **"Do Nothing"** in **System Settings >
Keyboard**, or pick **Right Option** as the trigger key in **KeyScribe > Settings**. Trigger keys are
per-mode.

### I granted a permission, but KeyScribe still says it is missing.

Quit and relaunch KeyScribe after changing macOS permission toggles. macOS caches permission
verdicts for the life of a running process. If it still does not take effect, remove KeyScribe from
that permission list and re-add it, or reset it with `tccutil reset <Service> com.keyscribe.app`.

### My dictation went to the clipboard instead of being typed in.

That is the focus-race fallback. If focus changes during dictation, KeyScribe copies the result
instead of inserting it into the wrong app. Paste it where you want it.

### Can KeyScribe preserve my clipboard while inserting?

The default `paste` insertion method briefly uses the macOS clipboard to stage the text, then restores
what was there. This is usually safe for ordinary text and small rich clipboards, but very large,
non-text, or unusual clipboard contents can degrade to plain text or be cleared if KeyScribe cannot
snapshot and restore them.

If preserving the clipboard matters more than insertion speed, set that mode's TOML to
`insertion = "type"`. This types characters directly instead of staging text on the clipboard. The
`insert` method can also avoid the clipboard in native Mac fields when Accessibility insertion works,
but it falls back to paste when that direct insert cannot be verified.

### Selecting a Qwen3-ASR model crashes in a source build.

The Metal Toolchain was not installed when the app was built. Run
`xcodebuild -downloadComponent MetalToolchain`, then rebuild with `./make-app.sh`. Packaged
downloads include the required bundled artifact.

## Using KeyScribe

### Does any of my speech or text get sent anywhere?

Speech recognition is always on-device — your audio is never sent anywhere. The only thing that can
leave your Mac is an optional, you-keyed LLM cleanup over a redacted payload, and it is off unless
you enable it. See [PRIVACY.md](PRIVACY.md) for the full picture.

### Which speech model should I pick?

Every offered model runs fully on-device; the trade-off is accuracy vs. speed vs. footprint:

- **Best accuracy:** Qwen3-ASR 1.7B.
- **Best default for English:** Parakeet TDT-CTC 110M — compact, fast, and accurate.
- **Best multilingual balance:** Qwen3-ASR 0.6B.
- **Smaller / faster footprint:** Whisper Small (English), Moonshine Base.
- Apple Speech, Whisper Large v3 Turbo, and Parakeet TDT v3 are also available. Apple Speech appears
  only on macOS 26+.

You can switch engines anytime in **Settings ▸ Speech Models**; each is downloaded on first use.

### Why is one model badged "no recognition bias"?

Recognition bias teaches the model your names, jargon, and acronyms while it transcribes. Every
model except Moonshine supports it. Moonshine has no on-device bias path, so KeyScribe can instead
run dictionary recovery after transcription to fix close matches.

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
build signature. Remove KeyScribe from that permission's list and re-add it, or reset it with
`tccutil reset <Service> com.keyscribe.app`.

## Troubleshooting

### Background audio cuts out while I dictate.

With **Settings ▸ General ▸ Mute system audio while dictating** on, playback is muted for the
duration. If start/end sounds are also on, the mute begins *after* the start sound so the cue isn't
swallowed — turn the start sound off if you want an instant mute.

### macOS re-prompts for permissions on every rebuild (building from source).

Ad-hoc signatures change each build, so macOS treats every rebuild as a new app. Create the
`KeyScribe Local` self-signed certificate (one-time) so the signature is stable across rebuilds —
steps in [BUILD.md](BUILD.md).
