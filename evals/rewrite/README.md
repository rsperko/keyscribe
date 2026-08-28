# Rewrite-prompt eval

Measures whether a candidate change to the LLM rewrite prompt actually helps, per scenario, before
it ships — instead of adopting competitor-inspired prompt features on faith. Text-only: no audio, no
mic, no insertion; the corpus (`cases.json`) is fully committed.

```bash
./KeyScribeDev.app/Contents/MacOS/KeyScribe --rewrite-eval evals/rewrite --connection omlx
# limit variants / add repeats / dump literal outputs:
#   --variants baseline,screen-terms --repeat 3 --raw
```

Every case runs through every variant against the chosen saved connection; each output is scored
with the deterministic checks below; the report prints check failures per variant, cases passed per
tag × variant, and a paired "fixes / breaks vs baseline" line per variant. Per-run attempt dumps go
to `results/` (gitignored — they embed model outputs and connection identity).

## Variants

Defined in `RewriteEvalVariants` (KeyScribeKit); prompt changes live behind `PromptAssembler.Options`
(all off by default — `.baseline` is byte-identical to the shipped prompt, test-enforced). A feature
that wins its eval graduates by making its option unconditional and deleting the flag.

| id | change under test |
|---|---|
| `baseline` | today's shipped prompt |
| `screen-terms` | the case's `screenTerms` fed through the existing validTerms + fuzzy-candidate channels (simulates an on-screen AX term harvest without building it) |
| `re-anchor` | output-only reminder appended as the system prompt's last line |
| `screen-terms-re-anchor` | both — the reminder's value only shows when term lists lengthen the system prompt |
| `field-hint` | destination-field rules from the case's `field` flags (single-line / plain text) |
| `user-name` | the case's `userName` hinted as a valid term |
| `temp-0` | baseline prompt at temperature 0 (connections default to 0.2) |

## Case schema (`cases.json`)

`schemaVersion: 1`. Optional top-level `prompts` map for shared mode prompts. Per case: `id`
(unique), `tags[]`, `prompt` (inline) or `promptId`, `transcript` (with realistic STT errors —
seed new ones from real engine output, not invented typos), and optional variant inputs:
`screenTerms[]`, `tokens[]` (literal `⟦SN:…⟧` strings, present in the transcript), `locale`,
`field.singleLine` / `field.plainText`, `appName`, `precedingText`, `selectedText`, `userName`,
`currentDateTime` (a fixed formatted string — checks may then reference absolute dates).

### Checks

- `mustContain` — case-SENSITIVE substring per entry ("ClaudeCode", not "claudecode").
- `mustNotContain` — case-INSENSITIVE substring per entry.
- `regexAbsent` — output must not match (RegexCache/NSRegularExpression syntax).
- `reference` + `maxWer` — word-level edit distance vs the reference, bounded (over-edit guard).
- Always on: non-empty; a no-preamble heuristic (leading "Here is/Sure/Certainly", code-fence wrap,
  whole-output quote wrap) — avoid transcripts that legitimately open with those phrases.
- When `tokens` present: the real `ValidationGate` (every token back exactly once, no strays).
- When `precedingText`/`selectedText` present: context-echo — any word trigram that appears in the
  context but not the transcript must not appear in the output (the "Hi Maria," leak class).

A case passes a variant when every attempt passes every applicable check.

## Authoring gotcha: the screen-terms channel has hard limits

`screen-terms` feeds terms exactly the way production would (mirrors `RewriteRequestBuilder`):
verbatim-present terms become validTerms; near-misses only reach the prompt if
`FuzzyCorrector.candidates` pairs them. That pairing is deliberately timid — multi-word windows snap
on an EXACT normalized match only ("charge bee" → ChargeBee), at most 2 tokens wide, and fuzzy
distance (≤2, phonetic-gated) is single-token only ("postgress" → Postgres). So "cloud code" can
never pair to ClaudeCode and a 3-word split can never pair at all — `recall-cloudcode-unpairable`
exists to keep that limit visible in results. When adding term-recall cases, pick mishearings the
channel can actually deliver, or you are measuring nothing.

## Authoring gotcha: `maxWer` is meaningless for CJK

`BenchmarkScoring.tokens` maps every non-alphanumeric scalar to a space and splits — but CJK
ideographs and kana **are** alphanumeric, so a space-free Japanese sentence collapses to a single
token and WER degenerates to 0-or-1. Score CJK cases with `mustContain` (a kana/kanji fragment that
must survive) and `regexAbsent` (English function words that must not appear); keep
`reference`/`maxWer` for space-delimited languages. `RewriteEvalCorpusTests.cjkCasesDoNotRelyOnWordErrorRate`
enforces this.

A mode prompt that **quotes English literals** beats the language rule, by design. The seeded Email
prompt spells out its scaffolding (`"Hi Sarah,"`, `"Hi,"`, `"Thanks,"`, `"Best,"` — `Mode.swift`), and
on Japanese dictation the floor model returns a correct Japanese body wrapped in `Hi 田中さん,` /
`Best,`. That is the deference clause working as written: `<instructions>` wins. Adding a
"quoted examples are a pattern, not text to copy" sentence to the shared rule was tried and measured —
output was byte-identical, so it was reverted rather than shipped as dead prompt weight. The fix
belongs in the mode: a user who writes in Japanese edits that mode's writing instruction, which is
exactly the per-mode override the design relies on. `language-japanese-email` therefore uses an inline
email prompt that describes the greeting and closing instead of quoting them, so it measures the
shared rule rather than the seeded prompt's literals.

The `language`-tagged cases are **authored, not seeded from engine output** — unlike the English
corpus, nobody here recorded Japanese through a real STT engine, so their transcripts carry realistic
filler (えーと / その) but no engine-specific mishearings. They test language selection, not recognition.

## Running gotcha: a rate-limited provider fakes a catastrophic regression

Variants run **sequentially against one connection**, so a provider with a per-period quota spends it
on the first variant and returns 429 for the rest of the run. The report counts those as `errors` and
the variant reads as `-19` / `-21` broken cases. Check the `errors` column before believing any
regression: if one variant has ~0 errors and the other has dozens, reverse `--variants` and confirm
the errors follow the *position*, not the variant. Observed 2026-08 on Groq (free tier, 151× 429) and
Mistral (30× 429 on whichever variant ran second). Lower `--repeat`, or use a local endpoint, which has
no quota.

## Known corpus gaps (fix these before trusting the affected verdicts)

- **Field-format cases are too easy.** Every `field-format` case passes at baseline on every model
  tested, so the `field-hint` variant has never had a failure to fix — its "+0" verdict is
  *unproven*, not negative. Needed: cases where baseline actually emits markdown or newlines into a
  constrained field (e.g. explicitly list-shaped dictation with a Markdown-leaning mode prompt).
- **Passive-echo cases are too easy.** The greeting/name/selection echo probes pass at baseline;
  only instruction-shaped injection ever failed (now fixed by the graduated fence). Harder passive
  probes (a name the transcript *almost* mentions, context topically identical to the dictation)
  would keep the fence honest.
- **Locale cases conflate two things.** `locale-colour`/`locale-ize` mix inflectional spelling
  (-ise/-ize — the shipped locale clause fixes these) with lexical variants (catalogue/programme —
  it does not). Split the checks before judging any future locale-rule refinement.
- **Repeat noise:** Gemini flakes ~1 attempt in 20 even at temperature 0 (observed: "Postgress"
  kept once under two variants whose prompts were baseline-identical). Use `--repeat 2`+ and treat
  any ±1-case delta that doesn't reproduce across models as noise.

Findings and ship/no-ship calls per variant land in `agent_notes/prompt_eval/`.
