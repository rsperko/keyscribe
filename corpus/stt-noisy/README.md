# stt-noisy — noisy twins of `stt/`

The same 107 sentences as `corpus/stt/`, with **identical ids and ground-truth text**, re-recorded
in a loud environment (`condition: "noisy"`). Because the labels are shared, pairing each id against
`corpus/stt/` measures how much each engine's WER degrades under real background noise.

The `*.wav` are gitignored (your own voice); the manifest is committed so anyone can record their own
noisy twins against the same sentences and compare.

## Recording

Same recorder as every sub-corpus, pointed here with `--dir`:

```bash
bash corpus/record.sh --dir stt-noisy --status          # progress, records nothing
bash corpus/record.sh --dir stt-noisy --tier T1         # the ranking-grade core first (46 clips)
bash corpus/record.sh --dir stt-noisy                   # everything un-recorded (all 107)
bash corpus/record.sh --dir stt-noisy 01 c27            # (re)record specific ids
```

Protocol: normal voice and normal pace, holding the laptop the way you actually dictate, in an
environment with real background noise. Move between different noise sources across the session so the
set spans a range of SNR rather than one steady hum. Re-record any clip on the spot with `r` if a
passer-by stomped on it.

## Replay

```bash
KeyScribe --benchmark corpus/stt-noisy        # WER / term recall / RTF over the noisy takes
```

Compare the per-engine numbers against a `corpus/stt` run to read off the noise penalty.
