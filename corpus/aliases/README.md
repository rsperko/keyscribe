# Alias discovery held-out corpus

Real-voice clips for measuring the History phrase finder: given a dictionary word, which phrases in
stored Heard text were probably that word misheard. Every clip's dictionary is the full term list in
the manifest, so each clip is a positive for the term it names and a negative for every other term.

- `alias` clips say a dictionary term inside an ordinary sentence.
- `distractor` clips say ordinary words that sound near a term without saying it.
- `control` clips say neither.

This set exists to check the finder on speech it was not tuned on. Record it once, then treat the
manifest as frozen: changing a sentence after looking at a scored run turns it into tuning data.

## Record

```bash
bash corpus/record.sh --aliases --status
bash corpus/record.sh --aliases
```

Read each clip at normal dictation pace. Saying a name slowly and carefully hides the mishearings the
finder is meant to surface.

## Measure

```bash
KeyScribe --alias-discovery corpus/aliases [--engines parakeet,parakeet-ultra] [--threshold 0.6]
```

Each installed engine transcribes every clip; the reference text labels which Heard phrases were
misses. The report gives occurrence and form recall, wrong suggestions per 100 negatives, wrong phrase
groups, and top-three precision. A run whose clips are all transcribed correctly says nothing about
recall, only about wrong suggestions.
