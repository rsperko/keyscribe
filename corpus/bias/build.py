#!/usr/bin/env python3
"""Build the `bias` sub-corpus from a ContextASR-Bench Speech/English shard.

Selects the entries that most exercise recognition bias — entity-dense clips full of *hard*
entities (proper nouns, acronyms, spelled-out alphanumerics an unbiased ASR mangles but a bias
list can recover) — spread across domain families so the kit is not all one vocabulary. Extracts
the chosen wavs (16 kHz mono PCM, as-is: no re-encode, so no ffmpeg `Lavf` tag and verify-source
classifies them synthetic) and writes `manifest.json` in the unified corpus schema (schemaVersion 1).

Every clip is 26–77 s, well past the 4 s streaming threshold, so each one exercises streaming AND
batch. Provenance: audio is ContextASR zero-shot TTS → source `tts:contextasr` (never `human`).

Usage:
  python3 corpus/bias/build.py --shard corpus/bias/shard.tar \
      --meta corpus/bias/ContextASR-Speech_English.jsonl [--n 20] [--family-cap 3] [--domain-cap 1]
"""
import argparse, json, os, re, tarfile

NUMWORDS = set("""zero one two three four five six seven eight nine ten eleven twelve thirteen
fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy
eighty ninety hundred thousand million billion oh negative point first second third fourth fifth""".split())

FAMILY = [
    ("medical", "medic|health|cardio|neuro|pediatr|surg|clinic|nephro|gastro|rheumat|nutrit|diabet|physiolog|anatomy|imaging|wellness|endocrin|obstet|pharma|microbio|patholog"),
    ("military-aviation", "military|aviation|aircraft|naval|navy|defense|defence|stealth|fighter|air ?force|maritime|intelligence|conflict|\\bwar\\b|weapon|missile|radar"),
    ("finance-business", "financ|fintech|trade|econom|corporate|business|market|invest|bank|real estate|logistic"),
    ("arts-media", "art|film|music|vocal|performing|literary|literature|entertainment|criticism|theatre|theater|gaming|video game|photography|film industry"),
    ("sports", "sport|cycling|football|athlet|competition|recreation|tourism"),
    ("tech-electronics", "tech|electronic|audio|computer|software|innovation|consumer|accessor|home entertainment|telecom|energy|infrastructure|standard|hardware"),
    ("history-culture", "history|historical|archaeolog|revolution|medieval|cultural|heritage|tea culture|diplomac|geopolit|antique"),
]

def family(domain):
    d = (domain or "").lower()
    for name, pat in FAMILY:
        if re.search(pat, d):
            return name
    return "other"

def entity_difficulty(e):
    words = e.split()
    nw = len(words)
    d = 1.0 + (1.0 if nw >= 2 else 0.0) + 0.5 * (nw - 1)
    if any(w.strip(".,'").lower() in NUMWORDS for w in words) or any(ch.isdigit() for ch in e):
        d += 1.5
    if any(len(w) >= 2 and w.isupper() for w in words):
        d += 1.5
    if re.search(r"[A-Za-z]-[A-Za-z]|/", e):
        d += 0.5
    d += 0.5 * sum(1 for w in words if w[:1].isupper())
    return d

def clean_terms(entity_list):
    seen, out = set(), []
    for e in entity_list:
        e = e.strip()
        if e and e.lower() not in seen:
            seen.add(e.lower())
            out.append(e)
    return out

def impact(rec):
    ents = rec["entity_list"]
    dsum = sum(entity_difficulty(e) for e in ents)
    density = len(ents) / max(rec["duration"], 1.0)
    return dsum * (1.0 + min(density, 0.4))

def shard_ids(tar):
    with tarfile.open(tar) as t:
        return {os.path.basename(m.name)[:-4] for m in t.getmembers()
                if m.name.endswith(".wav")}

def select(recs, available, n, family_cap, domain_cap):
    ranked = sorted((r for r in recs if r["uniq_id"] in available),
                    key=lambda r: (-impact(r), r["uniq_id"]))
    picked, fam_count, dom_count = [], {}, {}
    # pass 1: strict caps for diversity; pass 2: relax to reach n
    for caps in ((family_cap, domain_cap), (family_cap + 2, 2), (99, 99)):
        fc, dc = caps
        for r in ranked:
            if len(picked) >= n:
                break
            if r in picked:
                continue
            f, d = family(r["domain_label"]), r["domain_label"]
            if fam_count.get(f, 0) >= fc or dom_count.get(d, 0) >= dc:
                continue
            picked.append(r)
            fam_count[f] = fam_count.get(f, 0) + 1
            dom_count[d] = dom_count.get(d, 0) + 1
        if len(picked) >= n:
            break
    return picked

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shard", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--family-cap", type=int, default=3)
    ap.add_argument("--domain-cap", type=int, default=1)
    args = ap.parse_args()

    recs = [json.loads(l) for l in open(args.meta)]
    by_id = {r["uniq_id"]: r for r in recs}
    avail = shard_ids(args.shard)
    picked = select(recs, avail, args.n, args.family_cap, args.domain_cap)
    picked.sort(key=lambda r: (family(r["domain_label"]), -impact(r)))

    os.makedirs(args.out, exist_ok=True)
    members = {os.path.basename(m.name)[:-4]: m
               for m in tarfile.open(args.shard).getmembers() if m.name.endswith(".wav")}
    clips = []
    with tarfile.open(args.shard) as t:
        for i, r in enumerate(picked, 1):
            cid = f"bx{i:02d}"
            uid = r["uniq_id"]
            src = t.extractfile(members[uid]).read()
            open(os.path.join(args.out, f"{cid}.wav"), "wb").write(src)
            terms = clean_terms(r["entity_list"])
            clips.append({
                "id": cid,
                "file": f"{cid}.wav",
                "text": r["text"].strip(),
                "source": "tts:contextasr",
                "tags": ["bias", family(r["domain_label"]), f"contextasr:{uid}"],
                "condition": "clean-tts",
                "checks": {"stt": {"biasTerms": terms, "tier": "T2"}},
            })

    manifest = {
        "schemaVersion": 1,
        "corpus": "bias",
        "description": ("Recognition-bias stress clips derived from ContextASR-Bench "
                        "(MrSupW/ContextASR-Bench, MIT). Entity-dense zero-shot-TTS speech; "
                        "each clip's named entities are the bias terms. 26-77 s, so every clip "
                        "exercises streaming and batch. Rebuild: corpus/bias/build.py."),
        "clips": clips,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"selected {len(clips)} clips from {len(avail)} available in shard")
    fam = {}
    for r in picked:
        fam[family(r["domain_label"])] = fam.get(family(r["domain_label"]), 0) + 1
    print("family spread:", dict(sorted(fam.items())))
    durs = sorted(r["duration"] for r in picked)
    print(f"duration: min {durs[0]:.0f}s  median {durs[len(durs)//2]:.0f}s  max {durs[-1]:.0f}s")
    print(f"total bias terms: {sum(len(c['checks']['stt']['biasTerms']) for c in clips)}")
    print(f"wrote {os.path.join(args.out, 'manifest.json')}")

if __name__ == "__main__":
    main()
