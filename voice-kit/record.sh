#!/bin/zsh
# Usage: zsh record.sh [STUDY] [--app NAME] [--out DIR] [--simulate]
#   STUDY names studies/<STUDY>.tsv (optional when the kit ships exactly one study).
#   --app names the dictation app (default: the kit's app file, else KeyScribe, else KeyScribeDev).
#   --simulate skips the app restart; drop any .wav into <out>/captures yourself to stand in for a take.

set -u
setopt extended_glob null_glob

KIT_DIR="${0:A:h}"
KIT_VERSION="1.2"
APP=""
OUT=""
STUDY=""
SIMULATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --simulate) SIMULATE=1; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) STUDY="$1"; shift ;;
  esac
done

if [ -z "$STUDY" ]; then
  studies=("$KIT_DIR"/studies/*.tsv)
  if [ ${#studies} -eq 1 ]; then STUDY="${studies[1]:t:r}"
  else echo "Which study? One of: ${(j:, :)${(@)studies:t:r}}" >&2; echo "  zsh record.sh <study>" >&2; exit 2; fi
fi
case "$STUDY" in
  */*|*.tsv) PROMPTS="$STUDY"; STUDY="${STUDY:t:r}" ;;
  *) PROMPTS="$KIT_DIR/studies/$STUDY.tsv" ;;
esac
[ -f "$PROMPTS" ] || { echo "No study file at $PROMPTS" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$HOME/Desktop/keyscribe-$STUDY-recordings"

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)

find_app() {
  local name candidate
  local -a names=(KeyScribe KeyScribeDev)
  [ -f "$KIT_DIR/app" ] && names=("$(<"$KIT_DIR/app")")
  [ -n "$APP" ] && names=("$APP")
  for name in "${names[@]}"; do
    for candidate in "/Applications/$name.app" "$HOME/Applications/$name.app"; do
      if [ -d "$candidate" ]; then APP="$name"; APP_PATH="$candidate"; return 0; fi
    done
  done
  return 1
}

if ! find_app; then
  if [ "$SIMULATE" = 1 ]; then APP="${APP:-KeyScribe}"
  else echo "Could not find your dictation app in /Applications. Run again with --app <Name>." >&2; exit 1; fi
fi
SUPPORT="$HOME/Library/Application Support/$APP"
CAPTURES="$OUT/captures"
mkdir -p "$CAPTURES"

app_running() { pgrep -xq "$APP"; }

quit_app() {
  app_running || return 0
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1
  local i
  for i in {1..40}; do app_running || return 0; sleep 0.25; done
  echo "  $APP did not quit. Quit it from its menu bar icon, then press Return."; read -r
}

relaunch_for_recording() {
  [ "$SIMULATE" = 1 ] && return 0
  echo
  echo "  $APP needs a quick restart so it keeps a copy of each recording."
  echo "  Press Return to restart it now."
  read -r
  quit_app
  open -a "$APP_PATH" --args --keep-capture "$CAPTURES"
  sleep 3
}

restore_app() {
  [ "$SIMULATE" = 1 ] && return 0
  quit_app
  open -a "$APP_PATH"
}
trap 'restore_app' EXIT

TITLE="Voice recordings"
INTRO=""
CONSENT="These recordings go only to the person who gave you this kit, to test and improve speech recognition."
typeset -a Q_KEY Q_TEXT Q_OPTS
typeset -a P_ID P_TAGS P_BIAS P_NOTE P_TEXT P_SECTION P_INTRO P_FIRST P_FREE
section=""; intro=""; first=1
while IFS= read -r line; do
  [ -z "$line" ] && continue
  parts=("${(@s:	:)line}")
  key="${parts[1]-}"
  case "$key" in
    @study) ;;
    @title) TITLE="${parts[2]-}" ;;
    @intro) INTRO="${parts[2]-}" ;;
    @consent) CONSENT="${parts[2]-}" ;;
    \?*) Q_KEY+=("${key#\?}"); Q_TEXT+=("${parts[2]-}"); Q_OPTS+=("${parts[3]-}") ;;
    \#) section="${parts[2]-}"; intro="${parts[3]-}"; first=1 ;;
    *)
      P_ID+=("$key"); P_TAGS+=("${parts[2]-}"); P_NOTE+=("${parts[4]-}"); P_TEXT+=("${parts[5]-}")
      P_SECTION+=("$section"); P_INTRO+=("$intro"); P_FIRST+=("$first"); first=0
      if [ "${parts[3]-}" = "FREEFORM" ]; then P_FREE+=(1); P_BIAS+=(""); else P_FREE+=(0); P_BIAS+=("${parts[3]-}"); fi ;;
  esac
done < "$PROMPTS"
TOTAL=${#P_ID}
[ $TOTAL -gt 0 ] || { echo "No prompts in $PROMPTS" >&2; exit 2; }

PROFILE="$OUT/profile.tsv"
TAKES="$OUT/takes.tsv"
touch "$TAKES"

profile_get() { awk -F'\t' -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$PROFILE" 2>/dev/null; }
profile_set() { { grep -v "^$1"$'\t' "$PROFILE" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; } > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"; }

take_field() { awk -F'\t' -v id="$1" -v n="$2" '$1==id {v=$n} END {print v}' "$TAKES"; }
take_set() {
  { grep -v "^$1"$'\t' "$TAKES"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; } > "$TAKES.tmp" && mv "$TAKES.tmp" "$TAKES"
}
done_count() { local n=0 id; for id in "${P_ID[@]}"; do [ -n "$(take_field "$id" 2)" ] && n=$((n+1)); done; echo $n; }

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"; }
json_list() { local out="" item; for item in ${(s:,:)1}; do out+="${out:+, }$(json_str "$item")"; done; printf '[%s]' "$out"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_manifest() {
  local speaker_id="$(profile_get id)" i first_clip=1 first_free=1
  {
    echo '{'
    echo '  "schemaVersion": 1,'
    printf '  "corpus": %s,\n' "$(json_str "$STUDY")"
    printf '  "description": %s,\n' "$(json_str "$TITLE by $speaker_id via the voice kit")"
    printf '  "speakerID": %s,\n' "$(json_str "$speaker_id")"
    echo '  "speaker": {'
    printf '    "nickname": %s,\n' "$(json_str "$(profile_get nickname)")"
    for i in {1..${#Q_KEY}}; do
      printf '    %s: %s,\n' "$(json_str "${Q_KEY[$i]}")" "$(json_str "$(profile_get "q.${Q_KEY[$i]}")")"
    done
    printf '    "consentedAt": %s\n' "$(json_str "$(profile_get consentedAt)")"
    echo '  },'
    echo '  "kit": {'
    printf '    "name": "voice kit", "version": %s, "study": %s, "app": %s,\n' "$(json_str "$KIT_VERSION")" "$(json_str "$STUDY")" "$(json_str "$APP")"
    printf '    "macOS": %s, "machine": %s\n' "$(json_str "$(sw_vers -productVersion)")" "$(json_str "$(sysctl -n hw.model)")"
    echo '  },'
    printf '  "startedAt": %s,\n' "$(json_str "$(profile_get startedAt)")"
    printf '  "completedAt": %s,\n' "$(json_str "$(profile_get completedAt)")"
    echo '  "clips": ['
    for i in {1..$TOTAL}; do
      [ "${P_FREE[$i]}" = 1 ] && continue
      local file="$(take_field "${P_ID[$i]}" 2)"; [ -z "$file" ] && continue
      [ $first_clip = 1 ] || echo ','
      first_clip=0
      printf '    { "id": %s, "file": %s, "text": %s, "source": "human:capture-archive",\n' "$(json_str "${P_ID[$i]}")" "$(json_str "$file")" "$(json_str "${P_TEXT[$i]}")"
      printf '      "tags": %s, "condition": "normal"' "$(json_list "${P_TAGS[$i]}")"
      [ -n "${P_NOTE[$i]}" ] && printf ', "note": %s' "$(json_str "${P_NOTE[$i]}")"
      printf ',\n      "checks": { "stt": { "biasTerms": %s, "tier": "T2" } },\n' "$(json_list "${P_BIAS[$i]}")"
      printf '      "durationSeconds": %s, "takes": %s, "recordedAt": %s,\n' "$(take_field "${P_ID[$i]}" 3)" "$(take_field "${P_ID[$i]}" 4)" "$(json_str "$(take_field "${P_ID[$i]}" 5)")"
      printf '      "heard": %s, "engine": %s, "device": %s }' "$(json_str "$(take_field "${P_ID[$i]}" 6)")" "$(json_str "$(take_field "${P_ID[$i]}" 7)")" "$(json_str "$(take_field "${P_ID[$i]}" 8)")"
    done
    echo
    echo '  ],'
    echo '  "freeform": ['
    for i in {1..$TOTAL}; do
      [ "${P_FREE[$i]}" = 1 ] || continue
      local file="$(take_field "${P_ID[$i]}" 2)"; [ -z "$file" ] && continue
      [ $first_free = 1 ] || echo ','
      first_free=0
      printf '    { "id": %s, "file": %s, "prompt": %s, "source": "human:capture-archive",\n' "$(json_str "${P_ID[$i]}")" "$(json_str "$file")" "$(json_str "${P_TEXT[$i]}")"
      printf '      "durationSeconds": %s, "takes": %s, "recordedAt": %s,\n' "$(take_field "${P_ID[$i]}" 3)" "$(take_field "${P_ID[$i]}" 4)" "$(json_str "$(take_field "${P_ID[$i]}" 5)")"
      printf '      "heard": %s, "engine": %s, "device": %s }' "$(json_str "$(take_field "${P_ID[$i]}" 6)")" "$(json_str "$(take_field "${P_ID[$i]}" 7)")" "$(json_str "$(take_field "${P_ID[$i]}" 8)")"
    done
    echo
    echo '  ]'
    echo '}'
  } > "$OUT/manifest.json.tmp" && mv "$OUT/manifest.json.tmp" "$OUT/manifest.json"
}

history_since() {
  local since="$1" f line
  for f in "$SUPPORT/history/$(date -u +%F).jsonl" "$SUPPORT/history/$(date +%F).jsonl" "$SUPPORT/history/$(date -v-1d -u +%F).jsonl"; do
    [ -f "$f" ] || continue
    line=$(awk -v since="$since" 'match($0, /"timestamp":"[^"]*"/) { ts=substr($0, RSTART+13, RLENGTH-14); if (ts >= since) last=$0 } END { print last }' "$f")
    [ -n "$line" ] && { echo "$line"; return 0; }
  done
  return 1
}
json_field() {
  local key="$2"
  printf '%s' "$1" | sed -nE "s/.*\"$key\":\"((\\\\.|[^\"\\\\])*)\".*/\1/p" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

wav_seconds() { afinfo "$1" 2>/dev/null | awk '/estimated duration/ {printf "%.2f", $3; exit}'; }

ask() { local v; printf '  %s ' "$1" >&2; read -r v; printf '%s' "$v"; }
choose() {
  local label="$1"; shift; local -a opts=("$@"); local i v
  echo "  $label" >&2
  for i in {1..${#opts}}; do echo "     $i) ${opts[$i]}" >&2; done
  while true; do
    printf '  number (Return to skip): ' >&2; read -r v
    [ -z "$v" ] && return
    [[ "$v" == [0-9]## ]] && [ "$v" -ge 1 ] && [ "$v" -le ${#opts} ] && { printf '%s' "${opts[$v]}"; return; }
  done
}

welcome() {
  clear
  echo "${bold}$TITLE${reset}"
  echo
  [ -n "$INTRO" ] && { echo "  $INTRO"; echo; }
  echo "  Each recording and the text $APP heard stay in"
  echo "    $OUT"
  echo "  until you send the zip this script makes at the end. The script itself sends nothing."
  echo
  echo "  Tips: a quiet room, your usual microphone, your normal voice and pace."
  echo
  if [ -z "$(profile_get id)" ]; then
    echo "  A few questions first (press Return to skip any of them)."
    echo
    local nick i answer
    nick=$(ask "Your name or initials (only used to label the files):")
    local slug="${${nick:l}//[^a-z0-9]/-}"; slug="${slug##-}"; slug="${slug%%-}"
    local id="${slug:-speaker}-$(printf '%04x' $RANDOM)"
    profile_set id "$id"; profile_set nickname "$nick"
    for i in {1..${#Q_KEY}}; do
      if [ -n "${Q_OPTS[$i]}" ]; then answer=$(choose "${Q_TEXT[$i]}" "${(@s:|:)Q_OPTS[$i]}")
      else answer=$(ask "${Q_TEXT[$i]}"); fi
      profile_set "q.${Q_KEY[$i]}" "$answer"
    done
    echo
    echo "  $CONSENT"
    echo "  Press Return to agree, or Ctrl-C to stop."
    read -r
    profile_set consentedAt "$(now_iso)"; profile_set startedAt "$(now_iso)"; profile_set completedAt ""
  else
    echo "  Welcome back, $(profile_get nickname). $(done_count) of $TOTAL already recorded."
    echo "  Press Return to continue."
    read -r
  fi
  relaunch_for_recording
}

show_prompt() {
  local i="$1"
  clear
  echo "${dim}Prompt $i of $TOTAL  ·  ${P_SECTION[$i]}${reset}"
  echo
  if [ "${P_FIRST[$i]}" = 1 ] && [ -n "${P_INTRO[$i]}" ]; then echo "  ${P_INTRO[$i]}"; echo; fi
  [ -n "${P_NOTE[$i]}" ] && { echo "  ${dim}How to say it: ${P_NOTE[$i]}${reset}"; echo; }
  if [ "${P_FREE[$i]}" = 1 ]; then
    echo "  ${bold}${P_TEXT[$i]}${reset}"
  else
    echo "  ${bold}“${P_TEXT[$i]}”${reset}"
  fi
  echo
  local secs="$(take_field "${P_ID[$i]}" 3)"
  if [ -n "$secs" ]; then
    echo "  ✓ Recorded (${secs}s). Heard: ${dim}$(take_field "${P_ID[$i]}" 6)${reset}"
    echo
    echo "  ${dim}Return = next   l = listen   dictate again = redo   p = back   q = stop${reset}"
  else
    echo "  Hold your dictation key, read it, release, then press Return."
    echo
    echo "  ${dim}p = back   n = skip for now   q = stop${reset}"
  fi
  echo
  printf '> '
}

capture_take() {
  local i="$1" marker="$2" typed="$3" wav n
  for n in {1..32}; do
    wav=$(ls -t "$CAPTURES"/*.wav(N) 2>/dev/null | head -1)
    [ -n "$wav" ] && [ "$wav" -nt "$marker" ] && break
    wav=""; sleep 0.25
  done
  if [ -z "$wav" ]; then
    echo "  No new recording appeared. Dictate with $APP into this window, then press Return."
    sleep 2; return 1
  fi
  local file="${P_ID[$i]}.wav"
  cp "$wav" "$OUT/$file"
  local secs="$(wav_seconds "$OUT/$file")"
  local prev="$(take_field "${P_ID[$i]}" 4)"; local takes=$(( ${prev:-0} + 1 ))
  local heard="$typed" engine="" device="" line
  if line=$(history_since "$(cat "$marker.iso")"); then
    local h="$(json_field "$line" heard)"; [ -n "$h" ] && heard="$h"
    engine="$(json_field "$line" engine)"; device="$(json_field "$line" device)"
  fi
  take_set "${P_ID[$i]}" "$file" "${secs:-0}" "$takes" "$(now_iso)" "$heard" "$engine" "$device"
  write_manifest
  return 0
}

finish() {
  profile_set completedAt "$(now_iso)"
  write_manifest
  rm -f "$marker" "$marker.iso"
  local id="$(profile_get id)"
  local zip="$HOME/Desktop/keyscribe-$STUDY-$id.zip"
  rm -f "$zip"
  if ditto -c -k --norsrc --keepParent "$OUT" "$zip"; then
    clear
    echo "${bold}All done. Thank you!${reset}"
    echo
    echo "  $(done_count) of $TOTAL prompts recorded."
    echo "  Send this file to the person who gave you the kit:"
    echo
    echo "    ${bold}$zip${reset}"
    echo
    echo "  It is selected in the Finder window that just opened: drag it into an email or chat."
    echo "  After it is sent you can delete the folder $OUT."
    [ "$SIMULATE" = 1 ] || open -R "$zip"
  else
    echo "  Could not create the zip. The recordings are in $OUT; send that folder."
  fi
}

welcome
i=1
for j in {1..$TOTAL}; do [ -z "$(take_field "${P_ID[$j]}" 2)" ] && { i=$j; break; }; done
marker="$OUT/.shown"
while true; do
  touch "$marker"; now_iso > "$marker.iso"
  show_prompt $i
  read -r input || break
  case "$input" in
    q|Q) echo "  Stopped. Run the script again to continue where you left off."; exit 0 ;;
    p|P) [ $i -gt 1 ] && i=$((i-1)) ;;
    n|N) [ $i -lt $TOTAL ] && i=$((i+1)) ;;
    l|L) f="$(take_field "${P_ID[$i]}" 2)"; [ -n "$f" ] && afplay "$OUT/$f" ;;
    "")
      if [ -n "$(take_field "${P_ID[$i]}" 2)" ]; then
        if [ $i -lt $TOTAL ]; then i=$((i+1))
        elif [ "$(done_count)" -eq $TOTAL ]; then finish; exit 0
        else
          echo "  $(( TOTAL - $(done_count) )) prompts are still unrecorded (p goes back, q stops and keeps everything)."
          echo "  Press Return to finish anyway with what you have."; read -r more
          [ -z "$more" ] && { finish; exit 0; }
        fi
      fi ;;
    *) capture_take $i "$marker" "$input" ;;
  esac
done
