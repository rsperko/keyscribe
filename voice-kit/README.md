# Voice kit

A guided recorder for collecting speech from other people. The recipient runs one script against the
dictation app they already have; it walks them through a study's prompts, keeps the audio the app
captured and what it heard, and packs a zip for them to send back. Nothing is installed and the
script sends nothing.

Each kind of corpus is a **study**: `studies/<study>.tsv` (the prompts and questions) plus an optional
`studies/<study>.md` (the invite to send with the kit). Adding a study is adding those two files.

## Hand it out

Every release attaches `KeyScribe-voice-kit-<version>.zip` with all studies. To build one yourself:

```bash
make voice-kit                       # every study → voice-kit/dist/
make voice-kit STUDY=accents         # one study; the recipient then runs record.sh with no argument
zsh voice-kit/package.sh --app MyApp path/to/private.tsv   # a white-label build, or a study kept out of the repo
```

`dist/voice-kit.zip` is the kit; `dist/<study>-invite.md` is the note to send with it, with `{{APP}}`
filled in. The recipient unzips into Downloads and runs `zsh ~/Downloads/voice-kit/record.sh`
(`record.sh <study>` when the kit carries several). The script relaunches their app once with
`--keep-capture <dir>` so every committed take is archived, and once more at the end to put it back.
It finds the app named by `--app`, else the kit's baked `app` file, else KeyScribe, else KeyScribeDev.

## What comes back

`keyscribe-<study>-<speaker>.zip` on their Desktop, holding:

- `manifest.json` — the unified corpus schema (`corpus/README.md`): `corpus: <study>`, `clips[]` with
  `checks.stt` and `source: "human:capture-archive"`, plus `speaker{}` from the study's questions,
  `kit{}`, `freeform[]` for unscripted prompts, and per clip the `heard` text, `engine` and `device`
  their app wrote to History at the time.
- `<id>.wav` — the take kept per prompt, straight from the app's capture path.
- `captures/` — every archived take including redos (`takes` in the manifest counts them).
- `profile.tsv`, `takes.tsv` — the script's own state.

Ingest under `corpus/received/` (gitignored: it is someone else's voice and answers), flat so the
runners find it:

```bash
unzip keyscribe-accents-ana-1f2e.zip -d corpus/received/accents/
KeyScribe --benchmark corpus/received/accents/ana-1f2e
```

## Study file format (tab-separated)

```
@study    accents                       # names the output folder, the zip, and manifest.corpus
@title    Accent recordings             # welcome-screen heading
@intro    You will read 35 short sentences, about ten minutes in all.
@consent  These recordings go only to …  # shown before the Return-to-agree step
?firstLanguage  Your first language:                                          # free text → speaker.firstLanguage
?englishSince   When did you start speaking English?  from birth|as a child  # a choice
#   Section title   Intro shown with the section's first prompt
w01   casual          (biasTerms)   (note)   Thank you for waiting. …
d04   tech            Postgres,Kubernetes     The Postgres migration …
n01   numbers                       Say the order number digit by digit.   The order number is 47291 …
ff01  freeform        FREEFORM      Describe what you did yesterday.        # unscripted → freeform[]
```

Prompt rows are `id  tags  biasTerms  note  text`. Ids become the WAV names, so keep them unique. The
name-or-initials question is always asked first; it labels the files.

## Testing

`make test-voice-kit` drives `record.sh --simulate` through a short study and checks the manifest, the
zip, and the packager. By hand: `zsh voice-kit/record.sh --simulate --out /tmp/x <study>` skips the
app restart; copy any WAV into `/tmp/x/captures/` to stand in for a take.
