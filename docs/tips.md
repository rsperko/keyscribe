# Tips & Tricks

Small techniques that are easy to miss. This is not a linear guide — that's
[Getting Started](getting_started.md) — and it's not troubleshooting — that's [FAQ.md](../FAQ.md).
Skim for the one that fits, and come back as you grow your setup.

## Make a word or command come out exactly right

A **Dictionary** entry and a **Replacement** do different jobs, and the difference trips people up:

- **Dictionary** improves how reliably a word is *heard*. It tells the recognizer "this is a real
  word, not a misspelling." It does **not** control how the word is *written* — capitalization,
  punctuation, and spacing still come from transcription and any AI rewrite.
- **Replacement** controls the *output*. It swaps recognized text for exactly what you specify,
  verbatim.

So a dictionary entry alone won't pin down an exact spelling. If you add `pi` to your dictionary and
say it by itself, you might get `Pi.` — heard correctly, but capitalized and punctuated like a
sentence.

When you need a word to appear **exactly** as written — a command you'll paste into a terminal, a
lowercased tool name, a symbol — add a **Replacement** with the same text on both sides (for example
`pi` → `pi`). Keep the dictionary entry too if the word is also easy to mishear: the dictionary helps
KeyScribe *hear* it, the replacement makes sure it's *written* the way you want. Think of it as
dictionary for the ears, replacement for the mouth.

**Bonus:** when everything you dictate is a single whole-utterance replacement, it's inserted exactly
as written — no added capitalization, no trailing period, and it skips the AI rewrite entirely. That's
what makes `slash resume` → `/resume` land as a clean `/resume` you can paste straight into a shell.

## Inject a secret or URL mid-dictation without it reaching the AI

Say `insert clipboard contents` while dictating to drop whatever you've copied into the text at that
point. Two guarantees make this useful for sensitive material:

- **It never goes to the AI.** Even in a mode with rewrite on, the pasted text is not sent anywhere
  and is not rewritten — the model only ever sees a placeholder token. So a copied password, API
  token, or private URL stays on your machine.
- **It's inserted exactly as copied**, character for character, no cleanup.

Handy when you want a polished, rewritten sentence *around* a value that must stay untouched.

## Keep words literal when they sound like commands

If the words you want to dictate sound like edit commands — "new line," "scratch that" — wrap them in
a verbatim span so they stay literal:

```text
begin verbatim insert new line scratch that end verbatim
```

That inserts the words `insert new line scratch that` instead of acting on them. A verbatim span is
also protected from the AI rewrite, so it survives exactly as spoken.

If KeyScribe misses the closing "end verbatim," it protects the rest of the utterance as literal
text and leaves "begin verbatim" visible so you can spot the miss. One ⌘Z removes the whole
dictation; undo and say it again.

## Fix a mishearing without leaving what you're doing

When KeyScribe gets a word wrong, you don't have to open Settings. Use the **Add to Vocabulary**
shortcut (assign one in Settings ▸ General) to add a dictionary entry or replacement in the moment —
the fix sticks for next time. You can also select the misheard words in **History** and turn them into
a replacement or dictionary entry after the fact.

## Get the last result back when focus jumped

If focus changes mid-dictation, KeyScribe copies the result to the clipboard instead of pasting it
into the wrong app — so nothing is lost. To reinsert the most recent result on demand, use the menu
bar **Paste Last Dictation** command (or give it a shortcut in Settings ▸ General).
