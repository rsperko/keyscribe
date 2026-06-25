#!/usr/bin/env bash
#
# verify-live.sh — interactive checklist for the parts of KeyScribe that can only be verified by a
# human driving the real app (microphone, real BYOK cloud call, cross-app paste). Everything the
# robots can verify headlessly is already covered by `swift test` (incl. DictationPipelineWiringTests,
# which proves the verbatim-first / redaction / restore wiring end-to-end through DictationController).
#
# This script performs the MECHANICAL part of each check by inspecting on-disk artifacts (clipboard,
# history JSONL, mode TOML); you perform the speak/click action when prompted. Nothing here writes to
# the repo or the config — it only reads.
#
# Run from anywhere:  ./verify-live.sh

set -uo pipefail

SUPPORT="$HOME/Library/Application Support/KeyScribe"
HIST="$SUPPORT/history"
MODES="$SUPPORT/modes"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓ %s\033[0m\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
section() { printf '\n'; bold "== $1 =="; }
pause() { printf '\033[33m↳ %s\033[0m\n' "$1"; read -r _; }

latest_history() { ls -t "$HIST"/*.jsonl 2>/dev/null | head -1; }

section "0. Prerequisites"
if [ ! -d "$SUPPORT" ]; then
  fail "No config dir at $SUPPORT — launch KeyScribe at least once first."
fi
info "Build + launch:  ./make-app.sh && open KeyScribe.app"
info "Grant Microphone and Accessibility when prompted."
pause "KeyScribe is running and permissions are granted — press Enter."

# ── 1. Cross-app insertion + atomic undo (the M0 clipboard-marker probe) ──────────────────────────
section "1. Cross-app paste + atomic ⌘Z"
info "Open TextEdit (or any app) and click into an empty document."
MARKER="KS-PROBE-$$-DO-NOT-TYPE"
printf '%s' "$MARKER" | pbcopy
info "Put a marker on the clipboard so we can tell which insertion path ran."
pause "Dictate a short phrase (a few words) into TextEdit, wait for it to appear, then press Enter."
AFTER="$(pbpaste)"
if [ "$AFTER" = "$MARKER" ]; then
  pass "PASTE path — clipboard was saved & restored (marker intact). This is the primary path."
elif [ -z "$AFTER" ] || [ "$AFTER" != "$MARKER" ]; then
  info "Clipboard now holds: '$AFTER'"
  info "If your dictated text is missing from TextEdit AND the marker is gone → clipboard-fallback ran."
  info "If text landed in TextEdit AND the marker is gone → paste path did not restore (investigate)."
  fail "Marker changed — read the two cases above and judge which happened."
fi
pause "Now click into TextEdit and press ⌘Z ONCE. The ENTIRE dictation should disappear in a single undo. Did it? (Enter)"

# ── 2. Redaction wedge — secret tokenized before any cloud call ───────────────────────────────────
section "2. Redaction wedge (privacy mode + real cloud connection)"
info "Pick/create a mode with PRIVACY on and an AI connection that points at your real provider."
info "We'll dictate a recognizable secret and then confirm the STORED prompt holds a token, not the secret."
info "Suggested secret to speak: an email like  jane dot doe at example dot com"
SECRET="jane.doe@example.com"
info "(If you speak a different secret, edit \$SECRET in this script or just eyeball the grep below.)"
pause "Dictate '${SECRET} please' in your privacy+cloud mode, wait for insert, then press Enter."
H="$(latest_history)"
if [ -z "$H" ]; then
  fail "No history file found in $HIST — is history enabled, and did the dictation complete?"
else
  info "Latest history file: $H"
  LAST="$(tail -1 "$H")"
  if printf '%s' "$LAST" | grep -q '⟦SN:REDACT:'; then
    pass "Stored prompt contains a redaction token (⟦SN:REDACT:…⟧) — the secret was tokenized."
  else
    fail "No ⟦SN:REDACT token in the latest entry's prompt — redaction may not have fired."
  fi
  # The prompt field carries tokens, never originals (design.md §4.7). The secret may still appear in
  # the `result`/`heard` fields (those are local), so check specifically that the PROMPT omits it.
  PROMPT_FIELD="$(printf '%s' "$LAST" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("prompt",""))' 2>/dev/null)"
  if [ -n "$PROMPT_FIELD" ] && printf '%s' "$PROMPT_FIELD" | grep -qi "$SECRET"; then
    fail "The raw secret '$SECRET' appears in the stored prompt — IT WOULD HAVE LEAKED. Investigate."
  else
    pass "The raw secret does NOT appear in the stored outbound prompt."
  fi
  info "Also confirm the INSERTED text restored the real secret (it should read '${SECRET}')."
fi

# ── 3. Verbatim span survives a real rewrite ──────────────────────────────────────────────────────
section "3. Verbatim (live, through a real cloud rewrite)"
info "Use a mode with live-edits + an AI connection (privacy optional)."
pause "Dictate:  begin verbatim KeyScribe TDT v3 end verbatim sounds good  — then press Enter."
H="$(latest_history)"
if [ -n "$H" ]; then
  LAST="$(tail -1 "$H")"
  if printf '%s' "$LAST" | grep -q '⟦SN:VERB:'; then
    pass "Stored prompt shows a verbatim token (⟦SN:VERB:…⟧) — the span was fenced from the LLM."
  else
    fail "No ⟦SN:VERB token — verbatim may not have tokenized (is live-edits on for that mode?)."
  fi
  info "Confirm the inserted text contains 'KeyScribe TDT v3' UNCHANGED and the begin/end markers are gone."
fi

# ── 4. Settings commit-on-end-editing (HIG: modeless, write on blur not per keystroke) ────────────
section "4. Settings commit-on-end-editing"
DEFAULT_TOML="$(ls -t "$MODES"/*.toml 2>/dev/null | head -1)"
if [ -z "$DEFAULT_TOML" ]; then
  fail "No mode .toml found in $MODES."
else
  info "Watching: $DEFAULT_TOML"
  info "Open Settings ▸ Modes, select a mode, and click into the Name field."
  BEFORE_MTIME="$(stat -f %m "$DEFAULT_TOML")"
  pause "Type several characters in Name but DO NOT click away / press Return yet — then press Enter here."
  MID_MTIME="$(stat -f %m "$DEFAULT_TOML")"
  # Note: this only proves no-write-while-typing if the watched file is the one being edited; if you
  # selected a different mode, re-run and pick the right file.
  if [ "$MID_MTIME" = "$BEFORE_MTIME" ]; then
    pass "No write while typing (file mtime unchanged) — not committing per keystroke. ✓"
  else
    info "mtime changed while typing — either per-keystroke writes (regression) OR you edited a different mode file."
    fail "Investigate: confirm you were typing in the mode backed by $DEFAULT_TOML."
  fi
  pause "Now press Tab or click another field (commit on end-editing) — then press Enter here."
  AFTER_MTIME="$(stat -f %m "$DEFAULT_TOML")"
  if [ "$AFTER_MTIME" != "$MID_MTIME" ]; then
    pass "Write happened on blur (mtime changed) — commit-on-end-editing works. ✓"
  else
    fail "No write on blur — the edit may not have committed."
  fi
  info "Bonus: type in a field, press Esc — it should revert to the last committed value (eyeball)."
fi

section "Done"
info "Headless coverage (already green via 'swift test'): pipeline wiring, tokenization round-trip,"
info "validation gate, replacements word-boundary, mode resolution. This script covered the rest."
