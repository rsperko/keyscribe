# Release testing — the pre-ship gate

Run this before every release. One entry point: **`make preflight`** (→ `scripts/preflight.sh`).
It runs everything that can be automated, walks the human smoke checks, and — only if the whole
thing is green — writes a commit-keyed stamp. **`scripts/publish.sh` refuses to publish without a
matching stamp**, so a broken build cannot go public by forgetting a step.

## Quickstart — running it

```
# 1. Build the notarized release artifact (Tier A inspects KeyScribe.app + the DMG).
./release.sh patch|minor|major            # or a bare ./release.sh to rebuild the current tag

# 2. Run the gate. Automated tiers run unattended; then it walks you through ~2 dictations.
make preflight

# 3. If it passed (stamp written), publish. Refuses without a matching stamp.
make publish
```

**Prerequisites the gate needs (it tells you loudly when one is missing — it never silently passes):**
- **The release artifact is built** — `KeyScribe.app` + `KeyScribe-<ver>.dmg` at the repo root (step 1).
- **The STT engines you ship are installed** — Tier B only tests *installed* engines and reports the
  shipped ones that are missing (so they are untested). Install them in the app (Settings ▸ Speech
  Models) before a real release, or set `KEYSCRIBE_REQUIRE_ALL_ENGINES=1` to make a gap a hard failure.
  Check what you have with `KeyScribe.app/Contents/MacOS/KeyScribe --list-engines`.
- **The corpus is recorded** — `corpus/commands/` and `corpus/stt/` (your own voice, gitignored; record
  with `bash corpus/record.sh [--commands]`). Missing corpus ⇒ that check SKIPs, loudly.
- **A quiet room + your mic** for Tier B (real transcription) and Tier C (real dictation).

**Which models do the tests use?** None are pinned — the tests run across *whatever you have installed*,
which is deliberate: a release should verify the exact engines you ship. The only engine named
specifically is **Qwen3-ASR**, in the Tier C spot-check that proves `mlx.metallib` runs under the
hardened runtime. The `--list-engines` coverage line at the top of Tier B is your record of what was
actually exercised.

Modes: `make preflight` targets the release artifact and writes the publish stamp.
`scripts/preflight.sh --dev` targets `KeyScribeDev.app` (skips notarization checks, no stamp) for
day-to-day sanity; `--auto` runs the automated tiers only, non-interactive, for CI.

## Resumable — re-run one check, not the whole gate

Every check has a stable id (`scripts/preflight.sh --list-checks`) and its result is recorded in a
per-commit ledger under `.preflight-state/<commit>/`. A re-run **skips any check already green for this
commit + artifact**, so fixing one thing never means redoing `swift test` and the benchmark to get back
to Tier C. A cached green is reused only while its input signature still matches — source for
`swift test`, the built artifact for Tier A/C, the corpus + installed-engine set for Tier B — so a
rebuild or a corpus change re-runs the affected checks instead of trusting a stale pass.

- **Re-run just the failures:** `--only <id[,id]>` runs a subset; `--force [id[,id]]` ignores the cache
  (all checks, or the listed ones). The stamp is still only written once **every** required check is
  green for the commit — a partial `--only` run reports what is still outstanding and writes no stamp.
- **A failed check is retryable in place.** On a failure the interactive run offers **`[r]etry`**
  (re-run that one check — the fix for a flaky human check, e.g. re-dictating the redaction phrase so it
  is the latest history entry again) or **`[o]verride`** (mark it passed by hand, with a reason). An
  override is recorded truthfully in the stamp and the ledger — it does **not** masquerade as a real
  pass, and it is scoped to that one check, so every other gate still holds. This replaces reaching for
  the all-or-nothing `KEYSCRIBE_SKIP_PREFLIGHT=1`, which stays only as the last-resort full bypass.

## Why `swift test` being green is not enough

Releases have broken *immediately after shipping* while the dev build and `swift test` were both
green. That is not bad luck — it is structural. The unit + DI-seam suite runs against the **dev**
build (`KeyScribeDev.app`, self-signed, no hardened runtime). The failures that surface right after a
release live entirely in the **notarized production artifact** and are unreachable from a unit test:

| Release-only failure surface | Why a dev-build test can't see it |
|---|---|
| **TCC grants rebind to the code signature** | A re-signed release invalidates the `csreq`-bound Mic/Accessibility grant → the app silently can't hear or paste. Only the real signed app, relaunched, exercises this. |
| **Hardened runtime + entitlements** | `make-app.sh` omits them; only `release.sh` applies them. A missing/rejected entitlement only bites the notarized build. |
| **`mlx.metallib` bundled + signed** | Qwen3-ASR crashes at load ("Failed to load the default metallib") without it. It is assembled and signed only on the release path. |
| **Gatekeeper quarantine** | A fresh download carries `com.apple.quarantine`; first launch behaves differently than a locally-built app. |
| **First-run onboarding + model download** | Never touched by unit tests — needs a clean install. |
| **Trigger matrix** (modifier tap / Carbon chord / mouse tap) | Permission-gated OS event paths; can't be unit-tested. |

So the gate is **tiered**: cheap deterministic checks first, then functional checks that need models,
then a human driving the *real installed app* — because that last tier is the only thing that
actually catches the list above.

## The three tiers

### Tier A — build / packaging gates (automated, no mic, always runs, hard gate)

- `swift test` — full suite green.
- Artifact present, and `codesign --verify --deep --strict` passes (nested metallib/xcframeworks too).
- **`mlx.metallib` present** beside the executable (the silent Qwen killer).
- `Info.plist` stamped: real `CFBundleShortVersionString` / `CFBundleVersion` / bundle id (no `__PLACEHOLDER__`).
- Release only: Gatekeeper accepts it as **Notarized Developer ID**, ticket **stapled** (app + DMG),
  hardened-runtime **entitlements present**.

### Tier B — functional gates (automated; needs models + a quiet room; hard gate where it can run)

- **`--commands-check corpus/commands --baseline corpus/commands/baseline.json`** — every spoken
  command (scratch that, verbatim, insert newline/paragraph/tab, insert clipboard, whole-utterance
  replacements) still behaves on the real transcripts each installed engine produces. The clips are
  transcription-sensitive, so **no absolute pass-rate is meaningful** — a weak engine that mishears
  "scratch that" fails a clip on its WER, not a bug (empirically parakeet-110m ~80%, whisper-small
  ~69%, and they fail *different* clips). So the gate is a **per-engine regression check against a
  known-good baseline**: the first run establishes `baseline.json` (gitignored — the wavs are your
  own voice); later runs exit non-zero only when an engine cleans **fewer** clips than its baseline (a
  command-pipeline regression) or the clip count changed (re-baseline: delete the file, re-run). A
  newly-installed engine is added, not treated as a regression.
- **`--benchmark corpus/stt`** — biased WER stays under a **coarse** ceiling (`KEYSCRIBE_MAX_WER`,
  default 0.20). This is a *catastrophic-regression* backstop (bias wiring broke → WER doubles), not a
  rank check — the default is set so no shipped engine false-fails (Moonshine ships ~15% with no
  recognition bias). The commands-check baseline is the precise gate; this is the cheap safety net.
- **`--capture-probe`** — opt-in (`KEYSCRIBE_CAPTURE_PROBE=1`, needs a loopback/Aggregate device
  feeding a steady tone): `ringDropped` and `overloads` must both be 0. Run it whenever the audio
  path changed.

Where a corpus or the hardware is absent, Tier B prints a loud **SKIP** — never a silent pass.

### Tier C — human smoke on the freshly-installed notarized app (interactive; must be signed off)

Kept deliberately **short so it actually gets run** — an arduous checklist gets skipped, which defeats
the point. The routine path is **two script-verified dictations (~3 min)**, each chosen because a
single natural action proves a whole cluster of release-only invariants:

1. **One plain dictation** on the notarized app, launched against the sandbox config dir
   (`open KeyScribe.app --args --config-dir .preflight-run --first-run`) so onboarding runs fresh
   without touching your real config. Onboard, grant Mic + Accessibility, then dictate. If any text
   lands at all, that one action already proved: notarized launch, onboarding + model download, **both
   TCC grants binding to the new signature**, capture, STT, the paste path, and your default trigger.
   The script auto-checks the clipboard-marker probe (catches the AX false-success data-loss path); you
   confirm the text appeared and a single ⌘Z removed all of it.
2. **One private cloud rewrite** in a privacy+cloud mode (dictate a phrase with an email + a verbatim
   span). The script auto-verifies from the stored history that the outbound prompt holds a redaction
   token and **not** the raw secret, and that the verbatim span was fenced — you don't eyeball it.

Then **spot-checks you run only for the subsystem you changed** (Enter past the rest): the trigger
matrix (modifier / chord / mouse) if you touched hotkey code, Qwen loading + the `--raw` silence guard
if you touched STT, edit-in-place if you touched insertion. A routine release with no subsystem change
is just the two dictations.

`scripts/verify-live.sh` remains the standalone companion — the same on-disk artifact checks plus the
Settings commit-on-blur check — for when you want to exercise these outside a release.

## Your daily configuration is never touched

The whole run is non-destructive by construction — after it, the app works exactly as before:

- **Tier A + B** never read or write app config. The `--commands-check` / `--benchmark` / `--capture-probe`
  CLI paths exit before the app loads any config, and preflight passes `--config-dir` on them anyway as
  insurance. Their only writes are to the repo (`corpus/*/results.json`, `baseline.json`) and the shared,
  read-only model cache.
- **Tier C** runs the notarized app against a **throwaway config dir** (`.preflight-run`, gitignored) via
  `--config-dir … --first-run` — onboarding, modes, and history all land there, never in
  `~/Library/Application Support/KeyScribe/`. The sandbox is deleted when preflight exits.
- **Shared but safe:** downloaded models (read-only, never redirected), and the Mic/Accessibility grants
  plus any BYOK key (bundle-id-scoped, so testing *adds* them — it never disturbs your config). Quit your
  running app before Tier C so the sandbox instance is the one running; reopen it after — back to normal.

The one exception is the **optional** "validate the real /Applications download" spot-check, which
deliberately replaces your installed copy to test the true quarantine launch — skip it (Tier A's `spctl`
already proves notarization) unless you want that end-to-end, and reinstall your normal copy afterward.

## Workflow

```
make preflight-pre                 # FAIL-FAST: swift test + Tier B on the dev build, BEFORE notarizing
./release.sh patch|minor|major     # build + notarize the app and DMG (background + poll; ~10–30 min)
make preflight                     # Tier A packaging + Tier C smoke (A/B from the pre-run are cached) → stamp
make publish                       # refuses unless .preflight-pass matches HEAD
# or, all of it chained (this exact order):
make ship patch|minor|major        # preflight-pre → release → preflight → publish
```

**Why `preflight-pre` runs first.** `swift test` and the Tier B functional gates need a *built* app but
not a *notarized* one — WER and command behavior are byte-identical dev vs release. So they run against a
fast `make-app.sh` dev bundle **before** `release.sh`, and a red test or a WER regression aborts the whole
thing without ever spending the 10–30 min Apple notarize round-trip. Their green results are cached in the
per-commit ledger, so the post-notarize `make preflight` reuses them and only runs Tier A's packaging /
notarization checks (which *need* the notarized artifact) plus the Tier C human smoke. Net work is the
same, reordered to fail fast. (Notarization checks are deliberately excluded from `--pre` — a dev bundle
can't pass them.)

Modes: `preflight.sh --dev` (target `KeyScribeDev.app`, skip notarization checks, no stamp — day-to-day
sanity) · `preflight.sh --auto` (Tier A + B only, non-interactive, no stamp — CI / quick regression) ·
`--only <ids>` / `--force [ids]` / `--list-checks` / `--reset` (per-check re-run, see "Resumable" above).

The stamp (`.preflight-pass`, gitignored) records the verified commit SHA on its first line (what
`publish.sh` matches) plus a per-check breakdown, incl. any hand overrides. Rebuilding or moving HEAD
invalidates it — re-run preflight (cached-green checks are skipped, so this is cheap). Per-check override
is preferred over the full-bypass `KEYSCRIBE_SKIP_PREFLIGHT=1 make publish` (which ships wholly
unverified — say so).
