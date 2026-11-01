# Writing docs

Read before writing or editing any doc, including `AGENTS.md` and these guides.

- **Public docs are for users first.** `README.md`, `FAQ.md`, `PRIVACY.md`, and
  `docs/getting_started.md` should explain outcomes, setup, and tradeoffs in plain language.
  Implementation details, schemas, benchmark methodology, prompt internals, architecture, and
  contributor-only rationale belong under `docs/reference/` or `docs/development/`, with links from
  user docs only when they help an advanced reader continue.
- **Docs state rules, never tallies.** Nothing in this file, `docs/`, `README.md`, `FAQ.md`,
  `PRIVACY.md`, or `BUILD.md` may pin a count or an exhaustive list of code entities: no "ships 8
  models across 4 engine kinds", no "the only two engines that bias", no "exactly three network
  situations", no roster that has to match an `allCases`, a catalog, an enum, or a directory listing.
  **Name the source of truth and let the reader read it** (`SpeechModelCatalog.all`, `Log.swift`,
  `SettingsDestination`, `ls corpus/`), or state the rule the tally was standing in for. Naming a
  symbol that exists is fine; counting them is not. A tally is owned by nobody, goes stale the first
  time the code changes, and goes stale **silently** — every instance found so far had already drifted
  between two commits, including a "single flag" claim in a file whose own next section documents the
  second flag.
  **Measurements are the exception and they stay.** WER, latency, RTF, thresholds, budgets, memory,
  and "measured over N clips / N layouts" are evidence, not inventory — deleting the number destroys
  the claim. Anchor them in time instead ("as measured, `<date>`"). Apply the same care to a claim
  that something is *unbuilt*: building it is precisely the change that will not touch the doc, so
  say what to check rather than asserting the absence.
