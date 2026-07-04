#!/usr/bin/env bash
#
# preflight.sh — the release gate. Runs every check that CAN be automated against the artifact you
# are about to ship, then walks the human smoke checks that only a person driving the real app can
# confirm, and — only if the whole thing passes — writes a stamp keyed to the current commit that
# scripts/publish.sh refuses to publish without.
#
# The reason this exists: `swift test` is green on the DEV build, but releases break on the things
# that ONLY exist in the notarized production artifact — TCC grants rebinding to the new signature,
# hardened-runtime entitlements, the bundled+signed mlx.metallib (Qwen crashes without it), Gatekeeper
# quarantine on a fresh download, first-run onboarding, and the permission-gated trigger matrix. None
# of that is reachable from a unit test. See docs/development/release_testing.md for the full rationale.
#
# Tiers:
#   A  Build / packaging gates   — automated, no mic. Hard gate. Always runs.
#   B  Functional gates          — automated, needs models + a quiet room. Hard gate where it can run;
#                                   loudly SKIPPED (never silently passed) where the corpus/hardware is absent.
#   C  Human smoke on the real    — interactive checklist against the freshly-installed notarized app.
#      installed app                Must be signed off for the stamp to be written.
#
# Usage:
#   ./scripts/preflight.sh              full run against the RELEASE artifact (KeyScribe.app), writes the stamp
#   ./scripts/preflight.sh --dev        target KeyScribeDev.app; skip notarization checks; NO stamp (dev sanity)
#   ./scripts/preflight.sh --auto       Tier A + B only, non-interactive, NO stamp (CI / quick regression)
#
# Env:
#   KEYSCRIBE_MAX_WER=0.20   coarse biased-WER ceiling for the STT benchmark gate (default 0.20).
#                            Set to catch a CATASTROPHIC regression (bias wiring broke → WER doubles),
#                            not to rank engines — Moonshine ships ~15% (no recognition bias) and must
#                            not false-fail. Tune to your installed engine set.
#   KEYSCRIBE_CAPTURE_PROBE=1  run the capture-probe (needs a loopback/Aggregate device feeding a tone)

set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

MODE="release"
for a in "$@"; do
  case "$a" in
    --dev)  MODE="dev" ;;
    --auto) MODE="auto" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

MAX_WER="${KEYSCRIBE_MAX_WER:-0.20}"
STAMP="$REPO_ROOT/.preflight-pass"

case "$MODE" in
  dev) APP="KeyScribeDev.app"; APP_BIN="MacOS/KeyScribe" ;;
  *)   APP="KeyScribe.app";    APP_BIN="MacOS/KeyScribe" ;;
esac
APP_PATH="$REPO_ROOT/$APP"
EXE="$APP_PATH/Contents/$APP_BIN"

# Everything runs against a THROWAWAY config dir, never your real ~/Library/Application Support/KeyScribe.
# `--config-dir` redirects config/modes/history/onboarding here; downloaded models stay shared and are
# never redirected (KeyScribePaths). So the app's own help: "test onboarding without touching your real
# configuration." Removed on exit — a passing or failing run leaves your daily config untouched.
PF_CFG="$REPO_ROOT/.preflight-run"
HIST="$PF_CFG/history"
latest_history() { ls -t "$HIST"/*.jsonl 2>/dev/null | head -1; }
rm -rf "$PF_CFG"; mkdir -p "$PF_CFG"
trap 'rm -rf "$PF_CFG" 2>/dev/null' EXIT

# ── output helpers + tally ────────────────────────────────────────────────────────────────────────
FAILED=0; SKIPPED=0; PASSED=0
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
section() { printf '\n'; bold "══ $1 ══"; }
pass() { PASSED=$((PASSED+1)); printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; }
fail() { FAILED=$((FAILED+1)); printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '  \033[33m∅ SKIP\033[0m  %s\n' "$1"; }
info() { printf '         %s\n' "$1"; }
ask()  { printf '\033[36m  ? %s\033[0m [y/N] ' "$1"; read -r REPLY; [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; }
act()  { printf '\033[36m  ▸ %s\033[0m\n         (press Enter when done) ' "$1"; read -r _; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Tier A — build / packaging gates"

# A0. unit + DI-seam suite
if timeout --foreground 900 swift test >/tmp/preflight-swifttest.log 2>&1; then
  pass "swift test — full suite green"
else
  fail "swift test — see /tmp/preflight-swifttest.log"; tail -20 /tmp/preflight-swifttest.log
fi

# A1. the artifact exists
if [ -d "$APP_PATH" ]; then
  pass "artifact present: $APP"
else
  fail "artifact missing: $APP — build it first (${MODE:+dev: ./make-app.sh, }release: ./release.sh)"
fi

if [ -d "$APP_PATH" ]; then
  # A2. codesign integrity (nested code — metallib, xcframeworks — is checked by --deep)
  if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/tmp/preflight-codesign.log 2>&1; then
    pass "codesign --verify --deep --strict"
  else
    fail "codesign verify — see /tmp/preflight-codesign.log"; tail -10 /tmp/preflight-codesign.log
  fi

  # A3. mlx.metallib bundled beside the executable (its absence silently crashes Qwen3-ASR at load)
  if [ -f "$APP_PATH/Contents/MacOS/mlx.metallib" ]; then
    pass "mlx.metallib present beside the executable"
  else
    fail "mlx.metallib MISSING — Qwen3-ASR will crash at load ('Failed to load the default metallib')"
  fi

  # A4. Info.plist stamped (version / build / bundle id all present and non-placeholder)
  PL="$APP_PATH/Contents/Info.plist"
  SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL" 2>/dev/null || echo "")
  BUILDN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL" 2>/dev/null || echo "")
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PL" 2>/dev/null || echo "")
  if [ -n "$SHORT" ] && [ -n "$BUILDN" ] && [ "$BID" != "" ] && [[ "$BID" != *"__"* ]]; then
    pass "Info.plist stamped: $BID v$SHORT ($BUILDN)"
  else
    fail "Info.plist not fully stamped (version='$SHORT' build='$BUILDN' id='$BID')"
  fi

  if [ "$MODE" = "dev" ]; then
    skip "notarization / hardened-runtime / Gatekeeper — dev build is self-signed (checked only on release)"
  else
    # A5. Gatekeeper accepts it as a notarized Developer ID app, and the ticket is stapled
    if spctl -a -t exec -vv "$APP_PATH" 2>&1 | grep -q "source=Notarized Developer ID"; then
      pass "Gatekeeper: accepted as Notarized Developer ID"
    else
      fail "Gatekeeper does NOT accept $APP as notarized — a fresh download would be blocked"
    fi
    if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
      pass "notarization ticket stapled to the app"
    else
      fail "no stapled ticket — offline first-launch would fail Gatekeeper"
    fi
    # A6. hardened runtime + entitlements present (required for notarization to hold)
    if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "com.apple.security"; then
      pass "hardened-runtime entitlements present"
    else
      fail "no entitlements on the signed app — hardened runtime not applied"
    fi

    # A7. the stapled DMG that publish.sh will actually upload
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    DMG="$REPO_ROOT/KeyScribe-$VERSION.dmg"
    if [ -n "$VERSION" ] && [ -f "$DMG" ]; then
      if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
        pass "release DMG present + ticket validated: KeyScribe-$VERSION.dmg"
      else
        fail "KeyScribe-$VERSION.dmg is not stapled/validated"
      fi
    else
      fail "release DMG KeyScribe-$VERSION.dmg not built — run ./release.sh"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Tier B — functional gates (automated; needs models + a quiet room)"

# Engine coverage — Tier B tests only INSTALLED engines. Surface the shipped ones you have NOT
# installed, so an untested engine (that could ship a regression) is a visible SKIP, never silent.
COV="$("$EXE" --config-dir "$PF_CFG" --list-engines 2>/dev/null)"
TESTED="$(printf '%s\n' "$COV" | awk -F'\t' '$2!="missing"{print $1}' | paste -sd, -)"
MISSING="$(printf '%s\n' "$COV" | awk -F'\t' '$2=="missing"{print $1}' | paste -sd, -)"
info "engine coverage — will test: ${TESTED:-<none installed>}"
if [ -n "$MISSING" ]; then
  if [ "${KEYSCRIBE_REQUIRE_ALL_ENGINES:-0}" = "1" ]; then
    fail "shipped engines NOT installed (untested): $MISSING — install them (Settings ▸ Speech Models), or unset KEYSCRIBE_REQUIRE_ALL_ENGINES"
  else
    skip "shipped engines NOT installed, so UNTESTED: $MISSING — install to cover them (or KEYSCRIBE_REQUIRE_ALL_ENGINES=1 to require full coverage)"
  fi
fi

# B1. spoken-command regression across every installed engine, gated against a per-engine known-good
#     baseline (established on first run). A drop = a command-pipeline regression; weak-engine WER
#     noise is not, because the bar is "this engine's own last-good clip count".
CMD_BASELINE="$REPO_ROOT/corpus/commands/baseline.json"
if [ -f "$REPO_ROOT/corpus/commands/manifest.json" ]; then
  if timeout --foreground 1200 "$EXE" --config-dir "$PF_CFG" --commands-check "$REPO_ROOT/corpus/commands" --baseline "$CMD_BASELINE" >/tmp/preflight-commands.log 2>&1; then
    if grep -q "BASELINE ESTABLISHED" /tmp/preflight-commands.log; then
      skip "--commands-check: baseline just established — re-run preflight to gate against it"
      grep "BASELINE ESTABLISHED" /tmp/preflight-commands.log | sed 's/^/         /'
    else
      pass "--commands-check: every engine held its baseline"
    fi
  else
    fail "--commands-check regressed vs baseline — see /tmp/preflight-commands.log"
    grep -E "^FAIL" /tmp/preflight-commands.log | sed 's/^/         /' | head -20
  fi
else
  skip "--commands-check: corpus/commands not present (record it: bash corpus/record.sh --commands)"
fi

# B2. STT benchmark WER ceiling — a gross regression (bias broke, model swapped) fails the gate
if [ -f "$REPO_ROOT/corpus/stt/manifest.json" ]; then
  if timeout --foreground 2400 "$EXE" --config-dir "$PF_CFG" --benchmark "$REPO_ROOT/corpus/stt" >/tmp/preflight-bench.log 2>&1; then
    RES="$REPO_ROOT/corpus/stt/results.json"
    if [ -f "$RES" ]; then
      WORST=$(python3 - "$RES" "$MAX_WER" <<'PY'
import json, sys
res = json.load(open(sys.argv[1])); ceil = float(sys.argv[2])
bad = [(k, v.get("werBiased", 0)) for k, v in res.items() if v.get("werBiased", 0) > ceil]
print("\n".join(f"{k}={w:.3f}" for k, w in sorted(bad, key=lambda x: -x[1])))
PY
)
      if [ -z "$WORST" ]; then
        pass "--benchmark: all engines under the ${MAX_WER} biased-WER ceiling"
      else
        fail "--benchmark: engines OVER the ${MAX_WER} ceiling — bias/model regression likely"
        printf '%s\n' "$WORST" | sed 's/^/         /'
      fi
    else
      skip "--benchmark ran but wrote no results.json"
    fi
  else
    fail "--benchmark errored — see /tmp/preflight-bench.log"; tail -10 /tmp/preflight-bench.log
  fi
else
  skip "--benchmark: corpus/stt not present"
fi

# B3. capture-path integrity — opt-in (needs a loopback/Aggregate device feeding a steady tone)
if [ "${KEYSCRIBE_CAPTURE_PROBE:-0}" = "1" ]; then
  if timeout --foreground 60 "$EXE" --config-dir "$PF_CFG" --capture-probe --seconds 5 >/tmp/preflight-capture.log 2>&1; then
    if grep -qE "ringDropped=0.*overloads=0|overloads=0.*ringDropped=0" /tmp/preflight-capture.log; then
      pass "--capture-probe: no ring drops, no CoreAudio overloads"
    else
      fail "--capture-probe: ring drops or overloads detected"; grep -E "ringDropped|overloads|SINAD|glitch" /tmp/preflight-capture.log | sed 's/^/         /'
    fi
  else
    fail "--capture-probe errored — see /tmp/preflight-capture.log"
  fi
else
  skip "--capture-probe: set KEYSCRIBE_CAPTURE_PROBE=1 with a loopback device to run (needed when the audio path changed)"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Tier C — human smoke on the REAL installed app. Kept deliberately SHORT: two script-verified
# dictations that each prove a whole cluster of release-only invariants, then spot-checks you run only
# for the subsystem you touched. Skipped in --auto (no human) and --dev (no notarized artifact).
if [ "$MODE" != "release" ]; then
  section "Tier C — SKIPPED ($MODE mode: no human sign-off, no stamp will be written)"
else
  section "Tier C — human smoke (routine: 2 dictations, ~3 min)"
  info "This runs against a THROWAWAY config dir — your real KeyScribe config, modes, and history are"
  info "untouched, and this sandbox is deleted when preflight exits. Shared (and safe): downloaded"
  info "models (read-only), and the Mic/Accessibility grants + any BYOK key (bundle-scoped, additive)."
  printf '\n'
  info "Setup — so the sandbox instance is the one running:"
  info "  1. Quit your normal KeyScribe if it is running (same bundle id, or macOS reuses it)."
  info "  2. Launch the just-built notarized app against the sandbox:"
  info "       open $APP_PATH --args --config-dir '$PF_CFG' --first-run"
  info "  3. Finish onboarding (a model downloads), grant Mic + Accessibility, relaunch if asked."
  info "If it launched clean and onboarding completed, Gatekeeper + notarization already passed."
  info "When done, quit the sandbox instance and reopen your normal app — back to normal."
  act "Sandbox app is launched, onboarded, and permissions granted"

  # Routine 1 — one plain dictation. If text lands at all, the fresh signature's Mic + Accessibility
  # grants BOTH bound, capture+STT+paste all work, and your default trigger fired — one action, many
  # invariants. The marker probe auto-detects the AX false-success data-loss path.
  printf '\n'
  MARKER="KS-PREFLIGHT-$$-DO-NOT-TYPE"
  printf '%s' "$MARKER" | pbcopy
  act "In TextEdit, dictate a short phrase with your normal hotkey, then press ⌘Z once"
  AFTER="$(pbpaste)"
  if [ "$AFTER" = "$MARKER" ]; then
    pass "paste path saved+restored the clipboard (marker intact — the healthy path)"
  else
    fail "clipboard marker changed → not the save/restore paste path (AX false-success or fallback ran)"
    info "now holds: '$AFTER'"
  fi
  if ask "The dictated text appeared AND that single ⌘Z removed all of it"; then
    pass "dictation landed + atomic undo (Mic + Accessibility both bound under the new signature)"
  else
    fail "dictation did not land or did not undo atomically"
  fi

  # Routine 2 — one private cloud rewrite. Auto-verifies the outbound redaction + verbatim fence from
  # the stored history (tokens present, raw secret absent). Skippable if no privacy+cloud mode exists.
  printf '\n'
  if ask "Set up a privacy+cloud mode in the sandbox to test redaction (add a BYOK connection + privacy mode)"; then
    act "In that mode dictate:  email jane dot doe at example dot com begin verbatim KeyScribe TDT v3 end verbatim"
    H="$(latest_history)"; LAST="$(tail -1 "$H" 2>/dev/null)"
    if [ -n "$LAST" ] && printf '%s' "$LAST" | grep -q '⟦SN:REDACT:'; then
      PF="$(printf '%s' "$LAST" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("prompt",""))' 2>/dev/null)"
      if printf '%s' "$PF" | grep -qi 'jane.doe@example.com'; then
        fail "the raw secret appears in the OUTBOUND prompt — it would have leaked"
      else
        pass "outbound prompt holds a redaction token, not the secret (redaction fired)"
      fi
    else
      fail "no ⟦SN:REDACT⟧ in the latest history entry — redaction may not have fired (is privacy on?)"
    fi
    if [ -n "$LAST" ] && printf '%s' "$LAST" | grep -q '⟦SN:VERB:'; then
      pass "verbatim span was tokenized (fenced from the LLM)"
    else
      fail "no ⟦SN:VERB⟧ token — verbatim did not fence (is live-edits on for that mode?)"
    fi
    ask "The inserted text restored the real email and left 'KeyScribe TDT v3' unchanged" \
      && pass "restore round-tripped the secret + verbatim" || fail "restore did not round-trip"
  else
    skip "redaction path — no privacy+cloud mode to test (set one up before shipping the privacy feature)"
  fi

  # Spot-checks — only what you CHANGED this release. Enter past the rest; the routine dictation above
  # already exercised the common paths.
  printf '\n'; bold "  Spot-checks — run only for what you touched this release:"
  if ask "Changed hotkey / trigger code?"; then
    ask "  modifier-only, chord, AND mouse-button triggers each start+stop a dictation" \
      && pass "trigger matrix" || fail "a trigger type did not fire"
  else skip "trigger matrix (hotkey code unchanged)"; fi
  if ask "Changed STT engines / deps?"; then
    ask "  Qwen3-ASR selected loads + transcribes (proves mlx.metallib runs under hardened runtime)" \
      && pass "Qwen loads under hardened runtime" || fail "Qwen failed to load — check metallib signing"
    info "  Also re-run the --raw silence recipe (AGENTS.md 'Silence / no-speech') — no NEW lexical hallucination."
  else skip "Qwen load / silence guard (STT unchanged)"; fi
  if ask "Changed insertion / selection code?"; then
    ask "  edit-in-place (select text → replace-selection mode) rewrites the selection" \
      && pass "edit-in-place" || fail "edit-in-place did not replace the selection"
  else skip "edit-in-place (insertion code unchanged)"; fi
  # Optional and DISRUPTIVE — this one replaces your installed /Applications copy to test the true
  # download experience. Tier A's spctl check already proves notarization; skip unless you want the
  # end-to-end quarantine launch too. (Reinstall your normal copy afterward.)
  if ask "Validate the real /Applications download launch too? (replaces your installed copy)"; then
    info "  hdiutil attach KeyScribe-<ver>.dmg → drag to /Applications"
    info "  xattr -w com.apple.quarantine '0081;0;preflight;' /Applications/KeyScribe.app ; open it"
    ask "  quarantined /Applications copy launched with no 'unidentified developer' block" \
      && pass "quarantined download launches clean" || fail "Gatekeeper blocked the quarantined copy"
  else skip "quarantine /Applications launch (spctl in Tier A already proved notarization)"; fi
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Result"
printf '  %s passed · %s failed · %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"

if [ "$FAILED" -ne 0 ]; then
  bold "PREFLIGHT FAILED — do NOT publish."
  rm -f "$STAMP"
  exit 1
fi

if [ "$MODE" != "release" ]; then
  bold "Automated gates passed ($MODE mode). No stamp written — a real release needs the full run:"
  info "./scripts/preflight.sh   (writes the stamp publish.sh requires)"
  exit 0
fi

# Full release run, everything green + signed off → write the stamp keyed to this exact commit.
SHA="$(git rev-parse HEAD)"
TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '(untagged)')"
{
  echo "$SHA"
  echo "$TAG"
  echo "tiers: A B C"
} > "$STAMP"
bold "PREFLIGHT PASSED — stamp written for $TAG @ ${SHA:0:12}."
info "publish.sh will now allow this commit. Re-run preflight if you rebuild or move HEAD."
