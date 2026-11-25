# Spoken summary eval

Checks the summary Read Agent Replies Aloud makes of a long agent reply. Each case in `cases.json` goes through
the same request, prompt and clean-up the app uses, and the text that would be spoken is checked.

```bash
KeyScribe --spoken-eval evals/spoken --connection <id> --repeat 3
# a candidate prompt, without a rebuild:
#   --prompt /path/to/prompt.txt
```

A case has an `id`, the `reply`, and optionally `asked`, the dictation the reply came right after. `mentions` lists
patterns that must all be spoken, such as what failed and that it failed, so a summary of the opposite outcome fails. `avoids` lists patterns none
of which may be spoken, such as the request repeated back as if it were part of the answer, or a failure invented for a
reply where nothing failed. Every case also fails when a `#` number or a run of five or more digits is spoken. Patterns
are case-insensitive regular expressions, checked when the cases are read.

Seed new cases from real replies. A model's results vary from one run to the next, and attempts inside one run are
often the same, so compare prompts over several runs.

## Results

As measured on 2026-11-24, three runs of three attempts each, temperature 0.2, on local models:

| Model | Prompt before 2026-11-24 | Current prompt |
|---|---|---|
| Qwen3-Coder-30B-A3B 4-bit | buried CI failure 1/9, failed migration 5/9, others 9/9 | every case 9/9 |
| Gemma 4 26B A4B 4-bit | every case 9/9 | every case 9/9 |
| Qwen2.5 7B 4-bit | buried CI failure 4/9, failed migration 1/9 | buried CI failure 2/9, request repeated in 6/9 for a reply where nothing failed, others 9/9 |

The current prompt passed again with the stricter cases (every `mentions` pattern required), on the same two larger
models, 2026-11-24. The earlier column ran without today's clean-up, so a migration's name read out counted against it. A 7B model
follows neither prompt reliably.
