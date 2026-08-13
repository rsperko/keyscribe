# Troubleshooting

For first-run blockers (no menu-bar icon, permission prompts, the Globe key opening Emoji), start
with the [FAQ](../FAQ.md). This page is for the harder case: dictation ran, but the text did not end
up where you expected.

## Collect a diagnostic snapshot

Open **Settings ▸ Maintenance ▸ Diagnostics** and click **Copy Diagnostics**. That puts the whole
snapshot on your clipboard, ready to paste into a bug report.

If you prefer the terminal, or want to hand the output straight to a script, run the app binary with
`--diagnose`:

```bash
/Applications/KeyScribe.app/Contents/MacOS/KeyScribe --diagnose
```

If you installed the development build, use `KeyScribeDev.app` instead. Add `--dictations 25` to
include more history, or `--dictations 0` for none.

The output covers the version you are running, which permissions macOS has granted, your speech
model, every mode's delivery settings, and how your recent dictations ended. Paste it into a bug
report — or hand it to whichever coding agent you use, which saves the back-and-forth of being asked
for your version and settings one at a time.

One caveat on the permissions it reports: macOS attributes microphone access to whatever launched a
process, so running the binary from a terminal can report the microphone as denied even when the app
itself has access. Accessibility is reported accurately. If the microphone line looks wrong, trust
KeyScribe's own Settings screen.

**What it does not contain:** transcript text, clipboard contents, or API keys. Dictation rows carry
only the mode, speech model, microphone, outcome, and the names of the connection and model used.
The full local history — which *does* contain what you said — stays on your machine unless you
choose to share it. See [Privacy](../PRIVACY.md).

## "It said it worked, but nothing appeared"

Read the outcome of the dictation in the `--diagnose` output. It splits the problem in half.

### `inserted`

KeyScribe posted the paste keystroke. On the default `paste` insertion method, the only thing
verified is that the text reached the clipboard — not that the target app accepted it. So `inserted`
means "delivered as far as we can see," not "landed."

If nothing appeared, the text was almost certainly on your clipboard for a moment. Check where focus
actually was at the end of the dictation: the paste goes to whatever window is key, which may not be
the window you were looking at. Apps that intercept or delay ⌘V — terminals with paste protection,
remote-desktop and VM clients, some Electron apps — can swallow it.

Two things to try, in order:

1. Set that mode's `insertion = "insert"` in its TOML. This uses Accessibility to write the text
   directly and verifies it by reading the field back, falling back to paste when it cannot. It
   works in native Mac fields and is a no-op elsewhere.
2. Set `insertion = "type"`. This types the characters instead of pasting, which gets through most
   apps that block synthetic paste. It is slower and does not undo in a single ⌘Z.

See [Advanced Configuration](reference/advanced_configuration.md) for where these go.

### `copied`

KeyScribe deliberately did not insert, and put the text on your clipboard instead. Paste it where
you want it. This happens when the app or window you started dictating into is no longer the one in
front, when the target could not be identified, when Accessibility is not granted, or when the field
is a password field.

The history record does not currently say which of those it was. To see the reason, watch the log
while you reproduce it:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.keyscribe.app" && category == "insertion"'
```

### `local_fallback`

The AI rewrite did not complete, so your local transcript was kept. The `fallback:` line beneath the
row gives the reason. Note that this outcome replaces `inserted`/`copied`, so it does not tell you
how the text was delivered — if the text also never appeared, treat it as the `inserted` case above.

### No row at all

Two cases produce a dictation with no history record. If the focused field was a password field,
delivery is diverted to the clipboard and nothing is written to history by design. Otherwise, check
whether history is switched off, or whether the mode has `exclude_from_history` set — the
`--diagnose` output says which.

## Nothing happens when I press the trigger

Check the `Permissions` section of the `--diagnose` output first. Accessibility must be granted for
any trigger to work, and macOS caches permission state for the life of a running process, so a grant
made while KeyScribe was running does not take effect until you quit and relaunch it.

If Accessibility is granted and a modifier-only trigger (Fn, right-Option, right-Command) still does
nothing, check whether you are pressing it as part of a chord. Holding the trigger together with
another key is treated as your own keyboard shortcut and deliberately does not start a dictation.

## The speech model will not load

The `Model load failures` section of the `--diagnose` output lists recent failures with the model and
the error. A `timeout` entry usually means the first cold load was slow rather than broken — try
again. Repeated failures for one model are worth reporting with that section included.

## Reporting a problem

Include the `--diagnose` output, what you expected, and what happened instead. If the problem is
about text not appearing, say which app you were dictating into — the answer often depends on how
that app handles paste.
