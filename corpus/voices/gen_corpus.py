#!/usr/bin/env python3
# Generate the synthetic multi-voice "scratch that" punctuation corpus: Kokoro (neural, via mlx-audio)
# for US/UK voices + macOS `say` for extra accents. Every clip is written as 16 kHz mono <id>.wav in
# this directory, and manifest.json is (re)written — preserving any human takes already recorded.
# Driven by gen-corpus.sh (which provisions the venv + espeak-ng); see README.md. Re-runnable.
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCH = HERE / "kokoro_launch.py"
MODEL = os.environ.get("KOKORO_MODEL", "mlx-community/Kokoro-82M-bf16")

KOKORO_VOICES = ["af_heart", "af_bella", "am_michael", "am_adam", "bf_emma", "bm_george"]
SAY_VOICES = {"daniel": "Daniel", "karen": "Karen", "moira": "Moira",
              "rishi": "Rishi", "tessa": "Tessa", "samantha": "Samantha"}

# id, kind, expectTerminator, text spoken aloud
PHRASES = [
    ("cmd_pause",  "command", "yes", "We went up the hill, scratch that. We went down the hill."),
    ("cmd_runon",  "command", "yes", "We went up the hill scratch that we went down the hill"),
    ("cmd_after",  "command", "yes", "We went up the hill. Scratch that. We went down the hill."),
    ("cmd_end",    "command", "yes", "I think the meeting is on Tuesday scratch that"),
    ("lit_ticket", "literal", "no",  "I told her to scratch that lottery ticket and see if we won"),
    ("lit_itch",   "literal", "no",  "Let me scratch that itch real quick"),
]


def to_16k_mono(src: Path, dst: Path) -> None:
    subprocess.run(["afconvert", str(src), "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(dst)],
                   check=True, capture_output=True)


def clip(cid: str, text: str, source: str, kind: str, expect: str) -> dict:
    return {"id": cid, "file": f"{cid}.wav", "text": text, "source": source,
            "checks": {"stt": {"biasTerms": []},
                       "command": {"kind": kind, "expectTerminator": expect}}}


def main() -> None:
    tmp = HERE / ".tmpwav"
    tmp.mkdir(exist_ok=True)
    entries, failures = [], []

    for v in KOKORO_VOICES:
        for pid, kind, expect, text in PHRASES:
            cid = f"{pid}__k_{v}"
            prefix = str(tmp / cid)
            # mlx-audio's Kokoro vocoder intermittently hits a shape-broadcast bug for certain
            # phoneme lengths; a small speed nudge changes the length and usually dodges it.
            ok = False
            for speed in ("1.0", "0.95", "1.05"):
                r = subprocess.run([sys.executable, str(LAUNCH), "--model", MODEL, "--text", text,
                                    "--voice", v, "--speed", speed, "--file_prefix", prefix],
                                   capture_output=True, text=True)
                if r.returncode == 0 and Path(f"{prefix}_000.wav").exists():
                    ok = True
                    break
            if not ok:
                failures.append(cid)
                continue
            to_16k_mono(Path(f"{prefix}_000.wav"), HERE / f"{cid}.wav")
            entries.append(clip(cid, text, f"tts:kokoro:{v}", kind, expect))
        print(f"  kokoro {v}: done")

    for tag, name in SAY_VOICES.items():
        for pid, kind, expect, text in PHRASES:
            cid = f"{pid}__say_{tag}"
            aiff = tmp / f"{cid}.aiff"
            subprocess.run(["say", "-v", name, "-o", str(aiff), text], check=True)
            to_16k_mono(aiff, HERE / f"{cid}.wav")
            entries.append(clip(cid, text, f"tts:say:{name}", kind, expect))
        print(f"  say {name}: done")

    # Preserve the hand-recorded human takes verbatim (they carry their own `note` prosody hints);
    # the committed manifest is the source of truth for `record.sh --voices`.
    man = HERE / "manifest.json"
    human = []
    if man.exists():
        human = [c for c in json.load(open(man)).get("clips", []) if c.get("source") == "human"]
    json.dump({"schemaVersion": 1, "corpus": "voices", "clips": entries + human},
              open(man, "w"), indent=2, ensure_ascii=False)
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"\nwrote {len(entries)} synthetic clips (+{len(human)} human takes preserved) to {HERE}")
    if failures:
        print(f"kokoro failures ({len(failures)}, skipped): {', '.join(failures)}")


if __name__ == "__main__":
    main()
