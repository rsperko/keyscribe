#!/bin/zsh
# Usage: zsh package.sh [--app NAME] [--out DIR] [STUDY ...]
#   Writes <out>/voice-kit.zip and <out>/<study>-invite.md per study (out defaults to dist/).
#   STUDY is a name under studies/ or a path to any <study>.tsv (its invite is the .md beside it).
#   With no STUDY every studies/*.tsv ships. --app bakes the recipient's app name into the kit.
set -eu
KIT="${0:A:h}"
APP=KeyScribe
OUT="$KIT/dist"
BAKE_APP=0
studies=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; BAKE_APP=1; shift 2 ;;
    --out) OUT="${2:A}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) studies+=("$1"); shift ;;
  esac
done
[ ${#studies} -gt 0 ] || studies=("$KIT"/studies/*.tsv)

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/voice-kit/studies" "$OUT"
rm -f "$OUT/voice-kit.zip" "$OUT"/*-invite.md(N)
cp "$KIT/record.sh" "$BUILD/voice-kit/"
sed "s/{{APP}}/$APP/g" "$KIT/README.txt" > "$BUILD/voice-kit/README.txt"
[ "$BAKE_APP" = 1 ] && printf '%s' "$APP" > "$BUILD/voice-kit/app"
names=()
for s in "${studies[@]}"; do
  case "$s" in */*|*.tsv) tsv="${s:A}" ;; *) tsv="$KIT/studies/$s.tsv" ;; esac
  [ -f "$tsv" ] || { echo "No study file at $tsv" >&2; exit 2; }
  name="${tsv:t:r}"; names+=("$name")
  cp "$tsv" "$BUILD/voice-kit/studies/"
  [ -f "${tsv:r}.md" ] && sed "s/{{APP}}/$APP/g" "${tsv:r}.md" > "$OUT/$name-invite.md"
done
(cd "$BUILD" && ditto -c -k --norsrc --keepParent voice-kit "$OUT/voice-kit.zip")
echo "$OUT/voice-kit.zip ships ${(j:, :)names} for $APP"
