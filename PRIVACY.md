# Privacy in KeyScribe

KeyScribe is built local-first. This document describes precisely what stays on your Mac, what can
optionally leave it, and the limits of those guarantees. It describes how the software behaves; it is
not a legal privacy policy.

## What never leaves your Mac

- **Speech recognition is always on-device.** There is no cloud speech-to-text in KeyScribe, and
  there is no setting that enables one. Your audio is transcribed locally by an engine running on
  your machine.
- **No telemetry, no analytics, no crash reporting.** KeyScribe does not collect or transmit speech,
  transcripts, usage data, or diagnostics. There is no account and no sign-in.
- **History stays local.** Past dictations are stored as plain JSONL files under
  `~/Library/Application Support/KeyScribe/` and are never uploaded.
- **Your API keys stay in the Keychain.** BYOK provider keys are stored in the macOS Keychain. The
  on-disk config holds only a reference to a key, never the key material itself.

## The only thing that can leave your Mac

The single outbound network path is an **optional, bring-your-own-key (BYOK) LLM cleanup** that
rewrites a transcript (removing filler, fixing grammar, reformatting). It is off unless you configure
a provider and enable it for a mode.

When it runs:

- The request goes to **the provider and endpoint you configured**, authenticated with **your** key.
  KeyScribe has no LLM service of its own.
- Before the request is sent, sensitive spans are **tokenized out** of the transcript (the redaction
  wedge, below) and restored locally in the response.
- Turn the cleanup off and KeyScribe makes no network calls at all after the initial one-time model
  downloads.

## Network use, in full

KeyScribe touches the network in exactly two situations:

1. **Downloading speech models** — on-device engine weights are fetched on demand from their
   publishers (e.g. Hugging Face) the first time you select an engine, then cached locally and reused
   offline.
2. **The optional BYOK LLM cleanup** — described above, to your own provider.

There is no background phone-home, update ping (in-app updates are a planned, opt-in feature), or
license check.

## The redaction wedge — and its limits

When LLM cleanup is enabled, KeyScribe attempts to keep sensitive spans out of the request: matching
spans are replaced with nonce tokens *before* the transcript is sent, and the original text is
substituted back in locally *after* the response returns. The mapping from token to original lives in
memory only — it is **never logged and never written to history**. A validation gate checks that
every issued token comes back exactly once before the result is used; on failure KeyScribe retries
once more strictly, then falls back to the local transcript with a HUD notice.

**This is best-effort redaction, not a security guarantee.** It reduces what a third-party model
sees; it cannot promise that every sensitive span is caught. Treat it as a safety margin, not a
boundary you can rely on for regulated or high-stakes data. If something must never reach a
third-party provider, use **privacy mode** or simply leave LLM cleanup off.

## Privacy mode and context are mutually exclusive

Some modes can attach context (such as a browser URL or selected text) to the LLM request to improve
the rewrite. When a mode's **privacy toggle** is on, those context options are forced off and locked:
the redacted transcript is the only user content that can leave the machine for that mode.

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
