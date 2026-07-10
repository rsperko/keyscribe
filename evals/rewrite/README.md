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
| `locale` | "Write in {language}" carries the case's `locale` spelling variant |
| `user-name` | the case's `userName` hinted as a valid term |
| `temp-0` | baseline prompt at temperature 0 (connections default to 0.2) |

## Case schema (`cases.json`)

`schemaVersion: 1`. Optional top-level `prompts` map for shared mode prompts. Per case: `id`
(unique), `tags[]`, `prompt` (inline) or `promptId`, `transcript` (with realistic STT errors —
seed new ones from real engine output, not invented typos), and optional variant inputs:
`screenTerms[]`, `tokens[]` (literal `⟦SN:…⟧` strings, present in the transcript), `locale`,
`field.singleLine` / `field.plainText`, `appName`, `precedingText`, `selectedText`, `userName`.

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

Findings and ship/no-ship calls per variant land in `agent_notes/prompt_eval/`.
