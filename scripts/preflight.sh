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
# Resumable, per-check ledger: every check has a stable id and its result is recorded under
# .preflight-state/<commit>/. A re-run SKIPS any check already green for this commit + artifact, so a
# single failed check (or a flaky human one) is re-run on its own — you never redo A+B just to redo C.
# On a failure the interactive run offers RETRY (re-run just that check) or OVERRIDE (mark it passed by
# hand, with a reason, recorded truthfully in the stamp). Tiers:
#   A  Build / packaging gates   — automated, no mic. Hard gate. Always runs.
#   B  Functional gates          — automated, needs models + a quiet room. Hard gate where it can run;
#                                   loudly SKIPPED (never silently passed) where the corpus/hardware is absent.
#   C  Human smoke on the real    — interactive checklist against the freshly-installed notarized app.
#      installed app                Must be signed off for the stamp to be written.
#
# Usage:
#   ./scripts/preflight.sh                full run against the RELEASE artifact (KeyScribe.app), writes the stamp
#   ./scripts/preflight.sh --dev          target KeyScribeDev.app; skip notarization checks; NO stamp (dev sanity)
#   ./scripts/preflight.sh --auto         Tier A + B only, non-interactive, NO stamp (CI / quick regression)
#   ./scripts/preflight.sh --pre          PRE-notarize gate: swift test + Tier B only, non-interactive, NO stamp.
#                                         Run before ./release.sh so a red build never wastes the notarize; its
#                                         green results cache into the post-notarize full run via the ledger.
#   ./scripts/preflight.sh --only <ids>   run only these checks (comma-separated); the rest keep their ledger state
#   ./scripts/preflight.sh --force [ids]  ignore the cache and re-run (all checks, or just the listed ids)
#   ./scripts/preflight.sh --list-checks  print every check id and exit
#   ./scripts/preflight.sh --reset        clear this commit's ledger and exit
#
# Env:
#   KEYSCRIBE_MAX_WER=0.20   coarse biased-WER ceiling for the STT benchmark gate (default 0.20).
#                            Set to catch a CATASTROPHIC regression (bias wiring broke → WER doubles),
#                            not to rank engines — Moonshine ships ~15% (no recognition bias) and must
#                            not false-fail. Tune to your installed engine set.
#   KEYSCRIBE_CAPTURE_PROBE=1  run the capture-probe (needs a loopback/Aggregate device feeding a tone)
#   KEYSCRIBE_REQUIRE_ALL_ENGINES=1  a shipped-but-not-installed engine is a hard fail, not a skip.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

MODE="release"; PHASE="full"
ONLY=""; FORCE_ALL=0; FORCE_LIST=""; LIST_ONLY=0; RESET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dev)   MODE="dev" ;;
    --auto)  MODE="auto" ;;
    --pre)   PHASE="pre" ;;
    --only)  ONLY="${2:-}"; shift ;;
    --only=*) ONLY="${1#*=}" ;;
    --force) if [ $# -gt 1 ] && [ "${2#-}" = "${2:-}" ] && [ -n "${2:-}" ]; then FORCE_LIST="$2"; shift; else FORCE_ALL=1; fi ;;
    --force=*) FORCE_LIST="${1#*=}" ;;
    --list-checks) LIST_ONLY=1 ;;
    --reset) RESET=1 ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

MAX_WER="${KEYSCRIBE_MAX_WER:-0.20}"
STAMP="$REPO_ROOT/.preflight-pass"
INTERACTIVE=0; [ "$MODE" = "release" ] && [ "$PHASE" = "full" ] && INTERACTIVE=1

case "$MODE" in
  dev) APP="KeyScribeDev.app"; APP_BIN="MacOS/KeyScribe" ;;
  *)   APP="KeyScribe.app";    APP_BIN="MacOS/KeyScribe" ;;
esac
APP_PATH="$REPO_ROOT/$APP"
EXE="$APP_PATH/Contents/$APP_BIN"

# Everything runs against a THROWAWAY config dir, never your real ~/Library/Application Support/KeyScribe.
# `--config-dir` redirects config/modes/history/onboarding here; downloaded models stay shared and are
# never redirected (KeyScribePaths). Removed on exit — a passing or failing run leaves your daily config
# untouched. (The persistent per-commit LEDGER below is separate and deliberately kept.)
PF_CFG="$REPO_ROOT/.preflight-run"
HIST="$PF_CFG/history"
latest_history() { ls -t "$HIST"/*.jsonl 2>/dev/null | head -1; }
rm -rf "$PF_CFG"; mkdir -p "$PF_CFG"
trap 'rm -rf "$PF_CFG" 2>/dev/null' EXIT

# ── per-commit ledger ───────────────────────────────────────────────────────────────────────────────
# One directory per commit, one small file per check: "<status>\t<input-sig>\t<message>". A cached green
# is reused only when the recorded input-sig still matches (source for swift test, artifact for A/C,
# corpus+engines for B) — so a rebuild or corpus change re-runs the affected checks instead of lying.
RUNKEY="$(git rev-parse HEAD 2>/dev/null || echo nogit)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  RUNKEY="${RUNKEY}+dirty.$(git status --porcelain 2>/dev/null | shasum | cut -c1-8)"
fi
LEDGER_DIR="$REPO_ROOT/.preflight-state/$RUNKEY"
mkdir -p "$LEDGER_DIR"

if [ "$RESET" = 1 ]; then rm -rf "$LEDGER_DIR"; echo "cleared ledger for $RUNKEY"; exit 0; fi

sig_source() { echo "src"; }                                   # captured by RUNKEY (commit + dirty diff)
sig_artifact() { [ -e "$EXE" ] && stat -f '%m.%z' "$EXE" 2>/dev/null || echo none; }
sig_dmg() { [ -e "$1" ] && stat -f '%m.%z' "$1" 2>/dev/null || echo none; }
CORPUS_SIG=""   # computed lazily (needs the app binary for --list-engines)

# ── output helpers + tally ────────────────────────────────────────────────────────────────────────
FAILED=0; SKIPPED=0; PASSED=0; OVERRIDDEN=0; CACHED=0
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
section() { printf '\n'; bold "══ $1 ══"; }
p_pass() { PASSED=$((PASSED+1));         printf '  \033[32m✓ PASS\033[0m      %s\n' "$1"; }
p_skip() { SKIPPED=$((SKIPPED+1));       printf '  \033[33m∅ SKIP\033[0m      %s\n' "$1"; }
p_over() { PASSED=$((PASSED+1)); OVERRIDDEN=$((OVERRIDDEN+1)); printf '  \033[35m⤳ OVERRIDE\033[0m  %s\n' "$1"; }
p_cache(){ PASSED=$((PASSED+1)); CACHED=$((CACHED+1));
           if [ "$1" = override ]; then OVERRIDDEN=$((OVERRIDDEN+1)); printf '  \033[35m⟳ CACHED⤳\033[0m   %s\n' "$2";
           else printf '  \033[32m⟳ CACHED\033[0m   %s\n' "$2"; fi; }
info() { printf '             %s\n' "$1"; }
ask()  { printf '\033[36m  ? %s\033[0m [y/N] ' "$1"; read -r REPLY; [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; }
act()  { printf '\033[36m  ▸ %s\033[0m\n             (press Enter when done) ' "$1"; read -r _; }

# check bodies set their verdict here, then return
RSTATUS=""; RMSG=""
result() { RSTATUS="$1"; RMSG="$2"; }

led_status() { local f="$LEDGER_DIR/$1"; [ -f "$f" ] && cut -f1 <"$f" | head -1 || echo none; }
led_write()  { printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$LEDGER_DIR/$1"; }

only_match() { [ -z "$ONLY" ] && return 0; case ",${ONLY//[[:space:]]/,}," in *,"$1",*) return 0;; esac; return 1; }
force_id()   { [ "$FORCE_ALL" = 1 ] && return 0; case ",${FORCE_LIST//[[:space:]]/,}," in *,"$1",*) return 0;; esac; return 1; }
# The pre-notarize phase runs only these — swift test + Tier B. It must NOT run the Tier A packaging /
# notarization checks (they need the notarized artifact, which does not exist yet) or Tier C (human).
PRE_CHECKS=" a-swift-test b-coverage b-commands b-benchmark b-capture-probe "
pre_check() { case "$PRE_CHECKS" in *" $1 "*) return 0;; esac; return 1; }

# guard <id> <input-sig> <fn>  — the whole cache / run / retry / override / record cycle for one check.
guard() {
  local id="$1" sig="$2" fn="$3"
  only_match "$id" || return 0
  [ "$PHASE" = "pre" ] && ! pre_check "$id" && return 0
  local f="$LEDGER_DIR/$id"
  if ! force_id "$id" && [ -f "$f" ]; then
    local st psig; IFS=$'\t' read -r st psig _ <"$f"
    if { [ "$st" = pass ] || [ "$st" = override ]; } && [ "$psig" = "$sig" ]; then
      p_cache "$st" "[$id] $(cut -f3- <"$f")"; return 0
    fi
  fi
  while true; do
    RSTATUS=""; RMSG=""
    "$fn"
    case "$RSTATUS" in
      pass) p_pass "[$id] $RMSG"; led_write "$id" pass "$sig" "$RMSG"; return 0 ;;
      skip) p_skip "[$id] $RMSG"; led_write "$id" skip "$sig" "$RMSG"; return 0 ;;
      fail|*)
        # Print the failure but do NOT tally it yet — a retried or overridden check is not a failure.
        printf '  \033[31m✗ FAIL\033[0m      %s\n' "[$id] $RMSG"
        if [ "$INTERACTIVE" != 1 ]; then FAILED=$((FAILED+1)); led_write "$id" fail "$sig" "$RMSG"; return 1; fi
        printf '\033[36m     ↻ [r]etry · [o]verride · Enter = leave failed:\033[0m '; read -r ans
        case "$ans" in
          r|R) continue ;;
          o|O) printf '     reason: '; read -r reason
               p_over "[$id] $RMSG"; led_write "$id" override "$sig" "OVERRIDDEN: ${reason:-no reason given} (was: $RMSG)"; return 0 ;;
          *)   FAILED=$((FAILED+1)); led_write "$id" fail "$sig" "$RMSG"; return 1 ;;
        esac ;;
    esac
  done
}

# will_run <id> <sig> — true if guard() would actually execute the body (not cached, passes filters).
# Used only to decide whether to print the Tier C setup banner.
will_run() {
  only_match "$1" || return 1
  force_id "$1" && return 0
  local f="$LEDGER_DIR/$1"
  [ -f "$f" ] || return 0
  local st psig; IFS=$'\t' read -r st psig _ <"$f"
  { [ "$st" = pass ] || [ "$st" = override ]; } && [ "$psig" = "$2" ] && return 1
  return 0
}

# Required checks must each end pass / override / skip (never fail, never un-evaluated) for the stamp.
REQ_CORE="a-swift-test a-artifact a-codesign a-metallib a-plist b-commands b-benchmark"
REQ_RELEASE="a-gatekeeper a-staple a-entitlements a-dmg a-sparkle c-plain-dictation c-private-rewrite"

if [ "$LIST_ONLY" = 1 ]; then
  bold "checks (tier A/B automated, tier C human):"
  for id in $REQ_CORE $REQ_RELEASE b-coverage b-capture-probe c-trigger-matrix c-qwen-hardened c-edit-in-place c-quarantine; do
    printf '  %s\n' "$id"
  done
  exit 0
fi

corpus_sig() {
  if [ -z "$CORPUS_SIG" ]; then
    CORPUS_SIG="$({ cat "$REPO_ROOT/corpus/commands/manifest.json" 2>/dev/null
                    cat "$REPO_ROOT/corpus/stt/manifest.json" 2>/dev/null
                    "$EXE" --config-dir "$PF_CFG" --list-engines 2>/dev/null; } | shasum | cut -c1-12)"
  fi
  echo "$CORPUS_SIG"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Tier A — build / packaging gates"

chk_a_swift_test() {
  if timeout --foreground 900 swift test >/tmp/preflight-swifttest.log 2>&1; then
    result pass "swift test — full suite green"
  else
    tail -20 /tmp/preflight-swifttest.log
    result fail "swift test — see /tmp/preflight-swifttest.log"
  fi
}
guard a-swift-test "$(sig_source)" chk_a_swift_test

chk_a_artifact() {
  if [ -d "$APP_PATH" ]; then result pass "artifact present: $APP"
  else result fail "artifact missing: $APP — build it first (dev: ./make-app.sh, release: ./release.sh)"; fi
}
guard a-artifact "$(sig_artifact)" chk_a_artifact

chk_a_codesign() {
  [ -d "$APP_PATH" ] || { result skip "codesign — artifact missing"; return; }
  if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/tmp/preflight-codesign.log 2>&1; then
    result pass "codesign --verify --deep --strict"
  else
    tail -10 /tmp/preflight-codesign.log
    result fail "codesign verify — see /tmp/preflight-codesign.log"
  fi
}
guard a-codesign "$(sig_artifact)" chk_a_codesign

chk_a_metallib() {
  [ -d "$APP_PATH" ] || { result skip "mlx.metallib — artifact missing"; return; }
  if [ -f "$APP_PATH/Contents/MacOS/mlx.metallib" ]; then
    result pass "mlx.metallib present beside the executable"
  else
    result fail "mlx.metallib MISSING — Qwen3-ASR will crash at load ('Failed to load the default metallib')"
  fi
}
guard a-metallib "$(sig_artifact)" chk_a_metallib

chk_a_plist() {
  [ -d "$APP_PATH" ] || { result skip "Info.plist — artifact missing"; return; }
  local PL SHORT BUILDN BID
  PL="$APP_PATH/Contents/Info.plist"
  SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL" 2>/dev/null || echo "")
  BUILDN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL" 2>/dev/null || echo "")
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PL" 2>/dev/null || echo "")
  if [ -n "$SHORT" ] && [ -n "$BUILDN" ] && [ -n "$BID" ] && [[ "$BID" != *"__"* ]]; then
    result pass "Info.plist stamped: $BID v$SHORT ($BUILDN)"
  else
    result fail "Info.plist not fully stamped (version='$SHORT' build='$BUILDN' id='$BID')"
  fi
}
guard a-plist "$(sig_artifact)" chk_a_plist

if [ "$PHASE" = "pre" ]; then
  :
elif [ "$MODE" = "dev" ]; then
  p_skip "[a-gatekeeper/a-staple/a-entitlements/a-dmg] dev build is self-signed — notarization checked only on release"
else
  chk_a_gatekeeper() {
    [ -d "$APP_PATH" ] || { result skip "Gatekeeper — artifact missing"; return; }
    if spctl -a -t exec -vv "$APP_PATH" 2>&1 | grep -q "source=Notarized Developer ID"; then
      result pass "Gatekeeper: accepted as Notarized Developer ID"
    else
      result fail "Gatekeeper does NOT accept $APP as notarized — a fresh download would be blocked"
    fi
  }
  guard a-gatekeeper "$(sig_artifact)" chk_a_gatekeeper

  chk_a_staple() {
    [ -d "$APP_PATH" ] || { result skip "staple — artifact missing"; return; }
    if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
      result pass "notarization ticket stapled to the app"
    else
      result fail "no stapled ticket — offline first-launch would fail Gatekeeper"
    fi
  }
  guard a-staple "$(sig_artifact)" chk_a_staple

  chk_a_entitlements() {
    [ -d "$APP_PATH" ] || { result skip "entitlements — artifact missing"; return; }
    if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "com.apple.security"; then
      result pass "hardened-runtime entitlements present"
    else
      result fail "no entitlements on the signed app — hardened runtime not applied"
    fi
  }
  guard a-entitlements "$(sig_artifact)" chk_a_entitlements

  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  DMG="$REPO_ROOT/KeyScribe-$VERSION.dmg"
  chk_a_dmg() {
    if [ -n "$VERSION" ] && [ -f "$DMG" ]; then
      if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
        result pass "release DMG present + ticket validated: KeyScribe-$VERSION.dmg"
      else
        result fail "KeyScribe-$VERSION.dmg is not stapled/validated"
      fi
    else
      result fail "release DMG KeyScribe-$VERSION.dmg not built — run ./release.sh"
    fi
  }
  guard a-dmg "$(sig_dmg "$DMG")" chk_a_dmg

  # The production build ships Sparkle for in-app updates; a broken updater is invisible until a user
  # tries to update (or the app crashes at launch on a missing rpath). Gate the three ways it silently
  # breaks: framework not embedded (release built without KEYSCRIBE_SPARKLE=1), the load-bearing
  # @executable_path/../Frameworks rpath missing (dyld can't find it → launch crash), or SUPublicEDKey
  # absent/placeholder (updates can't be EdDSA-verified). See agent_notes/distribution_plan/sparkle.md.
  chk_a_sparkle() {
    [ -d "$APP_PATH" ] || { result skip "Sparkle updater — artifact missing"; return; }
    local BIN FW PL KEY
    BIN="$APP_PATH/Contents/$APP_BIN"
    FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    PL="$APP_PATH/Contents/Info.plist"
    KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PL" 2>/dev/null || echo "")
    if ! otool -L "$BIN" 2>/dev/null | grep -q "Sparkle.framework"; then
      result fail "binary does not link Sparkle — release built without KEYSCRIBE_SPARKLE=1; the app cannot self-update"
    elif [ ! -d "$FW" ]; then
      result fail "binary links Sparkle but Sparkle.framework is NOT embedded — dyld will fail at launch"
    elif ! otool -l "$BIN" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
      result fail "missing @executable_path/../Frameworks rpath — dyld cannot load Sparkle.framework; the app crashes at launch"
    elif [ -z "$KEY" ] || [[ "$KEY" == *"__"* ]]; then
      result fail "SUPublicEDKey absent/placeholder in Info.plist — updates cannot be EdDSA-verified"
    else
      result pass "Sparkle updater intact: binary links Sparkle, framework embedded, Frameworks rpath present, SUPublicEDKey set"
    fi
  }
  guard a-sparkle "$(sig_artifact)" chk_a_sparkle
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Tier B — functional gates (automated; needs models + a quiet room)"

chk_b_coverage() {
  local COV TESTED MISSING
  COV="$("$EXE" --config-dir "$PF_CFG" --list-engines 2>/dev/null)"
  TESTED="$(printf '%s\n' "$COV" | awk -F'\t' '$2!="missing"{print $1}' | paste -sd, -)"
  MISSING="$(printf '%s\n' "$COV" | awk -F'\t' '$2=="missing"{print $1}' | paste -sd, -)"
  info "engine coverage — will test: ${TESTED:-<none installed>}"
  if [ -z "$MISSING" ]; then
    result pass "engine coverage: every shipped engine is installed"
  elif [ "${KEYSCRIBE_REQUIRE_ALL_ENGINES:-0}" = "1" ]; then
    result fail "shipped engines NOT installed (untested): $MISSING — install them, or unset KEYSCRIBE_REQUIRE_ALL_ENGINES"
  else
    result skip "shipped engines NOT installed, so UNTESTED: $MISSING (KEYSCRIBE_REQUIRE_ALL_ENGINES=1 to require full coverage)"
  fi
}
guard b-coverage "$(corpus_sig)" chk_b_coverage

chk_b_commands() {
  local CMD_BASELINE="$REPO_ROOT/corpus/commands/baseline.json"
  [ -f "$REPO_ROOT/corpus/commands/manifest.json" ] || { result skip "--commands-check: corpus/commands not present (record it: bash corpus/record.sh --commands)"; return; }
  if timeout --foreground 1200 "$EXE" --config-dir "$PF_CFG" --commands-check "$REPO_ROOT/corpus/commands" --baseline "$CMD_BASELINE" >/tmp/preflight-commands.log 2>&1; then
    if grep -q "BASELINE ESTABLISHED" /tmp/preflight-commands.log; then
      grep "BASELINE ESTABLISHED" /tmp/preflight-commands.log | sed 's/^/             /'
      result skip "--commands-check: baseline just established — re-run preflight to gate against it"
    else
      result pass "--commands-check: every engine held its baseline"
    fi
  else
    grep -E "^FAIL" /tmp/preflight-commands.log | sed 's/^/             /' | head -20
    result fail "--commands-check regressed vs baseline — see /tmp/preflight-commands.log"
  fi
}
guard b-commands "$(corpus_sig)" chk_b_commands

chk_b_benchmark() {
  [ -f "$REPO_ROOT/corpus/stt/manifest.json" ] || { result skip "--benchmark: corpus/stt not present"; return; }
  if timeout --foreground 2400 "$EXE" --config-dir "$PF_CFG" --benchmark "$REPO_ROOT/corpus/stt" >/tmp/preflight-bench.log 2>&1; then
    local RES="$REPO_ROOT/corpus/stt/results.json" WORST
    [ -f "$RES" ] || { result skip "--benchmark ran but wrote no results.json"; return; }
    WORST=$(python3 - "$RES" "$MAX_WER" <<'PY'
import json, sys
res = json.load(open(sys.argv[1])); ceil = float(sys.argv[2])
bad = [(k, v.get("werBiased", 0)) for k, v in res.items() if v.get("werBiased", 0) > ceil]
print("\n".join(f"{k}={w:.3f}" for k, w in sorted(bad, key=lambda x: -x[1])))
PY
)
    if [ -z "$WORST" ]; then
      result pass "--benchmark: all engines under the ${MAX_WER} biased-WER ceiling"
    else
      printf '%s\n' "$WORST" | sed 's/^/             /'
      result fail "--benchmark: engines OVER the ${MAX_WER} ceiling — bias/model regression likely"
    fi
  else
    tail -10 /tmp/preflight-bench.log
    result fail "--benchmark errored — see /tmp/preflight-bench.log"
  fi
}
guard b-benchmark "$(corpus_sig)" chk_b_benchmark

chk_b_capture_probe() {
  [ "${KEYSCRIBE_CAPTURE_PROBE:-0}" = "1" ] || { result skip "--capture-probe: set KEYSCRIBE_CAPTURE_PROBE=1 with a loopback device to run (needed when the audio path changed)"; return; }
  if timeout --foreground 60 "$EXE" --config-dir "$PF_CFG" --capture-probe --seconds 5 >/tmp/preflight-capture.log 2>&1; then
    if grep -qE "ringDropped=0.*overloads=0|overloads=0.*ringDropped=0" /tmp/preflight-capture.log; then
      result pass "--capture-probe: no ring drops, no CoreAudio overloads"
    else
      grep -E "ringDropped|overloads|SINAD|glitch" /tmp/preflight-capture.log | sed 's/^/             /'
      result fail "--capture-probe: ring drops or overloads detected"
    fi
  else
    result fail "--capture-probe errored — see /tmp/preflight-capture.log"
  fi
}
guard b-capture-probe "$(sig_artifact)" chk_b_capture_probe

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Tier C — human smoke on the REAL installed app. Skipped in --auto (no human) and --dev (no notarized
# artifact). Each check is a single dictation or spot-check; a failure can be retried in place.
if [ "$MODE" != "release" ] || [ "$PHASE" = "pre" ]; then
  section "Tier C — SKIPPED (no human sign-off in $MODE/$PHASE — no stamp will be written)"
else
  section "Tier C — human smoke (routine: 2 dictations, ~3 min)"
  AS="$(sig_artifact)"
  if will_run c-plain-dictation "$AS" || will_run c-private-rewrite "$AS" \
     || will_run c-trigger-matrix "$AS" || will_run c-qwen-hardened "$AS" \
     || will_run c-edit-in-place "$AS" || will_run c-quarantine "$AS"; then
    info "This runs against a THROWAWAY config dir — your real KeyScribe config, modes, and history are"
    info "untouched, and this sandbox is deleted when preflight exits. Shared (and safe): downloaded"
    info "models (read-only), and the Mic/Accessibility grants + any BYOK key (bundle-scoped, additive)."
    printf '\n'
    info "Setup — so the sandbox instance is the one running:"
    info "  1. Quit your normal KeyScribe if it is running (same bundle id, or macOS reuses it)."
    info "  2. Launch the just-built notarized app against the sandbox:"
    info "       open $APP_PATH --args --config-dir '$PF_CFG' --first-run"
    info "  3. Finish onboarding (a model downloads), grant Mic + Accessibility, relaunch if asked."
    info "All Tier C checks below should use that same app + config dir unless a prompt says otherwise."
    info "When done, quit the sandbox instance and reopen whichever KeyScribe you normally use."
    act "Sandbox app is launched, onboarded, and permissions granted"
  else
    info "all Tier C checks already green for this build — nothing to drive."
  fi

  # Routine 1 — one plain dictation. If text lands at all, the fresh signature's Mic + Accessibility
  # grants BOTH bound, capture+STT+paste all work, and your default trigger fired. The marker probe
  # auto-detects the AX false-success data-loss path. Retry re-does the dictation.
  chk_c_plain_dictation() {
    local MARKER AFTER
    if ! ask "Run plain dictation smoke now?"; then result skip "plain dictation skipped by operator"; return; fi
    info "  Expected: use the sandbox app launched above ($APP_PATH with --config-dir '$PF_CFG')."
    info "  In TextEdit, dictate a short phrase with your normal hotkey. Confirm text appears, then press ⌘Z once."
    MARKER="KS-PREFLIGHT-$$-DO-NOT-TYPE"
    printf '%s' "$MARKER" | pbcopy
    act "Plain dictation was performed and ⌘Z was pressed"
    AFTER="$(pbpaste)"
    if [ "$AFTER" != "$MARKER" ]; then
      result fail "clipboard marker changed → not the save/restore paste path (AX false-success or fallback ran); now holds: '$AFTER'"; return
    fi
    if ask "The dictated text appeared AND that single ⌘Z removed all of it"; then
      result pass "plain dictation landed + atomic undo, paste save/restore intact (Mic + Accessibility bound under the new signature)"
    else
      result fail "dictation did not land or did not undo atomically"
    fi
  }
  printf '\n'; guard c-plain-dictation "$AS" chk_c_plain_dictation

  # Routine 2 — one private cloud rewrite. Reads the redaction + verbatim fence back from the stored
  # history of THE MOST RECENT dictation, so this must be your last dictation before answering (retry
  # re-does it, which makes it the latest again — that is the fix for the "wrong entry" false-fail).
  chk_c_private_rewrite() {
    if ! ask "Run private cloud rewrite/redaction smoke now?"; then result skip "private rewrite skipped by operator"; return; fi
    info "  Expected: in the sandbox config, add/select a privacy+cloud mode with a BYOK connection."
    info "  Dictate the exact phrase below in that mode, and make it your LAST dictation before continuing."
    info "  Phrase: email jane dot doe at example dot com begin verbatim KeyScribe TDT v3 end verbatim"
    act "Private rewrite dictation was performed as the latest dictation"
    local H LAST PF
    H="$(latest_history)"; LAST="$(tail -1 "$H" 2>/dev/null)"
    if [ -z "$LAST" ] || ! printf '%s' "$LAST" | grep -q '⟦SN:REDACT:'; then
      result fail "no ⟦SN:REDACT⟧ in the LATEST history entry — redaction did not fire, OR a later dictation is now the last entry (retry, keeping this your last)"; return
    fi
    PF="$(printf '%s' "$LAST" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("prompt",""))' 2>/dev/null)"
    if printf '%s' "$PF" | grep -qi 'jane.doe@example.com'; then
      result fail "the raw secret appears in the OUTBOUND prompt — it would have leaked"; return
    fi
    if ! printf '%s' "$LAST" | grep -q '⟦SN:VERB:'; then
      result fail "no ⟦SN:VERB⟧ token — verbatim did not fence (is live-edits on for that mode?)"; return
    fi
    if ask "The inserted text restored the real email and left 'KeyScribe TDT v3' unchanged"; then
      result pass "private rewrite: outbound holds a redaction token not the secret, verbatim fenced, restore round-tripped"
    else
      result fail "restore did not round-trip the secret / verbatim"
    fi
  }
  printf '\n'; guard c-private-rewrite "$AS" chk_c_private_rewrite

  # Spot-checks — only what you CHANGED this release. Each skips unless you opt in.
  printf '\n'; bold "  Spot-checks — run only for what you touched this release:"
  chk_c_trigger_matrix() {
    if ! ask "Changed hotkey / trigger code this release?"; then result skip "trigger matrix (hotkey code unchanged)"; return; fi
    info "  Expected: using the same sandbox app/config, verify all trigger types you ship."
    info "  Start and stop one dictation with each: modifier-only trigger, chord trigger, and mouse-button trigger."
    if ask "  modifier-only, chord, AND mouse-button triggers each start+stop a dictation"; then result pass "trigger matrix"; else result fail "a trigger type did not fire"; fi
  }
  guard c-trigger-matrix "$AS" chk_c_trigger_matrix

  chk_c_qwen_hardened() {
    if ! ask "Changed STT engines / deps this release?"; then result skip "Qwen load / silence guard (STT unchanged)"; return; fi
    info "  Expected: using the same sandbox app/config, select Qwen3-ASR and dictate a short phrase."
    info "  This proves mlx.metallib loads from the hardened-runtime release app."
    info "  Also re-run the --raw silence recipe (AGENTS.md 'Silence / no-speech') — no NEW lexical hallucination."
    if ask "  Qwen3-ASR selected loads + transcribes (proves mlx.metallib runs under hardened runtime)"; then result pass "Qwen loads under hardened runtime"; else result fail "Qwen failed to load — check metallib signing"; fi
  }
  guard c-qwen-hardened "$AS" chk_c_qwen_hardened

  chk_c_edit_in_place() {
    if ! ask "Changed insertion / selection code this release?"; then result skip "edit-in-place (insertion code unchanged)"; return; fi
    info "  Expected: using the same sandbox app/config, select text in an editor and run replace-selection mode."
    info "  Confirm the selected text is replaced, not appended beside the selection."
    if ask "  edit-in-place (select text → replace-selection mode) rewrites the selection"; then result pass "edit-in-place"; else result fail "edit-in-place did not replace the selection"; fi
  }
  guard c-edit-in-place "$AS" chk_c_edit_in_place

  chk_c_quarantine() {
    if ! ask "Validate quarantined launch of the repo-local release app too?"; then result skip "quarantine launch skipped (spctl in Tier A already proved notarization)"; return; fi
    info "  Expected: quit KeyScribe, mark the repo-local release app as quarantined, then launch it with the same sandbox config."
    info "  Run:"
    info "    xattr -w com.apple.quarantine '0081;0;preflight;' '$APP_PATH'"
    info "    open '$APP_PATH' --args --config-dir '$PF_CFG'"
    if ask "  quarantined repo-local app launched with no 'unidentified developer' block and used '$PF_CFG'"; then result pass "quarantined repo-local app launches clean"; else result fail "Gatekeeper blocked the quarantined repo-local app"; fi
  }
  guard c-quarantine "$AS" chk_c_quarantine
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
section "Result"
printf '  %s passed (%s cached, %s overridden) · %s failed · %s skipped\n' \
  "$PASSED" "$CACHED" "$OVERRIDDEN" "$FAILED" "$SKIPPED"

# Any required check that is currently failing, or was never evaluated for this commit, blocks the stamp.
if [ "$PHASE" = "pre" ]; then
  REQUIRED="a-swift-test b-commands b-benchmark"
elif [ "$MODE" = "release" ]; then
  REQUIRED="$REQ_CORE $REQ_RELEASE"
else
  REQUIRED="$REQ_CORE"
fi
HARDFAIL=0; OUTSTANDING=""
for id in $REQUIRED; do
  case "$(led_status "$id")" in
    pass|override|skip) ;;
    fail) HARDFAIL=1; OUTSTANDING="$OUTSTANDING $id(failed)" ;;
    *)    OUTSTANDING="$OUTSTANDING $id(not-run)" ;;
  esac
done
[ "$FAILED" -gt 0 ] && HARDFAIL=1

if [ "$HARDFAIL" -ne 0 ]; then
  bold "PREFLIGHT FAILED — do NOT publish."
  [ -n "$OUTSTANDING" ] && info "blocking:$OUTSTANDING"
  info "re-run just the failures: ./scripts/preflight.sh --only <id>   (or --force <id> to ignore the cache)"
  [ "$PHASE" = "pre" ] && info "this failed BEFORE notarizing — fix it and re-run, no Apple round-trip wasted."
  rm -f "$STAMP"
  exit 1
fi

if [ "$PHASE" = "pre" ]; then
  bold "PRE-NOTARIZE GATES PASSED — safe to notarize."
  info "swift test + Tier B are green and cached for this commit; the post-notarize run reuses them,"
  info "so ./release.sh then './scripts/preflight.sh' only runs Tier A packaging + the Tier C smoke."
  exit 0
fi

if [ "$MODE" != "release" ]; then
  bold "Automated gates passed ($MODE mode). No stamp written — a real release needs the full run:"
  info "./scripts/preflight.sh   (writes the stamp publish.sh requires; A+B stay cached, you drive Tier C)"
  exit 0
fi

if [ -n "$OUTSTANDING" ]; then
  bold "PREFLIGHT INCOMPLETE — no stamp yet."
  info "still to run for this commit:$OUTSTANDING"
  info "run the full gate (cached checks are skipped): ./scripts/preflight.sh"
  exit 0
fi

# Everything required is green or overridden → write the stamp keyed to this exact commit. First line
# stays the raw SHA (publish.sh matches on it); the breakdown below records any overrides truthfully.
SHA="$(git rev-parse HEAD)"
TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '(untagged)')"
{
  echo "$SHA"
  echo "$TAG"
  echo "tiers: A B C"
  for id in $REQUIRED; do printf 'check %s: %s\n' "$id" "$(led_status "$id")"; done
  [ "$OVERRIDDEN" -gt 0 ] && echo "note: $OVERRIDDEN check(s) OVERRIDDEN by hand — see .preflight-state/$RUNKEY/"
} > "$STAMP"
bold "PREFLIGHT PASSED — stamp written for $TAG @ ${SHA:0:12}."
[ "$OVERRIDDEN" -gt 0 ] && info "$OVERRIDDEN check(s) were overridden by hand (recorded in the stamp)."
info "publish.sh will now allow this commit. Re-run preflight if you rebuild or move HEAD."
