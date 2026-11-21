#!/bin/zsh
# Drives record.sh --simulate through a short study and checks the manifest and zip it leaves behind.
set -u
KIT="${0:A:h}"
WORK="$(mktemp -d)"
trap 'exec 3>&- 2>/dev/null; rm -rf "$WORK"' EXIT
OUT="$WORK/out"
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR/Desktop"
fail() { echo "FAIL: $*" >&2; [ -f "$WORK/log.txt" ] && tail -20 "$WORK/log.txt" >&2; exit 1; }

cat > "$WORK/short.tsv" <<'TSV'
@study	short
@title	Short test
@intro	Two prompts.
?lang	Your first language:
?room	How is the room?	quiet|noisy
#	Short test	Intro line
t01	casual			First test sentence.
t02	numbers	Postgres	Say it slowly.	Second, with 42 numbers.
#	Own words	Talk freely.
ff01	freeform	FREEFORM		Tell us anything.
TSV

perl -e 'alarm 30; exec @ARGV' say -o "$WORK/take.wav" --data-format=LEF32@16000 "test take" || fail "say could not make a test take"

mkfifo "$WORK/in"
HOME="$HOME_DIR" TERM=xterm zsh "$KIT/record.sh" "$WORK/short.tsv" --out "$OUT" --simulate < "$WORK/in" > "$WORK/log.txt" 2>&1 &
PID=$!
exec 3>"$WORK/in"
send() { sleep 0.4; printf '%s\n' "$1" >&3; }
take() { sleep 0.5; cp "$WORK/take.wav" "$OUT/captures/commit-$RANDOM$RANDOM.wav"; send "$1"; sleep 1.5; }

sleep 1
send "Test Person"; send "Spanish"; send "2"; send ""
sleep 1
take "first test sentence"; send ""
take "second with 42 numbers"; send ""
take "anything at all"; send ""
sleep 2; exec 3>&-
wait $PID || fail "record.sh exited non-zero"

M="$OUT/manifest.json"
[ -f "$M" ] || fail "no manifest written"
python3 -I - "$M" <<'PY' || fail "manifest check"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["corpus"] == "short", m["corpus"]
assert m["speaker"]["nickname"] == "Test Person"
assert m["speaker"]["lang"] == "Spanish"
assert m["speaker"]["room"] == "noisy"
assert m["speaker"]["consentedAt"]
assert m["completedAt"]
assert [c["id"] for c in m["clips"]] == ["t01", "t02"], m["clips"]
t02 = m["clips"][1]
assert t02["checks"]["stt"]["biasTerms"] == ["Postgres"]
assert t02["note"] == "Say it slowly."
assert t02["heard"] == "second with 42 numbers"
assert t02["source"] == "human:capture-archive"
assert [f["id"] for f in m["freeform"]] == ["ff01"]
PY
for f in t01.wav t02.wav ff01.wav; do [ -s "$OUT/$f" ] || fail "missing $f"; done
ls "$HOME_DIR/Desktop"/keyscribe-short-test-person-*.zip >/dev/null 2>&1 || fail "no zip on the Desktop"

PKG="$WORK/pkg"
zsh "$KIT/package.sh" --app Dictator --out "$PKG" "$WORK/short.tsv" accents >/dev/null || fail "package.sh failed"
unzip -q "$PKG/voice-kit.zip" -d "$WORK/unzipped" || fail "package zip unreadable"
[ "$(<"$WORK/unzipped/voice-kit/app")" = Dictator ] || fail "app name not baked into the kit"
[ -f "$WORK/unzipped/voice-kit/studies/short.tsv" ] && [ -f "$WORK/unzipped/voice-kit/studies/accents.tsv" ] || fail "studies missing from the kit"
grep -q '{{APP}}' "$WORK/unzipped/voice-kit/README.txt" "$PKG/accents-invite.md" && fail "unsubstituted {{APP}}"
grep -q Dictator "$PKG/accents-invite.md" || fail "invite does not name the app"
echo "voice kit package: ok"

REL="$WORK/release"
VOICE_KIT_DRY_RUN="$REL" zsh "$KIT/publish.sh" >/dev/null || fail "publish.sh dry run failed"
unzip -q "$REL/voice-kit-accents.zip" -d "$WORK/rel" || fail "no voice-kit-accents.zip"
[ -x "$WORK/rel/voice-kit/record.sh" ] && [ -f "$WORK/rel/voice-kit/studies/accents.tsv" ] || fail "accents zip lacks the recorder or study"
[ "$(ls "$WORK/rel/voice-kit/studies" | wc -l)" -eq 1 ] || fail "accents zip carries other studies"
grep -q "releases/download/voice-kit/voice-kit-accents.zip" "$REL/notes.md" || fail "release notes lack the download link"
grep -q '{{APP}}' "$REL/notes.md" && fail "unsubstituted {{APP}} in release notes"
echo "voice kit release: ok"
echo "voice kit: ok"
