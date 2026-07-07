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
  `~/Library/Application Support/KeyScribe/` and are never uploaded.
- **Your saved API keys stay in the Keychain.** BYOK provider keys are stored in the macOS
  Keychain. The on-disk config holds only a reference to a key, never the key material itself.
- **Command-generated tokens are not persisted.** OpenAI-compatible endpoints can use a command that
  prints a bearer token. KeyScribe keeps generated tokens in memory only, honoring reported expiry
  when present.

## The only thing that can leave your Mac

The single outbound network path is an **optional, bring-your-own-key (BYOK) LLM cleanup** that
rewrites a transcript (removing filler, fixing grammar, reformatting). It is off unless you configure
a provider and enable it for a mode.

When it runs:

- The request goes to **the provider and endpoint you configured**, authenticated using the
  credential method you selected: a Keychain-backed API key, no auth for local/no-auth endpoints, or
  a command-generated bearer token. KeyScribe has no LLM service of its own.
- Before the request is sent, recognizable sensitive spans may be **tokenized out** of the
  transcript (the redaction wedge, below) and restored locally in the response.
- Turn the cleanup off and KeyScribe makes no network calls at all after the initial one-time model
  downloads.

## Network use, in full

KeyScribe touches the network in exactly three situations:

1. **Downloading speech models** — on-device engine weights are fetched on demand from their
   publishers (e.g. Hugging Face) the first time you select an engine, then cached locally and reused
   offline.
2. **The optional BYOK LLM cleanup** — described above, to your own provider.
3. **Checking for app updates** — KeyScribe periodically fetches a small update feed to see whether a
   newer version is available, and downloads it only if you choose to install one. It asks before the
   first automatic check and you can turn it off. It carries no speech, transcript, or usage data —
   only the metadata any HTTP request unavoidably reveals (your IP address and the app/OS version); the
   updater's optional anonymous system profiling is left disabled. Updates are cryptographically
   verified before they run.

There is no background phone-home or license check.

## The redaction wedge — and its limits

When LLM cleanup is enabled, KeyScribe attempts to keep recognizable sensitive spans out of the
request: matching spans are replaced with nonce tokens *before* the transcript is sent, and the
original text is substituted back in locally *after* the response returns. The mapping from token to
original lives in memory only — it is **never logged and never written to history**. A validation gate
checks that every issued token comes back exactly once before the result is used; on failure
KeyScribe retries once more strictly, then falls back to the local transcript with a HUD notice.

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
- **History** as JSONL, one file per day.
- **Downloaded speech model weights** under `models/`.

You can inspect, back up, or delete any of it with the Finder or a text editor. Deleting the history
files removes that history; removing the application support folder resets KeyScribe.

## Open source

KeyScribe is GPLv3 and the full source is public, so these claims are auditable end to end rather
than taken on trust.
