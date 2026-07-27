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
| `screen-terms` | identifiers harvested from the case's `precedingText` (the production source) fed through the local exact/single-token stage, then the validTerms + fuzzy-candidate channels |
| `re-anchor` | output-only reminder appended as the system prompt's last line |
| `screen-terms-re-anchor` | both — the reminder's value only shows when term lists lengthen the system prompt |
| `user-name` | the case's `userName` hinted as a valid term |
| `temp-0` | baseline prompt at temperature 0 (connections default to 0.2) |

Graduated 2026-07 (branch made unconditional, option + variant deleted, per the contract below):
**field-affordance rules** (`field-hint`: +2/−0 on the floor after the hard
`field-singleline-listbait` / `field-plaintext-markdownbait` cases landed; note production currently
derives only the single-line fact from AX — `plainText` has no capture source yet, so that half is
prompt-validated but production-unreachable).

**NOT graduated: the bounded-use context contract.** Its earlier +1/−0 sat inside this corpus's own
±1 noise band and was carried by echo probes the "known gaps" section below still calls too easy. The
strict fence therefore stands, and terminology matching rides the curated Dictionary only. The
draft rule is preserved on `reference/screen-context-experiment`; regraduating it needs the harder
adversarial coverage listed under known gaps, not a rerun.

**REJECTED IN PRODUCTION (2026-07): the screen-terms channel does NOT ship.** The variant is kept
here as the evidence for that decision, together with the two regression cases it produced.
`RewriteRequestBuilder` no longer feeds harvested identifiers into validTerms/fuzzyCandidates;
only the user's curated Dictionary does, which is the consented form of the same idea. The local
exact-normalized/single-token stage is unaffected and still ships (provisionally).

**The screen-terms number below supersedes every earlier one** (+8/−0, +5/−0, +5/−2). Those runs were
CONFOUNDED: every case carrying `screenTerms` had no `precedingText`, so the variant was measured
against no screen context at all — while production always sends the harvested text as `<context>` to
both arms. The variant also harvested from the case's `screenTerms` directly, a source production does
not have. Both are fixed: `RewriteEvalVariants` now harvests from `precedingText`, and all 14
term-bearing cases carry realistic screen text that both arms receive identically, so the only
difference is extraction + local correction + the explicit term channels.

Paired results (`--repeat 3`, 40-case corpus with identical context in both arms). **Net positive on
both models, but NOT regression-free, and the failure is model-dependent in opposite directions:**

| model | baseline | screen-terms | Δ cases | fixes | breaks |
|---|---|---|---|---|---|
| gemini-3.1-flash-lite-preview | 99/120 | 108/120 | +4/−1 | recall-chargebee, longterms-recall, token-with-terms, context-casing-usestate | **distractor-usestate-prose** |
| Qwen3-Coder-30B-A3B-Instruct-4bit | 97/120 | 100/120 | +3/−1 | recall-chargebee, recall-fluidaudio, token-with-terms | **code-identifiers** |

Both breaks are the SAME knob seen from opposite ends, and neither is a bug to be fixed. A 2-token
exact-normalized join is offered to the model as a *candidate*, hedged ("where the text clearly refers
to one; otherwise leave the text unchanged"), because `FuzzyCorrector.candidates` cannot tell these two
apart — they are structurally identical:

- `"parse config" → parseConfig` in *"rename the parse config function"* — the win.
- `"use state" → useState` in *"we should use state funds"* — prose corruption.

Gemini adjudicates toward applying: it takes the four recalls **and** writes "useState funds"
(`distractor-usestate-prose`). Qwen adjudicates toward preserving: it keeps the prose intact **and**
leaves `code-identifiers` as "parse config". Making the rule directive would win `code-identifiers` on
Qwen while corrupting prose on *every* model; keeping it hedged does the reverse. **The hedge is
load-bearing — do not "fix" either break by re-wording it without re-running both models on
`distractor-usestate-prose`, which exists precisely to catch that.**

Weigh the two costs asymmetrically when deciding: a missed identifier is invisible to the user, while
corrupted prose is visible, wrong, and inside the atomic insert.

Authoring trap this exposed: **`precedingText` must not share a 3-token window with the expected
output.** `contextEcho` diffs context trigrams against the transcript's, so context that echoes the
output's own phrasing (`"...over to ChargeBee last quarter"` against an output reading `"over to
ChargeBee last month"`) fails legitimate term recall in BOTH arms and silently suppresses the signal.
Two cases hit this on the first paired run. Check new cases with the trigram model before trusting a
run.

Results files record `corpusSHA256` plus a per-variant `variantPromptSHA256` (hash of every case's
actual assembled prompt), so a number can be tied to the exact corpus and the exact prompts —
including variant transforms — that produced it.

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
the case's `precedingText` passes through `ScreenTermExtractor` first (a term production would never
harvest — a plain capitalized surname or brand word with no identifier shape — is dropped;
`recall-postgres-unharvestable` / `recall-surname-unharvestable` keep that limit visible: such terms
belong to the Dictionary channel), the exact/single-token local stage snaps the transcript, and then
verbatim-present terms become validTerms while near-misses only reach the prompt if
`FuzzyCorrector.candidates` pairs them. That pairing is deliberately timid — multi-word windows snap
on an EXACT normalized match only ("charge bee" → ChargeBee), at most 2 tokens wide, and fuzzy
distance (≤2, phonetic-gated) is single-token only ("postgress" → Postgres). So "cloud code" can
never pair to ClaudeCode and a 3-word split can never pair at all — `recall-cloudcode-unpairable`
exists to keep that limit visible in results. When adding term-recall cases, pick mishearings the
channel can actually deliver, or you are measuring nothing.

## Known corpus gaps (fix these before trusting the affected verdicts)

- ~~Field-format cases are too easy.~~ Resolved 2026-07: `field-singleline-listbait` and
  `field-plaintext-markdownbait` fail at baseline (real newlines / markdown into constrained
  fields), which is what let `field-hint` graduate.
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
