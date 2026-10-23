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
For Accessibility, clicking **Allow** in **Settings ▸ Permissions** does that reset for you.

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

Every offered model runs fully on-device. **Settings ▸ Speech Models** lists what is available, with
each model's accuracy (Top, High, Good, or Lower), processing speed, size, and language coverage. Both
labels compare a model with the current models on the list (models marked Legacy aside), so "Top
accuracy" means no current model does noticeably better. Models labeled Top accuracy were roughly tied in our tests — choose among them by
speed, languages, punctuation, or dictionary use. What to look for:

- **Good default:** the one marked **Recommended** — accurate, fast, and multilingual. Start there
  and switch only if something specific pushes you off it.
- **Lots of names or jargon:** a model whose accuracy says it is *better with names and jargon you add
  to your dictionary*. Those models use your dictionary while recognizing speech, so once you add the
  words it keeps missing, they get them right more often. They use more memory. Every other model still
  uses your dictionary to fix near-miss spellings after transcription.
- **No download:** Apple's built-in speech works immediately, but it is labeled Lower accuracy — fine for
  trying things out, not the best choice for everyday dictation.
- **Punctuation without AI rewrite:** one English-only model writes punctuation and capitalization
  for you; its description says so.
- **Noisy places:** the models labeled Top accuracy hold up best with real background noise; the
  others lose noticeably more, and the built-in system model degrades the most.
- **Legacy:** a model marked Legacy still works but is being phased out; switch to the recommended
  model when convenient.

You can switch engines anytime in **Settings ▸ Speech Models**; each is downloaded on first use.
Alongside your first speech model, KeyScribe also fetches a tiny (~1 MB) voice-activity-detection model
that runs on-device to tell whether a recording actually contains speech — so an accidental trigger with
no talking inserts nothing instead of pasting stray text. Like every speech model, it never sends audio
off your machine.

### Can I dictate in a language other than English?

Yes, with one setup step. Pick a speech model that covers your language in **Settings ▸ Speech
Models** — each model lists the languages it handles, and several are broadly multilingual. The
English-only models will not transcribe anything else, and the default model's languages are all
European, so check the list before assuming your language is covered.

If you also use AI rewrite, it writes back in whatever language you dictated — there is no language
setting to find, and you can switch languages between dictations without changing anything. Mixing
languages in one sentence works too: English product and technical terms stay in English inside an
otherwise non-English sentence. If you want a mode to always produce one language, or to translate,
say so in that mode's writing instruction (Settings ▸ Modes ▸ AI rewrite) — for example "Always write
the result in English."

### How do I make KeyScribe spell my names and jargon correctly?

Add them to the **Dictionary** (Settings ▸ Vocabulary, or the on-the-spot correction shortcut). When
you say a term you added, KeyScribe prefers your spelling — the way you wrote it. That works on every
speech model: some models can also steer recognition toward your terms as they listen — **Settings ▸
Speech Models** says which — and on every model KeyScribe fixes near-misses right after
transcription. The fix sticks for next time.

If a word comes out correctly spelled but mis-capitalized or punctuated (say `pi` → `Pi.`), see
[Tips & Tricks](docs/tips.md) for how to pin the exact output.

### What does the dictionary do — and not do?

One thing, honestly: when you say a term you added, KeyScribe writes it your way. It is best-effort,
not a guarantee — a phrase the model badly mangles belongs in **Replacements** instead, which changes
it exactly, every time. That includes short names: a four-letter name is fixed for capitalization only, never for a near-miss
spelling, because it sits one letter away from everyday words (Mike and "make"), and a name of three
letters or fewer is left as heard. A dictionaried compound also snaps its spoken form ("text field" →
"TextField") whenever you say those words; if you only *sometimes* want that, add the term to a
**per-mode** dictionary so it applies only in that mode. And when a mode runs an AI rewrite, your
dictionary terms are shared with your own AI service — marked as intended spellings, not typos, so it
does not "fix" them — including in privacy modes, which turn context off but still send that term hint.

### Can I switch apps or run actions by voice?

Yes, with the experimental **Voice Commands** mode. Turn it on in **Settings ▸ Maintenance ▸
Experimental features**, then assign a shortcut in **Settings ▸ Modes ▸ Voice Commands**. It can't
be shared with another mode: if you pick one that a dictation mode already uses, KeyScribe asks before
moving it, names the modes that lose it, and offers **Undo** afterwards. Use that shortcut when you
want to speak a command:

- **“switch to Mail”** or **“open Safari”** brings the app forward, opening it if needed. App names
  work without setup, and so does the name in an app's menu bar when it differs from the one in the
  Applications folder (“switch to Code” for Visual Studio Code).
- **“open inbox”** goes to an app or web page you have named `inbox` under **Places**. For a web page,
  it uses a matching open tab when possible.
- **“run journal buy milk”** runs an action you have added under **Actions**. A script or macOS
  shortcut receives the extra words only when you have configured it to accept them.
- **“switch to budget”** brings forward an open window whose title says Budget. With two editor
  windows or two terminals open, say a word from the title of the one you want. Only windows on the
  current desktop can be found. **“switch to home assistant”** also finds an open browser tab by its
  title, including tabs in the background. Titles do not have to be said exactly: the words can come in
  any order, and a close mishearing still finds the window or tab.
- **“go back”** returns to the window you were using before your last switch by voice, even in the
  same app. Say it again to switch back. Running an action does not change that destination.

Commands never type your words. An unrecognized command shows an explanation and runs nothing, and a
command that matches more than one place, app, or action asks which one (below). **Preview a command** previews
what a typed command would do without running it.

Before enabling the feature, a notice explains that a recognition mistake can bring an unintended
app and its windows forward, including while sharing your screen. Cancel leaves the feature off.
The explanation remains available under Places in the mode panel.

### A voice command asked “Which one?”

Two or more places, apps, or actions answered to what you said, so KeyScribe lists them, numbered,
instead of guessing. Nothing runs and nothing is typed while the list is shown, and while it waits for
your answer your keystrokes keep going to the app you were in.

Say you have two places, **Personal Mail** and **Work Mail**, each with `mail` under **Other names**:

1. Say **“switch to mail”** with your Voice Commands shortcut. A list of both appears.
2. Use the same shortcut again and say **“two”**, **“number two”**, **“the second one”**, or
   **“the last one”**. The list stays visible while you speak.
3. Work Mail opens. **“go back”** later returns to the app you were in when you gave the first
   command.

Actions work the same way. If two actions answer to `ship`, **“run ship staging”** asks **Which
action?**, and answering **“two”** runs the second one with `staging`, the words from your original
command. The number you answer with is never passed to the action.

You can also click a row. To dismiss the list, say **“cancel”** or **“never mind”**, or click
**Cancel**. Saying a whole new command, such as **“open Work Mail”**, replaces the list. If what you say
is neither a number in the list nor a command, the list stays and shows what was heard, so you can tell
whether your answer was misheard. The list also goes
away after 30 seconds without an answer, when you switch to another app or start a different mode, and
when you change your places or actions; after that, a number means nothing. When more than five match,
KeyScribe asks you to say more of the name instead of listing them.

To get this question on purpose, give two places the same name under **Other names**: Settings explains
that saying it will ask you to choose. If your answer is consistently misheard — “two” arriving as
“tube”, say — add a replacement from `tube` to `two` under **Vocabulary ▸ Voice Commands**.

### A voice command keeps being misheard.

Some command-word mishearings work automatically: `which to Mail` and `witch to Mail` are understood
as “switch to Mail”. The word `to` can also arrive as `two` or `too` after `switch`, `which`, `witch`,
or `go`. These alternatives work in **Preview a command**, too, and leave the original words in History.

When KeyScribe does not recognize a command, or an answer to “Which one?”, it briefly shows what it
heard, such as **Heard “stitch to Mail”**. That is what your speech model wrote, before any of your
replacements, and a long phrase is shortened. Other problems, such as a name that matches nothing, say
what went wrong instead. The heard phrase is hidden, leaving only **Command not recognized**, when you
were in a password field or KeyScribe could not confirm which field you were in. When the command is saved to History, its entry has the complete
phrase.

With the experimental voice commands, open **Settings ▸ Vocabulary ▸ Voice Commands**. Words and
replacements there apply only to commands, and run before KeyScribe reads what you said:

- **A name that sometimes comes out wrong:** add the app's real spelling, such as `Spotify`, to the
  dictionary. This is a best-effort spelling hint, not an explicit mapping from one word to another.
  Dictionary correction applies only to app and place names, never command words or script names and
  arguments. Its fuzzy correction excludes dictionary terms shorter than four characters.
- **A phrase that consistently comes out wrong:** add a replacement for the complete command. For
  example, if you say "switch to Mail" but your speech model hears "switch to male", use these fields:

  | Field | Value |
  |---|---|
  | Word or heard phrase | `switch to male` |
  | Use instead | `switch to Mail` |
  | Match heard phrase as a regular expression (under Pattern matching) | Off |

  Another example: if "open Zoom" is consistently heard as "open soon", replace `open soon` with
  `open Zoom`. A replacement can also fix other misheard command words: `stitch to Mail` → `switch to Mail`.
  Prefer the complete command over replacing a common word everywhere: mode replacements also apply to
  words passed to scripts and shortcuts.

- **A name that needs to work with several commands:** add an app under **Settings ▸ Modes ▸ Voice
  Commands ▸ Places ▸ Add Place… ▸ App…**, choose Mail, and enter `male` in **Other names**. Both "switch to
  male" and "open male" then go to Mail, without rewriting other uses of the word. This is also useful
  for a preferred nickname, such as `email` for Mail.
- **Your own spoken shortcuts:** a replacement for a whole phrase becomes the command, so `code` →
  `switch to Visual Studio Code` lets you say just "code".

To check a phrase, open **Settings ▸ Modes ▸ Voice Commands** and type it into **Preview a command**: it shows what
the phrase is read as after your replacements and what it would do. The preview reads what you type; it
does not listen. It works without opening an app or running a script or shortcut.
For the example above, type `switch to male` and check that it resolves to Mail.

Keep these corrections scoped to **Voice Commands**. Global words and replacements apply here only if
you explicitly include them for this mode; they are left out by default. A Global replacement for a
common word such as `male` could also change ordinary dictation in modes that include it.

### Can a voice command run my own script?

Yes, with the experimental voice commands. In **Settings ▸ Modes ▸ Voice Commands ▸ Actions**, choose
**Add Action ▸ Script**, give it a name to say, and pick the program. Arguments go one per line, and `{text}`
stands for whatever you say after the name: a script named "deploy" with the arguments `--env` and
`{text}` turns "run deploy staging" into `deploy --env staging`. Scripts require **run**; a bare name
or an app-switching phrase never runs a script. If a replacement used to turn something you say into a
script's bare name, such as "ship it" into "deploy prod", change it to produce "run deploy prod". The spoken name can differ from the file name: a script
named "foo" can run `~/bin/bar.sh` when you say "run foo".

For example, save this as `~/bin/note` and run `chmod +x ~/bin/note` so it can run:

```sh
#!/bin/sh
printf '%s\n' "$1" >> "$HOME/notes.txt"
```

Then add a script named "note" with the program `~/bin/note` and one argument, `{text}`. Saying
"run note buy milk" appends "buy milk" to `notes.txt`.

KeyScribe starts the script in the background. The script itself may open another app. KeyScribe waits a moment: if
the script fails by then, the error shows what it printed last. A script still running after that is
shown as started and left to finish. When History is on, its entry updates when it finishes. Later
failures also appear on screen unless you are dictating. It runs without a shell, with
the environment KeyScribe started with. Opened normally, its `PATH` holds only the system folders, so call
other tools by their full path or set `PATH` at the top of the script.
Use **Preview a command** to see the exact command a phrase would run, without running it.

The dictionary never changes a script or shortcut's name or the words you pass it. If a name keeps coming out
wrong, add the misheard form as another spoken name.

Every Add Script sheet warns that recognition mistakes can start an unintended script or pass it
different words. A script runs with your account's permissions; for actions that cannot be undone, use
a script that asks for confirmation.

### Can a voice command run a Shortcut?

Yes. Choose **Add Action ▸ Shortcut from Shortcuts…**, pick one of your shortcuts, and give it a name to say. To hand it
what you say after the name, set **Input** to `{text}`: a shortcut named "journal" with that input turns
"run journal buy milk" into the shortcut receiving "buy milk" as text. It runs in the background like a
script. A shortcut that asks you something, such as Ask for Input or Choose from Menu, waits for your
answer; KeyScribe shows it as started and records its final result when History is on. A shortcut may
also open another app.
If the picker is empty, create a shortcut in Shortcuts, then choose **Refresh List** from the picker.

Every Add Shortcut sheet warns that a misheard name can start the shortcut or give it different words,
and that its steps can send messages, change files, or send your words to online services.

### Can I edit text I've already written?

Yes — select the text, trigger an edit-in-place mode, and speak an instruction. KeyScribe rewrites
the selection in place.

### I pressed a mode's shortcut and nothing happened, or it cancelled straight away.

The mode is limited to certain apps or websites, and you pressed its shortcut somewhere it does not
apply. What you get depends on which kind of rule the mode uses:

- **Limited to apps.** The shortcut does nothing, and the key behaves normally in that app. KeyScribe
  releases a shortcut in apps where the mode it belongs to cannot run, so a mode scoped to one app no
  longer takes that key away from every other app.
- **Limited to a website or window title.** You hear the start sound and then the cancel sound.
  KeyScribe cannot tell which page or window you are on until dictation begins, so it has to start
  before it can rule the mode out. Nothing is recorded, transcribed, or inserted.

Two ways to change it. To dictate plainly there instead, give Plain Dictation the same shortcut — a
shortcut only falls back to Plain Dictation where Plain Dictation also owns it. To silence a website
rule outside its browser, add the browser to the same rule; see
[Pair a website rule with its browser](docs/getting_started.md#pair-a-website-rule-with-its-browser).

### Is there a limit on how long one dictation can be?

Yes — five minutes per dictation. Thirty seconds before the limit, the recording indicator gets an
orange ring that runs down and the HUD counts down ("Stops in 0:30"). When time runs out, KeyScribe
stops listening and inserts everything you said, just as if you had released the key. Start another
dictation to keep going.

A dictation stopped by the limit is inserted **without** its AI rewrite, even in a mode that normally
uses one. It ends mid-thought, and a rewrite would treat the fragment as a finished piece. The HUD
tells you when this happens. A mode that normally presses Return after inserting does not press it, so
an unfinished message is never sent. In an edit-in-place mode, a dictation stopped by the limit leaves your
selected text unchanged.

### Where are my settings and history stored?

Everything is a plain file under `~/Library/Application Support/KeyScribe/` — TOML config, JSONL
history (one file per day), and downloaded model weights under `models/`. You can inspect, back up,
or delete any of it. Removing that folder resets KeyScribe.

## Permissions

### Which permissions does KeyScribe need, and why?

Two for everyday dictation, granted in **System Settings ▸ Privacy & Security**:

- **Microphone** — on-device speech recognition.
- **Accessibility** — detecting a modifier-key trigger (Fn / right-⌥ / right-⌘) and inserting
  transcribed text into the focused app. (A key+modifier trigger like ⌃⌥E is registered as a system
  hotkey and needs no permission.)

A third, **Automation**, is requested only when KeyScribe has to ask your browser something: the
current tab's address for a mode that routes by website, or, with the experimental voice commands, the
open tabs' addresses and titles (in every window, which can include private ones) so it can switch to a saved web
page. Nothing it reads leaves your Mac.
If you use neither, the request never appears.

KeyScribe does **not** request Input Monitoring.

### I toggled a permission on, but KeyScribe still says it's missing.

macOS caches permission verdicts for the life of a running process, so **quit and relaunch
KeyScribe** after changing a toggle. If it still doesn't take effect, the grant may be bound to an old
build signature — common after switching from a build you made yourself to a downloaded release.
System Settings keeps showing the old entry as on, but it no longer applies. When Accessibility goes
missing this way, KeyScribe opens **Settings ▸ Permissions** for you at launch. Click **Allow** there:
KeyScribe resets the old entry so you can turn it on again.
For other permissions, remove KeyScribe from that permission's list and re-add it, or reset it with
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

### Background audio changes while I dictate.

**Settings ▸ General ▸ Other audio** decides what happens to other playback while you dictate:
**Quiet** (the default) turns it down, **Mute** silences it, and **Unchanged** leaves it alone. If
start/end sounds are also on, the change begins *after* the start sound so the cue isn't swallowed —
turn the start sound off if you want it to take effect instantly.

### macOS re-prompts for permissions on every rebuild (building from source).

Ad-hoc signatures change each build, so macOS treats every rebuild as a new app. Create the
`KeyScribe Local` self-signed certificate (one-time) so the signature is stable across rebuilds —
steps in [BUILD.md](BUILD.md).
