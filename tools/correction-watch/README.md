# correction-watch

A standalone measurement tool. It answers one question: after you dictate, how often do you go back
and fix a word, and which words? The answer decides whether KeyScribe should learn dictionary
suggestions from your corrections.

It changes nothing. It reads the dictation history KeyScribe already writes, looks at the text field
you dictated into, and logs what you changed there in the next 30 seconds.

## What it does

For each new dictation in History that was inserted into an app:

1. Notes the frontmost app and reads its focused text field through Accessibility. Electron apps are
   asked to turn on their accessibility tree, the same request KeyScribe makes when it reads context.
2. Finds the dictated words in that field.
3. Re-reads the field every half second for the watch window, following the dictated words if
   text around them moves.
4. Stops early when the words disappear (the message was sent or the field cleared), and logs the
   last state it saw.
5. Logs a word-level comparison of what was inserted against that last state.

Password fields are skipped. Apps that expose no text (browsers, VS Code-family editors and some
Electron apps) are logged as `unreadable`, which is useful in itself: it shows how much dictation
goes where corrections can't be seen.

## Privacy

Each log record holds the dictated text, the matching words in the field, the final words, and the
changes. It never holds the rest of the field. Pass `--no-text` to keep only counts and the kind of
each change. Logs are plain files under `~/Library/Logs/correction-watch/`, one per day, readable
only by you. Nothing leaves the machine. Delete the folder to remove them.

## Use

Turn on History in KeyScribe's settings: the tool reads it.

```sh
tools/correction-watch/build.sh
tools/correction-watch/.build/correction-watch watch
```

Give the app you run it from (your terminal) Accessibility access when asked. It finds the newest
history folder under `~/Library/Application Support`, which covers renamed builds; pass
`--history-dir` to choose one. Leave it running in a terminal tab; ctrl-C stops it.

Options: `--window SECONDS` (default 30), `--log-dir DIR`, `--no-text`.

## Report

```sh
tools/correction-watch/.build/correction-watch report --days 7
```

Prints, per app, how many dictations were readable and how many were changed, then the replaced
words (what was heard and what you changed it to) with counts. A replacement that repeats is a
dictionary or replacement candidate. Rewording, added words and deleted words are logged too, so the
report also shows how much editing is not a mishearing at all.

## Limits

- Text typed after the dictation is ignored; only the dictated words are compared.
- A fix made by retyping the whole sentence shows up as a large change, not a word pair.
- In terminal apps the field is the whole visible screen, so a dictated phrase that also appears
  elsewhere on screen can be matched to the wrong place. The tool prefers the latest occurrence.
- A dictation that lands in an app other than the frontmost one is not followed.
