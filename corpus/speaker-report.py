"""Markdown speech-recognition report for one speaker folder.

Usage: python3 corpus/speaker-report.py <folder>

The folder must hold manifest.json and results.json. Normalized WER and
transcripts in results.json are used when present; otherwise the report
falls back to raw WER and the manifest's heard text.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

TOKEN = re.compile(r"\$?\d+(?:[.:]\d+)*%?(?![a-z0-9])|[a-z0-9]+(?:'[a-z0-9]+)*")
PROFILE_SKIP = {"consentedAt"}


def tokenize(text):
    text = text.lower().replace("-", " ").replace("’", "'")
    return TOKEN.findall(text)


def align(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
    ops = []
    i, j = n, m
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            kind = "match" if ref[i - 1] == hyp[j - 1] else "sub"
            ops.append((kind, i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", i - 1, None))
            i -= 1
        else:
            ops.append(("ins", None, j - 1))
            j -= 1
    return ops[::-1]


def lost_ref_indices(ops):
    return {r for kind, r, _ in ops if kind in ("del", "sub")}


def wer_of(row):
    if not row:
        return None, False
    if row.get("werNormalizedUnbiased") is not None:
        return row["werNormalizedUnbiased"], True
    return row.get("werUnbiased"), False


def pct(value):
    return "n/a" if value is None else f"{value * 100:.1f}%"


def label(key):
    return re.sub(r"([a-z])([A-Z])", r"\1 \2", key).capitalize()


def section_of(clip):
    tags = clip.get("tags") or []
    if tags:
        return tags[0]
    match = re.match(r"[A-Za-z]+", clip["id"])
    return match.group(0) if match else clip["id"]


def load(folder):
    paths = [folder / "manifest.json", folder / "results.json"]
    missing = [p.name for p in paths if not p.is_file()]
    if missing:
        sys.stderr.write(f"speaker-report: missing in {folder}: {', '.join(missing)}\n")
        sys.exit(2)
    return [json.loads(p.read_text(encoding="utf-8")) for p in paths]


def speaker_section(manifest, clips, freeform_count):
    lines = ["## 1. Speaker", ""]
    for key, value in (manifest.get("speaker") or {}).items():
        if key not in PROFILE_SKIP:
            lines.append(f"- {label(key)}: {value}")
    lines.append(f"- Scripted clips: {len(clips)}")
    lines.append(f"- Freeform clips: {freeform_count}")
    timed = []
    for clip in clips:
        duration = clip.get("durationSeconds") or 0
        if duration > 0:
            timed.append((len(tokenize(clip["text"])), duration, clip["id"]))
    total_words = sum(w for w, _, _ in timed)
    total_seconds = sum(d for _, d, _ in timed)
    if total_seconds:
        rates = [(w / d * 60, cid) for w, d, cid in timed]
        slowest, fastest = min(rates), max(rates)
        lines.append(
            f"- Speaking rate: {total_words / total_seconds * 60:.1f} words per minute "
            f"(slowest {slowest[0]:.1f} on {slowest[1]}, fastest {fastest[0]:.1f} on {fastest[1]})"
        )
    else:
        lines.append("- Speaking rate: n/a (no clip durations)")
    return lines


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: speaker-report.py <folder>\n")
        sys.exit(2)
    folder = Path(sys.argv[1])
    manifest, results = load(folder)
    clips = manifest.get("clips", [])
    ref_by_id = {c["id"]: tokenize(c["text"]) for c in clips}
    summaries = results.get("engines") or {}
    clip_rows = results.get("clips") or {}

    engine_ids = list(summaries) + [e for e in clip_rows if e not in summaries]

    def engine_sort_key(engine):
        value, _ = wer_of(summaries.get(engine))
        return (value is None, value or 0, engine)

    engine_ids.sort(key=engine_sort_key)

    lines = [f"# Speaker report: {folder.name}", ""]
    lines += speaker_section(manifest, clips, len(manifest.get("freeform") or []))

    lines += ["", "## 2. Engines overall", "", "| Engine | Raw WER (unbiased) | Normalized WER (unbiased) | RTF |", "|---|---|---|---|"]
    for engine in engine_ids:
        row = summaries.get(engine) or {}
        normalized = row.get("werNormalizedUnbiased")
        rtf = row.get("rtf")
        lines.append(
            f"| {engine} | {pct(row.get('werUnbiased'))} | "
            f"{pct(normalized) if normalized is not None else 'n/a'} | "
            f"{f'{rtf:.3f}' if rtf is not None else 'n/a'} |"
        )

    sections = sorted({section_of(c) for c in clips})
    flags = []

    def section_cells(engine):
        cells = []
        for section in sections:
            total = weight = 0.0
            for clip in clips:
                if section_of(clip) != section:
                    continue
                value, normalized = wer_of((clip_rows.get(engine) or {}).get(clip["id"]))
                words = len(ref_by_id[clip["id"]])
                if value is None or words == 0:
                    continue
                flags.append(normalized)
                total += value * words
                weight += words
            cells.append(pct(total / weight) if weight else "n/a")
        return cells

    engine_cells = {engine: section_cells(engine) for engine in engine_ids}
    if flags and all(flags):
        metric = "normalized WER (unbiased)"
    elif flags and not any(flags):
        metric = "raw WER (unbiased)"
    else:
        metric = "normalized WER (unbiased) where present, raw WER (unbiased) otherwise"
    lines += ["", "## 3. WER by section", "",
              f"Word-weighted mean of per-clip {metric}; weight is reference word count.", "",
              "| Engine | " + " | ".join(sections) + " |",
              "|---|" + "---|" * len(sections)]
    for engine in engine_ids:
        lines.append(f"| {engine} | " + " | ".join(engine_cells[engine]) + " |")

    transcripts = results.get("transcripts")
    if transcripts:
        hyps = {
            engine: {cid: t["unbiased"] for cid, t in rows.items() if t and t.get("unbiased") is not None}
            for engine, rows in transcripts.items()
        }
        source_note = "Hypotheses from `transcripts` (unbiased)."
    else:
        speaker_apps = sorted({c["engine"] for c in clips if c.get("engine")})
        hyps = {"heard": {c["id"]: c["heard"] for c in clips if c.get("heard") is not None}}
        source_note = ("No `transcripts` in results.json; using manifest `heard` as one pseudo-engine "
                       f"(speaker's app: {', '.join(speaker_apps) or 'unknown'}).")

    pair_clips = defaultdict(set)
    pair_engines = defaultdict(set)
    for engine, rows in hyps.items():
        for cid, text in rows.items():
            if cid not in ref_by_id:
                continue
            ref, hyp = ref_by_id[cid], tokenize(text)
            for kind, r, h in align(ref, hyp):
                if kind == "sub":
                    pair = (ref[r], hyp[h])
                    if any(ch.isdigit() for ch in pair[0] + pair[1]):
                        continue
                    pair_clips[pair].add((engine, cid))
                    pair_engines[pair].add(engine)
    ranked = sorted(pair_clips, key=lambda p: (-len(pair_clips[p]), -len(pair_engines[p]), p))[:30]

    lines += ["", "## 4. Substitution pairs", "", source_note, ""]
    if ranked:
        lines += ["| Reference | Hypothesis | Clip-engine pairs | Engines |", "|---|---|---|---|"]
        for ref_word, hyp_word in ranked:
            pair = (ref_word, hyp_word)
            lines.append(f"| {ref_word} | {hyp_word} | {len(pair_clips[pair])} | {len(pair_engines[pair])} |")
    else:
        lines.append("No single-word substitutions.")

    engine_order = [e for e in engine_ids if e in hyps] + [e for e in hyps if e not in engine_ids]
    first_missing = {}
    lines += ["", "## 5. First and last word loss", ""]
    for engine in engine_order:
        first_ids, last_ids, evaluated = [], [], 0
        for clip in clips:
            cid, ref = clip["id"], ref_by_id[clip["id"]]
            text = hyps[engine].get(cid)
            if text is None or not ref:
                continue
            evaluated += 1
            lost = lost_ref_indices(align(ref, tokenize(text)))
            first_missing[(engine, cid)] = 0 in lost
            if 0 in lost:
                first_ids.append(cid)
            if len(ref) - 1 in lost:
                last_ids.append(cid)
        lines.append(
            f"- **{engine}** ({evaluated} clips): first word missing in {len(first_ids)}: "
            f"{', '.join(first_ids) or 'none'}; last word missing in {len(last_ids)}: "
            f"{', '.join(last_ids) or 'none'}"
        )

    everyone_missed = [
        clip["id"] for clip in clips
        if ref_by_id[clip["id"]] and engine_order
        and all(first_missing.get((e, clip["id"])) for e in engine_order)
    ]
    lines += ["", "First word missing in every engine with a transcript: "
              f"{', '.join(everyone_missed) or 'none'}"]

    mean_rows = []
    for clip in clips:
        values = [wer_of((rows or {}).get(clip["id"]))[0] for rows in clip_rows.values()]
        values = [v for v in values if v is not None]
        if values:
            mean_rows.append((sum(values) / len(values), clip))
    mean_rows.sort(key=lambda item: (-item[0], item[1]["id"]))
    lines += ["", "## 6. Hardest clips", "", "| Clip | Reference | Mean WER |", "|---|---|---|"]
    for mean, clip in mean_rows[:10]:
        lines.append(f"| {clip['id']} | {clip['text'].replace('|', chr(92) + '|')} | {pct(mean)} |")

    print("\n".join(lines))


if __name__ == "__main__":
    main()
