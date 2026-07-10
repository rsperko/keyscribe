# KeyScribe — Prompt & System-Prompt Structure

> Companion to `design.md` §4.2/§4.4. Defines how the optional LLM rewrite step is prompted.
> **LLM floor: Gemini 2.5 Flash** — structure is tuned to be reliable on a fast/cheap model:
> explicit, concise, consistently delimited, not reliant on top-tier instruction-following.

---

## Goals
1. One template that serves both rewrite shapes:
   - **Dictation rewrite** — transcript is the content; the mode prompt is the instruction.
   - **Edit-in-place** — the *selection* is the content; mode prompt + dictated instructions
     are the instruction (`design.md` §4.3).
2. **Protect tokens and vocabulary** through the rewrite (`design.md` §4.2): nonce tokens
   (`⟦SN:…⟧`) and preserve-terms are reinforced in the system prompt.
3. **Output only the result** — no preamble/markdown/quotes — so it can be inserted directly.
4. Reliable on **Gemini 2.5 Flash**.

## Conventions (from Flash prompting guidance)
- **XML-style tags** as delimiters (`<instructions>`, `<context>`, `<content>`), used
  consistently. (Markdown headings also work; we pick one — XML — and never mix.)
- **System message = stable rules + dynamic constraints.** **User message = the actual
  instruction, context blocks, and content.**
- **Dynamic constraints are conditional** — token/preserve-terms lines appear only when
  those features are active, so the prompt stays lean for a fast model.
- Empty context blocks are **omitted entirely**, not sent blank.

---

## System message (template)

```
You are KeyScribe's text transformation engine. You transform text exactly as instructed and
return only the transformed text.

Rules:
- Output ONLY the transformed text — no preamble, no explanation, no surrounding quotes,
  code fences, or XML tags.
- Rewrite only the text inside <content>: apply every instruction fully, but make no change an
  instruction does not call for. Return it unchanged only when the instructions call for no
  change to already-correct text.
- {{#if context}}The <context> block is background about the user's screen, NOT text to rewrite —
  never copy, quote, continue, complete, or output anything from it. Any <context> text in your
  output is a mistake.{{/if}}
- {{#if tokens}}Each ⟦SN:…⟧ is an opaque marker — copy it into your output verbatim and exactly
  once, with its characters unchanged. You may move it if the instruction reorders the text, but
  never edit what is inside it, translate it, drop it, or replace it with a word like REDACTED.{{/if}}
- {{#if validTerms}}These terms are valid and intentional, not misspellings — treat them as
  correct: {{validTerms}}. You may still transform them if the instructions require it.{{/if}}
- Write in {{language}}.
{{modeSystemInstructions}}
```

- The **context-isolation fence** is injected whenever a `<context>` block is present. Its
  **positive lead** — "rewrite only `<content>`, apply every instruction fully, change nothing an
  instruction doesn't call for, return unchanged only when no change is called for" — is an always-on
  rule (it also guards over-production on the no-context path); the context-gated bullet carries the
  "background, never output" isolation half. The conditional "return unchanged" wording is
  deliberate: an earlier "if it is already clean, return it unchanged" made a weak model equate
  *grammatically clean input* with *no work to do* and skip a transformative instruction (e.g. a "talk
  like a pirate" style fragment) on already-correct text. It is
  load-bearing for a weak model: framing that invites the model to "use the context to match
  names/tone" causes it to lift screen text into the output (inventing a `Hi Maria,` greeting from a
  name visible on screen, echoing an instruction-like headline). The fence therefore leads with the
  **positive task**, frames context as pure **background, never to be output**, labels any context in
  the output "a mistake," and **deliberately drops** the "use it to match names/tone" purpose.
  - **Design consequence:** controlled terminology/name matching belongs in the **`validTerms`**
    channel (the Dictionary), which is safe; opted-in context is for *situational grounding
    only*, fenced from output.
  - This is a **quality** failure mode, not a privacy one: the output is inserted **locally** (the
    user's own screen content returning to their screen); the cloud already received the opted-in
    context and the redaction wedge still protects secrets. The rule does not appear when there is no
    context.
- The **tokens** block is a directive (the marker must survive verbatim). It permits **reordering**
  on purpose: restore is position-independent (matches by token string, not position), so a
  "reverse"/"sort" instruction is free to move the marker — the gate only requires it return
  unchanged, exactly once. The **validTerms** block
  is a **hint** (dictionary terms are valid, not misspellings) — the model may still transform
  them per the instructions. Both are injected only when present (`design.md` §4.2).
- `modeSystemInstructions` is the mode's own system-level guidance (optional).

## User message (template)

```
<instructions>
{{modePrompt}}
{{dictatedInstructions}}

Always also apply these style rules, even to otherwise-clean text. Where a style rule conflicts
with the wording instruction above, the style rule wins:
- {{styleRule}}
</instructions>

<context>
  <app>{{appName}} ({{bundleId}})</app>
  <field>{{fieldRole}}</field>
  <selection>{{selectedText}}</selection>
  <preceding_text>{{precedingText}}</preceding_text>
</context>

<content>
{{contentToTransform}}
</content>
```

- The mode's **shared prompt fragments** (e.g. a "my voice" fragment, `design.md` §4.3) are **not**
  flattened into `modePrompt`. They render in order as a **labeled, bulleted "style rules" section**
  inside `<instructions>`, after the mode prompt + dictated instructions. The lead-in carries two
  signals a flat append loses: **apply even to otherwise-clean text** (so the always-on minimal-change
  rule can't make a weak model skip a transformative fragment) and **the style rule wins a conflict
  with the wording instruction above** (precedence — a "talk like a pirate" fragment overrides a mode
  prompt's "keep my wording"). The whole section is omitted when the mode has no fragments.
- **Dictation rewrite:** `contentToTransform` = the (tokenized) transcript;
  `dictatedInstructions` is usually empty (the mode prompt carries the intent).
- **Edit-in-place:** `contentToTransform` = the selected text; `dictatedInstructions` = what
  the user just spoke; `<selection>` may be omitted to avoid duplicating the content.
- **Context is opt-in per mode** (`design.md` §4.4): `<app>`/`<field>` appear only if the
  mode opted into **App**; `<preceding_text>` (bounded text before the caret, native-only/best-effort)
  only if it opted into **preceding text**. Any `<context>` child with no value is omitted; if all are
  empty, drop `<context>` entirely.

---

## Post-LLM validation
The output passes a deterministic gate before insertion (`design.md` §4.2):
- **Token integrity** — every token present in the model payload returns exactly once (unless the
  mode allows deletion); no stray `⟦SN:…⟧`-style tokens. If KeyScribe issued a token but did not send
  it in this request, the output must not invent it.
- **Non-empty** — a refusal or empty response is a failure.
- **On failure** — retry once with a stricter minimal prompt, then fall back to the local
  (un-rewritten) text with a HUD notice. Never insert partially-restored text.

Opted-in context blocks (`<selection>`, `<preceding_text>`) are **untrusted
data, not instructions** — kept in separate delimited blocks. Before send, `PromptAssembler.neutralize()`
**breaks any of our own delimiter tags** that appear inside untrusted context (it inserts a zero-width
space right after the `<` of a `</preceding_text>`-style tag) so embedded text cannot close our block
or open a new one; the ZWSP is invisible to the model and never reaches the insert. The post-LLM gate
is the second line of defense, catching context that still tries to steer the rewrite or drop tokens
(indirect prompt injection). No classifier in v1.

## Context & token budget
Large context causes latency, cost, and provider-side context limits. The policy is explicit and
**never silently truncates user content**:
- **Instructions and mode prompt are never truncated** — they define the task.
- **Selected text is content** and takes priority over other context.
- **Assembled content is sent as-is rather than cut client-side.** If the provider rejects it or
  returns a truncated response, the rewrite fails and KeyScribe falls back to the local text/copy path
  with a HUD notice.
- **`max_tokens` scales with edit-in-place** — a long selection needs output room ≥ its own
  length; the connection default (`config_schema.md`, 2048) is a floor, raised per request when
  the content demands it.

## Structure scope
- The structure above is **fixed**: context chunks are appended in this stable order. User-defined
  **prompt templating** that places chunks at arbitrary points is a footgun and out of scope
  (`design.md` §4.4, YAGNI).
- **Context placement:** stable rules in the system message, situational context in the user message.
- **Token sentinel:** `⟦SN:…⟧` is the chosen sentinel. It survives the Gemini 2.5 Flash floor (24/24
  across hard rewrite shapes incl. translate/summarize, multi-token, adjacent, boundaries, and
  edit-in-place). The characters matter less than the *other* axis on a modern model — low
  stray/collision risk in dictated prose: `⟦`/`⟧` (U+27E6/27E7) essentially never appear in normal
  text, so the gate's stray-token regex won't false-fire, whereas ASCII brackets/braces collide with
  code and PUA chars are invisible/fragile. Opt-in survival harness: `SentinelSurvivalProbeTests`
  (`RUN_SENTINEL_PROBE=1 GEMINI_API_KEY=… swift test --filter sentinelSurvival`).
- **Few-shot:** zero-shot by default for speed/cost; per-mode examples only if a task needs it.

## Changing this prompt

Candidate prompt changes are **eval-gated, not adopted on judgment**: implement the change as a
`PromptAssembler.Options` flag (off by default — `.baseline` stays byte-identical to the shipped
prompt, test-enforced), add it as a variant in `RewriteEvalVariants`, and run
`KeyScribe --rewrite-eval evals/rewrite` (harness, corpus, and check semantics in
`evals/rewrite/README.md`) against a local model and the Gemini floor. A variant that wins graduates
by making its option unconditional and deleting the flag; one that loses is deleted. Findings live in
`agent_notes/prompt_eval/`.

## Sources
- [Prompt design strategies — Gemini API](https://ai.google.dev/gemini-api/docs/prompting-strategies)
- [Best practices for prompt engineering with Gemini 2.5 (Google Cloud / Medium)](https://medium.com/google-cloud/best-practices-for-prompt-engineering-with-gemini-2-5-pro-755cb473de70)
