# KeyScribe FAQ & Troubleshooting

## First-run fixes

### I launched KeyScribe but do not see a window.

KeyScribe is a menu-bar app. Look for the waveform glyph in the macOS menu bar. Open the menu from
there to reach Settings, History, speech models, and mode choices.

### I cannot find the KeyScribe icon in my menu bar.

**Double-click KeyScribe in Applications.** It is already running, so this opens Settings rather
than starting a second copy — that works no matter why the icon is missing.

The usual cause is that the menu bar has run out of room. On a Mac with a notch, icons that do not
fit disappear behind it — and because the frontmost app's own menus take the space on the left,
switching to an app with a lot of menus can push icons under the notch that were visible a moment
earlier. Quitting another menu-bar app, or switching to an app with fewer menus, brings it back. A
menu-bar manager such as Bartender, Ice, or Vanilla may also be hiding it — check that app's own
settings. Dictation keeps working the whole time; the trigger key does not depend on the icon being
visible.

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

### Can KeyScribe preserve my clipboard while inserting or editing a selection?

The default `paste` insertion method briefly uses the macOS clipboard to stage the text, then restores
what was there. Edit Selection modes also briefly use normal copy/paste to capture the selected text.
This is usually safe for ordinary text and small rich clipboards, but very large, non-text, or unusual
clipboard contents can degrade to plain text or be cleared if KeyScribe cannot snapshot and restore
them.

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
- **Best in noisy places:** Whisper Large v3 Turbo or Qwen3-ASR 1.7B. Both barely lose accuracy
  with real background noise; the smaller models lose noticeably more, and Apple Speech degrades
  the most. If you often dictate in cafés, open offices, or transit, pick one of these two.
- **Smaller / faster footprint:** Whisper Small (English), Moonshine Base.
- Apple Speech, Whisper Large v3 Turbo, and Parakeet TDT v3 are also available. Apple Speech appears
  only on macOS 26+.

You can switch engines anytime in **Settings ▸ Speech Models**; each is downloaded on first use.
Alongside your first speech model, KeyScribe also fetches a tiny (~1 MB) voice-activity-detection model
that runs on-device to tell whether a recording actually contains speech — so an accidental trigger with
no talking inserts nothing instead of pasting stray text. Like every speech model, it never sends audio
off your machine.

### Can I dictate in a language other than English?

Yes, with one setup step. Pick a speech model that covers your language in **Settings ▸ Speech
Models** — Whisper Large v3 Turbo (99 languages), Qwen3-ASR 0.6B/1.7B (52), and Apple Speech (20) are
the broad ones. The English-only models (Whisper Small, Moonshine Base, Parakeet TDT-CTC 110M) and
Parakeet TDT v3, whose 25 languages are all European, will not transcribe outside their coverage.

If you also use AI rewrite, it writes back in whatever language you dictated — there is no language
setting to find, and you can switch languages between dictations without changing anything. Mixing
languages in one sentence works too: English product and technical terms stay in English inside an
otherwise non-English sentence. If you want a mode to always produce one language, or to translate,
say so in that mode's writing instruction (Settings ▸ Modes ▸ AI rewrite) — for example "Always write
the result in English."

### How do I make KeyScribe spell my names and jargon correctly?

Add them to the **Dictionary** (Settings ▸ Vocabulary, or the on-the-spot correction shortcut). When
you say a term you added, KeyScribe prefers your spelling — the way you wrote it. That works on every
speech model: two of the model families (Whisper and Qwen3) also steer recognition toward your terms
as they listen, and on every model KeyScribe fixes near-misses right after transcription. The fix
sticks for next time.

If a word comes out correctly spelled but mis-capitalized or punctuated (say `pi` → `Pi.`), see
[Tips & Tricks](docs/tips.md) for how to pin the exact output.

### What does the dictionary do — and not do?

One thing, honestly: when you say a term you added, KeyScribe writes it your way. It is best-effort,
not a guarantee — a phrase the model badly mangles belongs in **Replacements** instead, which changes
it exactly, every time. A dictionaried compound also snaps its spoken form ("text field" →
"TextField") whenever you say those words; if you only *sometimes* want that, add the term to a
**per-mode** dictionary so it applies only in that mode. And when a mode runs an AI rewrite, your
dictionary terms are shared with your own AI service — marked as intended spellings, not typos, so it
does not "fix" them — including in privacy modes, which turn context off but still send that term hint.

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

### How do I collect information for a bug report?

Open **Settings ▸ Maintenance ▸ Diagnostics** and click **Copy Diagnostics**. It copies your version,
granted permissions, speech model, mode settings, and recent dictation outcomes — with no transcript
text, clipboard contents, or API keys. The same report is available from a terminal as
`/Applications/KeyScribe.app/Contents/MacOS/KeyScribe --diagnose`. See
[Troubleshooting](docs/troubleshooting.md) for how to read it.

### My dictation said it worked, but the text never appeared.

`inserted` means KeyScribe posted the paste keystroke, not that the app accepted it. See
[Troubleshooting](docs/troubleshooting.md) for how to tell the cases apart and what to change.

### Background audio cuts out while I dictate.

With **Settings ▸ General ▸ Mute system audio while dictating** on, playback is muted for the
duration. If start/end sounds are also on, the mute begins *after* the start sound so the cue isn't
swallowed — turn the start sound off if you want an instant mute.

### macOS re-prompts for permissions on every rebuild (building from source).

Ad-hoc signatures change each build, so macOS treats every rebuild as a new app. Create the
`KeyScribe Local` self-signed certificate (one-time) so the signature is stable across rebuilds —
steps in [BUILD.md](BUILD.md).
