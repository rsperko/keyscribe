# Privacy in KeyScribe

KeyScribe is built local-first. This document describes precisely what stays on your Mac, what can
optionally leave it, and the limits of those guarantees. It describes how the software behaves; it is
not a legal privacy policy.

## Summary

| Data | Where it goes |
| --- | --- |
| Audio from the microphone | Transcribed on your Mac. Never uploaded by KeyScribe. |
| Plain Dictation text | Processed and inserted on your Mac. No provider request. |
| Optional rewrite text | Sent only to the provider or endpoint configured for that mode. |
| Clipboard text inserted by voice | Tokenized before rewrite and restored locally; not sent as clipboard text. |
| History | Local JSONL files under `~/Library/Application Support/KeyScribe/`. |
| Saved API keys | macOS Keychain. The config stores only a key reference. |
| Command-generated bearer tokens | Memory only, with expiry honored when present. |
| Speech model weights | Downloaded on demand, cached locally, and reused offline. |

## What never leaves your Mac

- **Speech recognition is always on-device.** There is no cloud speech-to-text in KeyScribe, and
  there is no setting that enables one. Your audio is transcribed locally by an engine running on
  your machine.
- **No telemetry, no analytics, no crash reporting.** KeyScribe does not collect or transmit speech,
  transcripts, usage data, or diagnostics. There is no account and no sign-in.
- **History stays local.** Past dictations are stored as plain JSONL files under
  `~/Library/Application Support/KeyScribe/` and are never uploaded. History is on by default and
  keeps a limited number of days, which you can change or turn off in Settings. The history folder is
  excluded from Time Machine backups.
- **Your saved API keys stay in the Keychain.** BYOK provider keys are stored in the macOS
  Keychain. The on-disk config holds only a reference to a key, never the key material itself.
- **Command-generated tokens are not persisted.** OpenAI-compatible endpoints can use a command that
  prints a bearer token. KeyScribe keeps generated tokens in memory only, honoring reported expiry
  when present.

## The only thing KeyScribe itself sends

The only path on which KeyScribe itself sends your words off your Mac is an **optional,
bring-your-own-key (BYOK) LLM cleanup** that rewrites a transcript (removing filler, fixing grammar,
reformatting). It is off unless you configure a provider and enable it for a mode. A script or
shortcut you set up to run by voice can send what you said wherever it is built to; see
[Programs and shortcuts you run by voice](#programs-and-shortcuts-you-run-by-voice).

When it runs:

- The request goes to **the provider and endpoint you configured**, authenticated using the
  credential method you selected: a Keychain-backed API key, no auth for local/no-auth endpoints, or
  a command-generated bearer token. KeyScribe has no LLM service of its own.
- Before the request is sent, recognizable sensitive spans may be **tokenized out** of the
  transcript (the redaction wedge, below) and restored locally in the response.
- Turn the cleanup off and KeyScribe itself makes no network calls after the initial one-time model
  downloads, apart from the update check below.

## Network use, in full

KeyScribe only reaches the network for these things, and never to send your audio:

1. **Downloading speech models** — on-device engine weights are fetched on demand from their
   publishers (e.g. Hugging Face) the first time you select an engine, then cached locally and reused
   offline. A tiny (~1 MB) voice-activity-detection model is fetched the same way, alongside your first
   speech model; it runs entirely on-device to detect whether a recording contains any speech (so a
   silent trigger inserts nothing) and never sends audio anywhere.
2. **Your own AI service**, if you set one up — the optional LLM cleanup described above, plus the
   connection test and model list when you add or edit a connection. All of it goes to the provider
   you configured and nowhere else. While you are recording a mode that uses it, KeyScribe may also
   open the connection ahead of time so the cleanup comes back faster; that request carries no
   content, and it is skipped entirely when you are typing in a password field.
3. **Checking for app updates** — KeyScribe periodically fetches a small update feed to see whether a
   newer version is available, and downloads it only if you choose to install one. It asks before the
   first automatic check and you can turn it off. It carries no speech, transcript, or usage data —
   only the metadata any HTTP request unavoidably reveals (your IP address and the app/OS version); the
   updater's optional anonymous system profiling is left disabled. Updates are cryptographically
   verified before they run.

There is no background phone-home or license check.

## Programs and shortcuts you run by voice

With the experimental voice commands you can name a script or a macOS shortcut that KeyScribe runs
when you say its name (optionally after **run**), and pass it the words you say after the name. It runs
whenever what you say starts with one of its names, including a mishearing of something else and a
name that sounds like switching apps, such as "open notes". Saying "switch to" or "open" with
anything that is not one of its names never runs one. KeyScribe starts a script on your Mac and hands it those words
as an argument, or runs a shortcut and hands them over as its input; it does not send them anywhere
itself. What the script or shortcut does with them is up to what you chose: a shortcut can send
messages, change files, or send its input to online services, depending on its steps. Both run as you, with
everything your account can do, and a misheard command can run them, so choose what you connect this
way with care.

Every Run a Script and Run a Shortcut sheet explains these consequences before saving, each in its own
words, and every Open an App or Link and Find a Browser Tab sheet explains that it can bring an app's
windows forward. Separately,
a notice before first enabling Voice Commands explains that an unintended app's windows can become
visible and receive your next keystrokes.

To find a window you name, Voice Commands reads the titles of your open windows on this Mac, only when
no app or place matched what you said. The titles are not sent anywhere or written to diagnostic logs.

A Find in an App's Sidebar command (an experimental feature, off unless you turn it on) reads the names listed in that app's sidebar, such as channels, people,
or mailboxes, only when you say it or press Check Sidebar while editing it. The names are not sent anywhere or written to diagnostic logs. For some
apps, such as Slack, reading the sidebar first turns on the app's own accessibility support, which stays on
until that app quits.

When history is on, each voice command is saved there like a dictation: what you said, the command it
ran with those words (for a window, its title and app, and the titles in a list it offered you), and, if it failed, the error message, which can include the last line the script
or shortcut wrote to its error output. An action still running when it is saved is updated with its
final result when it finishes. Turning history off stops this along with everything else; to keep only voice
commands out, turn on **Do not save this mode in history** in the Voice Commands settings.

## The redaction wedge — and its limits

When LLM cleanup is enabled, KeyScribe attempts to keep recognizable sensitive spans out of the
request: matching spans are replaced with nonce tokens *before* the transcript is sent, and the
original text is substituted back in locally *after* the response returns. The mapping from token to
original lives in memory only — it is **never logged and never written to history**. A validation gate
checks that every token sent to the model comes back exactly once, rejects stray token-looking text,
and rejects empty responses before the result is used; on failure KeyScribe retries once more
strictly, then falls back to the local transcript with a HUD notice.

**This is best-effort redaction, not a security guarantee.** It reduces what a third-party model
sees when a span is recognized, but it cannot promise that every sensitive span is caught. It works
on the text produced by speech recognition, so it can miss content the recognizer verbalizes or
normalizes, such as an email address transcribed as words. Treat it as a safety margin, not a
boundary you can rely on for regulated or high-stakes data. If something must never reach a
third-party provider, use Plain Dictation or another mode with LLM cleanup off.

## Privacy mode and context are mutually exclusive

Some modes can attach context to the LLM request to improve the rewrite. When a mode's **privacy
toggle** is on, those context options are forced off and locked: the transcript, after best-effort
recognizable-span redaction, is the only user content that can leave the machine for that mode.

## Where your data lives

Everything KeyScribe persists is a plain file under `~/Library/Application Support/KeyScribe/`:

- **Config** (modes, connections, dictionary, replacements) as TOML.
- **History** as JSONL, one file per day. Each entry holds what you said and what was inserted, and,
  for a mode that uses an AI service, the request sent to it. That request can include text from other
  apps: the text you selected for a rewrite mode, and whatever context the mode attaches, such as text
  before the cursor. It is plain text, readable by anything running as you.
- **Replacement use counts** under `usage/`: for each of your replacements, how many dictations it
  changed and the day it was last used. No dictation text is stored there, and it is kept whether or
  not History is on.
- **Downloaded speech model weights** under `models/`.

You can inspect, back up, or delete any of it with the Finder or a text editor. Deleting the history
files removes that history; removing the application support folder resets KeyScribe.

While you dictate, the recording is written to a temporary file and deleted once it is transcribed. If
KeyScribe quits in the middle of a dictation, it deletes the leftover recording the next time it starts,
or within a few minutes of starting for a recording left by an older version.
**Erase All KeyScribe Data** in Settings removes everything described here except downloaded speech
models, including retained and leftover recordings, and also deletes saved API keys from the Keychain.
One exception: a leftover recording made in the last few minutes by an older version of KeyScribe could
still be in use by that version, so it is kept, and the next start deletes it.

## What KeyScribe trusts

KeyScribe treats its own settings folder as yours. Anything that can change the files in it can change
what KeyScribe runs on your behalf:

- **A connection's token command** runs through your login shell, as you, each time a token is needed.
- **Voice commands** run the script or shortcut a command names, with the words you said.

So protect that folder as you would your shell profile.

A voice command acts on whatever the microphone hears while you are recording, not only your own voice.
Anyone audible during a dictation, especially one you have left running, can supply the words a script
receives. Keep that in mind before connecting a script that sends messages, changes files, or calls
online services.

## Open source

KeyScribe is GPLv3 and the full source is public, so these claims are auditable end to end rather
than taken on trust.
