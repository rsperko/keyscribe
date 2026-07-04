#!/usr/bin/env bash
# P2 perf-pass smoke walkthrough — runs the headless checks, then guides the GUI checks step by step.
# Not part of the release gate; a throwaway helper for exercising the P2-1/P2-2/P2-3/P2-4 changes by hand.
#
#   bash scripts/smoke-p2.sh            # full walkthrough
#   bash scripts/smoke-p2.sh --headless # only the automated checks (A1–A3), no GUI prompts
#
# Requires the dev app built (./make-app.sh) and Microphone + Accessibility granted to KeyScribeDev.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP="$ROOT/KeyScribeDev.app"
BIN="$APP/Contents/MacOS/KeyScribe"
HEADLESS=0
[ "${1:-}" = "--headless" ] && HEADLESS=1

if [ ! -x "$BIN" ]; then
  echo "KeyScribeDev.app not found at $APP"
  echo "Build it first:  ./make-app.sh"
  exit 1
fi

hr() { printf '─%.0s' {1..72}; echo; }
step() { echo; hr; echo "  $1"; hr; }
pause() { [ "$HEADLESS" -eq 1 ] && return 0; read -rp $'\n  ▶ Press Enter when done (or Ctrl-C to stop)… ' _; }
ask()  { local a; read -rp "  $1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }

echo "P2 smoke walkthrough — dev app: $APP"
echo "Automated first (A1–A3), then guided GUI (G1–G7)."

########################################  AUTOMATED  ########################################

step "A1 · P2-1 samples-vs-WAV parity (ALL sample-capable engines, incl. Qwen)"
echo "  Transcribes each corpus/commands clip via the WAV path AND the in-memory samples path"
echo "  (two isolated passes) and asserts they are byte-identical. Qwen runs here because the app"
echo "  binary carries the MLX metallib. Expect: every engine 35/35 identical, final ✓ PASS."
echo
"$BIN" --samples-parity corpus/commands || echo "  (non-zero exit = a mismatch surfaced above — investigate that engine)"

step "A2 · P2-1 capture-health canaries"
echo "  Drives the real capture path over a tone and reports dropped/corrupted audio you can't hear."
echo "  Watch the teardown line: ringDropped=0 overloads=0 (both MUST be 0). Needs Microphone permission."
pause
"$BIN" --capture-probe --seconds 5 || echo "  (capture-probe returned non-zero — check the SINAD/glitch report)"

step "A3 · P2-3 head-clip exposure table"
echo "  Trims each command clip by 0/50/100/200 ms and reports command pass-rate per trim. This is the"
echo "  before/after-P1-1 measurement; a steep falloff as ms grows is head-clip sensitivity."
bash corpus/head-trim.sh --engines parakeet-tdt-ctc-110m,apple --bin "$BIN"

if [ "$HEADLESS" -eq 1 ]; then
  echo; echo "Headless checks done. Re-run without --headless for the GUI walkthrough."; exit 0
fi

########################################  GUI (guided)  ########################################

step "Launch the app"
echo "  A KeyScribeDev menu-bar item (orange tint) should appear. Keeping it running for the rest."
open "$APP"
echo "  Give it a moment to register the hotkey + prewarm."
pause

step "G1 · P2-1 live insert + clipboard-restore probe (default engine)"
echo "  1. Click into a normal text field (Notes, TextEdit, a browser box)."
echo "  2. This script has put a MARKER on your clipboard."
printf 'KEYSCRIBE_MARKER_%s' "$$" | pbcopy
echo "     clipboard now = '$(pbpaste)'"
echo "  3. Trigger dictation and say:  the quick brown fox jumps over the lazy dog"
echo "  4. Release and let it insert."
pause
echo "  Checking clipboard restore…"
if [ "$(pbpaste)" = "KEYSCRIBE_MARKER_$$" ]; then
  echo "  ✓ clipboard MARKER intact — the paste path saved/restored it (samples path inserted cleanly)."
else
  echo "  ⚠ clipboard is now: '$(pbpaste)'"
  echo "    If that's your dictated text, insertion fell back to the clipboard path (check why);"
  echo "    if it's empty/other, investigate the restore. (A correct run leaves the MARKER.)"
fi
ask "Did the dictated sentence insert correctly and undo with a single ⌘Z?" \
  && echo "  ✓ noted" || echo "  ⚠ noted — capture the transcript/behavior."

step "G1b · P2-1 per-engine spot check"
echo "  In Settings → Speech Models, switch the active model and dictate one sentence each for the"
echo "  installed engines you care about (Parakeet ×2, Whisper ×2, Qwen ×2, Moonshine, Apple)."
echo "  A1 already proved the samples path is byte-identical offline; this confirms it end-to-end live."
echo "  Watch for a garbled/empty insert on any engine (Moonshine garbles commands — expected)."
pause

step "G2 · P2-2 'Loading speech model…' HUD"
echo "  1. Settings → Speech Models → set eviction to Frugal."
echo "  2. Pick a heavy model (Whisper Large v3 Turbo) as active."
echo "  3. Quit & relaunch the app (so the model is cold), OR wait for idle eviction."
echo "  4. Trigger a dictation, speak briefly, release."
echo "  Expect: after ~1s the HUD reads 'Loading speech model…' (dim mic), THEN flips to 'Transcribing'."
echo "  With eviction back on Fastest (default) it should NEVER appear — the model stays warm."
pause
ask "Did 'Loading speech model…' show during the cold load, then become 'Transcribing'?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "G3 · P2-4 mic glyph FILL with sounds OFF"
echo "  1. Settings → turn dictation sounds OFF."
echo "  2. Trigger and hold; watch the HUD mic glyph."
echo "  Expect: a dim/hollow mic while arming → it FILLS solid red with a level ring the instant the mic"
echo "  goes live (frames admitted). The fill is your only go-signal with sounds off — it should be legible,"
echo "  not a one-frame flash."
pause
ask "Was the dim→solid-red fill on mic-live clearly visible?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "G4 · P2-4 cue overlap with sounds ON"
echo "  1. Settings → turn dictation sounds ON."
echo "  2. Trigger and speak right when the chime ends."
echo "  Expect: the chime plays during the dim/pulsing arming glyph, and the mic fills solid at the chime's"
echo "  end (= admission). The chime end is now an honest 'speak now' boundary. No chime should leak into"
echo "  the transcript (say nothing during the chime; confirm the transcript has no artifact)."
pause
ask "Did the glyph fill at chime-end, with no chime artifact in the transcript?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "G5 · P2-4 fade-out on complete"
echo "  Do any normal dictation and watch the green 'Inserted' toast disappear."
echo "  Expect: it FADES out (~120 ms) rather than vanishing abruptly. Appearance stays instant."
pause
ask "Did the complete toast fade out (not pop out)?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "G6 · P2-4 Reduce Motion"
echo "  1. System Settings → Accessibility → Display → turn Reduce Motion ON."
echo "  2. Do a dictation."
echo "  Expect: no pulsing/fill animation, HUD hides instantly (no fade). Then turn Reduce Motion back OFF."
pause
ask "With Reduce Motion on, were all the new animations bypassed (instant, no fade)?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "G7 · cancel-during-cue (regression guard for the overlap)"
echo "  With sounds ON: trigger, then release (or press ESC) WHILE the chime is still playing."
echo "  Expect: it cancels cleanly — HUD hides, no insert, no stuck mic indicator, next dictation works."
pause
ask "Did an in-cue release/ESC cancel cleanly with no stuck state?" \
  && echo "  ✓ noted" || echo "  ⚠ noted"

step "Done"
echo "  Summary of what each step proved:"
echo "   A1  P2-1 samples path byte-identical to WAV (offline, all engines incl. Qwen)"
echo "   A2  P2-1 capture canaries clean (ringDropped/overloads = 0)"
echo "   A3  P2-3 head-clip exposure quantified"
echo "   G1  P2-1 live insert + clipboard restore correct"
echo "   G2  P2-2 loading HUD honesty"
echo "   G3–G6 P2-4 glyph fill / cue overlap / fade / reduce-motion"
echo "   G7  cancel-during-cue still clean under the cue/bring-up overlap"
echo
echo "  If anything read ⚠, note the engine/state and share it. Re-run A1–A3 anytime with --headless."
