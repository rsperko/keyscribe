# Speech corpus

Recorded speech plus the harnesses that replay it through the real engines and pipeline. Every
recording is your own voice — the `*.wav` are **gitignored**; only the manifests, harness scripts,
and these READMEs are committed, so anyone can record their own clips against the same manifests and
get comparable results.

## The convention

Each **sub-corpus is one folder = a manifest + flat `<id>.wav` files** in that folder. The headless
runners resolve audio as `<dir>/<manifest>.json` + `<dir>/<id>.wav` with no recursion, so clips stay
flat and are organized by **semantic id prefix**, not subfolders. A clip needed by two sub-corpora is
**copied** into each (there is no shared pool).

## Sub-corpora

| Folder | Purpose | Manifest | Replay |
|--------|---------|----------|--------|
| `stt/` | Engine accuracy (WER / term recall / RTF) | `manifest.json` | `KeyScribe --benchmark corpus/stt` — ranked by `compare.sh` |
| `bias/` | Recognition-bias stress + streaming-vs-batch + engine onboarding (ContextASR-Bench derived) | `manifest.json` | `KeyScribe --benchmark corpus/bias [--streaming] [--raw]` — build via `bias/build.py` |
| `commands/` | Spoken-command regression on real transcripts | `manifest.json` | `KeyScribe --commands-check corpus/commands` |
| `voices/` | Multi-voice TTS/human studies of command phrasing | `manifest.json` | `KeyScribe --benchmark corpus/voices --raw` |

## Manifest schema (unified, `schemaVersion: 1`)

Every `manifest.json` has the same shape: a top-level `{ schemaVersion, corpus, description?, context?, clips[] }`,
where each clip carries a **common core** (discovery) plus a namespaced **`checks`** block per task
(expectations). A future tool can glob `corpus/*/manifest.json`, union the `clips`, and query them
uniformly — e.g. all `source == "human"` clips, all with a `checks.stt` block, all whose `text`
contains a phrase.

```jsonc
{
  "schemaVersion": 1,
  "corpus": "commands",                 // stt | commands | voices
  "description": "…",                   // optional, manifest-level
  "context": {                          // optional, manifest-wide run context (commands)
    "clipboard": "agent_notes/foo/",
    "replacements": [ { "heard": "slash resume", "replace": "/resume", "isRegex": false } ]
  },
  "clips": [
    {
      "id": "np_period",
      "file": "np_period.wav",          // relative to this manifest (defaults to "<id>.wav")
      "text": "…",                      // the words spoken (STT ground-truth transcript, or command intent)
      "source": "human",               // "human" | "tts:say:Samantha" | "tts:kokoro:af_heart"
      "tags": ["tech"],                 // optional, free-form discovery strata
      "condition": "normal",            // optional (stt)
      "note": "…",                      // optional delivery cue read aloud to the recorder at record time
                                        //   (pauses / "full stop after X"), NOT rationale or test intent
      "checks": {                       // task expectations; a clip may carry several blocks
        "stt":     { "biasTerms": ["Kubernetes"], "tier": "T2" },
        "command": { "contains": ["…"], "absent": ["…"], "equals": "…",
                     "noLeadingPunct": "…", "kind": "command", "expectTerminator": "yes" }
      }
    }
  ]
}
```

`source` is authoritative provenance: only clips proven to be real recordings are `human` (verified by
content hash against known human takes and by the ffmpeg encoder signature); everything synthetic is
`tts:<engine>[:voice]`.

`stt/` and `voices/` have their own READMEs; `commands/` is documented alongside its manifest.

## Recording

One resumable recorder drives every sub-corpus (`--status` reports progress, records nothing;
re-run any time — existing clips are skipped; explicit ids overwrite):

```bash
bash corpus/record.sh                 # STT engine corpus (stt/) — all un-recorded clips
bash corpus/record.sh --tier T2       #   just the ranking-grade tier
bash corpus/record.sh --commands      # spoken-command cases (commands/)
bash corpus/record.sh --commands vb01 np_period   # (re)record specific command ids in real voice
```

Then replay: `bash corpus/compare.sh` (ranks engines over `stt/`) or
`KeyScribe --commands-check corpus/commands`.
