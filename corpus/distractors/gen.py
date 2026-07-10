#!/usr/bin/env python3
# Generate the recognition-bias DISTRACTOR corpus: ordinary sentences whose audio is acoustically
# adjacent to a dictionary term, with a realistic small dictionary (<=10 terms, the loosest CTC-WS
# gate) active on every clip. On a distractor clip the reference contains NO dictionary term, so any
# term the engine emits is a FALSE FIRE. Control clips DO speak a term, so recall confirms bias still
# fires when it should. Rendered with macOS `say` in a few accents -> 16 kHz mono <id>.wav; manifest
# is (re)written preserving any human takes. TTS acoustics are clean, so this likely UNDER-measures
# false fires (note the caveat in results). Re-runnable. See README.md.
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Neutral, public tech terms only (repo hygiene: no employer/vendor-internal terms). Java/Rust are the
# short single-token terms whose common-word neighbors ("lava", "dust") sit in the classic edit-distance
# false-positive band the fuzzy phonetic gate must reject.
DICT = ["GitHub", "Cloudflare", "Kubernetes", "TypeScript", "Grafana", "Redis", "TextField", "CodeBase",
        "Java", "Rust"]

SAY_VOICES = {"samantha": "Samantha", "daniel": "Daniel", "karen": "Karen"}

# (id, target term the sentence is adjacent to, text). Reference text contains NO dictionary term.
DISTRACTORS = [
    ("d_getup1",   "GitHub",     "I need to get up early tomorrow"),
    ("d_getup2",   "GitHub",     "did you get up on time this morning"),
    ("d_getup3",   "GitHub",     "he could not get up this morning"),
    ("d_cloud1",   "Cloudflare", "we watched a bright flare light up the cloudy sky"),
    ("d_cloud2",   "Cloudflare", "the cloud was there when we looked up"),
    ("d_cloud3",   "Cloudflare", "a solar flare lit up the cloud cover"),
    ("d_comm1",    "Kubernetes", "our local communities came together"),
    ("d_comm2",    "Kubernetes", "the youth communities need more support"),
    ("d_comm3",    "Kubernetes", "small communities often work harder"),
    ("d_script1",  "TypeScript", "what type of script did you use"),
    ("d_script2",  "TypeScript", "that is the type of script I like"),
    ("d_script3",  "TypeScript", "any type of script works fine here"),
    ("d_gonna1",   "Grafana",    "we are gonna have a great time"),
    ("d_gonna2",   "Grafana",    "I am gonna have another coffee soon"),
    ("d_gonna3",   "Grafana",    "they are gonna have a party tonight"),
    ("d_readus1",  "Redis",      "please read us the final results"),
    ("d_readus2",  "Redis",      "he read us a bedtime story"),
    ("d_readus3",  "Redis",      "can you read us the menu please"),
    ("d_field1",   "TextField",  "click the text field above the button"),
    ("d_field2",   "TextField",  "leave the text field empty for now"),
    ("d_field3",   "TextField",  "the text field turned red suddenly"),
    ("d_base1",    "CodeBase",   "review the whole code base before merging"),
    ("d_base2",    "CodeBase",   "we moved the code base to a new server"),
    ("d_base3",    "CodeBase",   "keep the code base clean and simple"),
    # Single-token near-misses (edit distance 1, phonetically distinct): the fuzzy phonetic gate must
    # leave these common words alone. "rusty" is deliberately omitted -- it contains "rust", so the
    # substring-containment false-fire metric cannot score it (see README).
    ("d_lava1",    "Java",       "the lava flow blocked the road"),
    ("d_lava2",    "Java",       "molten lava poured down the hillside"),
    ("d_lava3",    "Java",       "we watched the lava glow at night"),
    ("d_dust1",    "Rust",       "the dust settled on the old shelf"),
    ("d_dust2",    "Rust",       "a thick layer of dust covered the table"),
    ("d_dust3",    "Rust",       "please wipe the dust off the screen"),
    # Long-word (norm >= 7) distance-3 probes for Grafana: blocked today; the future threshold
    # loosening (distance 3 + phonetic-key slack) must keep them blocked.
    ("d_graft1",   "Grafana",    "the grafting process takes several weeks"),
    ("d_graft2",   "Grafana",    "grafting fruit trees is an old craft"),
    ("d_graffiti1","Grafana",    "the graffiti covered the whole wall"),
    ("d_graffiti2","Grafana",    "someone sprayed graffiti on the bridge"),
]

# (id, term, text) where the dictionary term IS spoken -> a fire here is correct, not a false fire.
CONTROLS = [
    ("c_github",     "GitHub",     "I pushed the changes to GitHub this morning"),
    ("c_cloudflare", "Cloudflare", "we put the site behind Cloudflare last week"),
    ("c_kubernetes", "Kubernetes", "the service runs on Kubernetes in production"),
    ("c_typescript", "TypeScript", "we rewrote the whole app in TypeScript"),
    ("c_grafana",    "Grafana",    "the dashboard is built with Grafana"),
    ("c_redis",      "Redis",      "we cache the session data in Redis"),
    ("c_textfield",  "TextField",  "bind the input value to the TextField"),
    ("c_codebase",   "CodeBase",   "the CodeBase is clean and well organized"),
    ("c_java",       "Java",       "we wrote the backend service in Java"),
    ("c_rust",       "Rust",       "the systems layer is written in Rust"),
]


def to_16k_mono(src: Path, dst: Path) -> None:
    subprocess.run(["afconvert", str(src), "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(dst)],
                   check=True, capture_output=True)


def clip(cid: str, text: str, source: str, target: str, kind: str) -> dict:
    return {"id": cid, "file": f"{cid}.wav", "text": text, "source": source,
            "tags": [kind, target],
            "checks": {"stt": {"biasTerms": DICT, "tier": "distractor"}}}


def render(rows, kind, tmp) -> list:
    entries = []
    for tag, name in SAY_VOICES.items():
        for cid_base, target, text in rows:
            cid = f"{cid_base}__say_{tag}"
            aiff = tmp / f"{cid}.aiff"
            subprocess.run(["say", "-v", name, "-o", str(aiff), text], check=True)
            to_16k_mono(aiff, HERE / f"{cid}.wav")
            entries.append(clip(cid, text, f"tts:say:{name}", target, kind))
        print(f"  say {name} ({kind}): done")
    return entries


def main() -> None:
    tmp = HERE / ".tmpwav"
    tmp.mkdir(exist_ok=True)
    entries = render(DISTRACTORS, "distractor", tmp) + render(CONTROLS, "control", tmp)

    man = HERE / "manifest.json"
    human = []
    if man.exists():
        human = [c for c in json.load(open(man)).get("clips", []) if c.get("source") == "human"]
    json.dump({"schemaVersion": 1, "corpus": "distractors",
               "description": "Sound-alike distractor + control clips to measure recognition-bias false fires.",
               "dictionary": DICT,
               "clips": entries + human},
              open(man, "w"), indent=2, ensure_ascii=False)
    for p in tmp.glob("*.aiff"):
        p.unlink()
    tmp.rmdir()
    print(f"\nwrote {len(entries)} synthetic clips (+{len(human)} human takes preserved) to {HERE}")


if __name__ == "__main__":
    main()
