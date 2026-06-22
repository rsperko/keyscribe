# KeyScribe — Engineering & Product Principles

> Established early, maintained consistently. These govern every design and implementation
> decision. When a choice conflicts with a principle, the principle wins or the deviation is
> documented and justified. Companion to `design.md` and `roadmap.md`.

---

## 1. Insanely memory & CPU efficient
Efficiency is a **measured feature**, not an afterthought. We will make many optimization
passes to drive memory and CPU toward optimal.
- Treat memory and CPU as budgets with targets per subsystem (idle, listening, transcribing,
  rewriting). Measure before and after every milestone.
- Idle cost should be near-zero — a menu-bar app that's invisible until invoked.
- Repeated optimization passes are expected and planned, not a sign something went wrong.

## 2. No hacks — fully data-driven, zero app/mode identity in source
The system contains **no hardcoded app bundles and no behavior special-cased to a specific
app or mode.**
- No `if app == "Slack"`, no shipped per-app presets, no `if mode == "email"` branches.
- A **user** entering a bundle ID into their own mode constraint is fine — that is user data
  flowing through a generic engine. The prohibition is on *us* baking identity into code.
- A Mode is just a named bag of config the generic pipeline executes. The pipeline must not
  branch on a mode's name or purpose. Adding a new mode is adding data, never code.

## 3. Simple architecture
Prefer the simplest structure that works. Inline → method → class → module → abstraction,
and only when a real pattern emerges. No pass-through layers, no single-implementation
abstractions, no speculative indirection.

## 4. UX-first — progressive disclosure is THE key
The product is judged by how it feels, not how powerful it is on paper.
- Default path is dead simple: download a model → set a hotkey → talk.
- Every power feature (modes, pipeline stages, insertion control, BYOK rewrite) ships, but
  lives behind Advanced surfaces that never burden a casual user.
- A new power feature is not "done" if it complicates the default path. Simple by default,
  powerful on demand.

## 5. Best-of-breed per feature
For **any** feature we add, first research the best products that do it and build the best
version — ideas come from anywhere, not just our category.
- Example: BYOK / LLM-connection UX should be modeled on whoever does it most intuitively
  (e.g. LibreChat's connection management), not necessarily a dictation competitor.
- Each feature's milestone includes an explicit "who does this best, and why" research step
  before implementation. Don't reinvent; adopt and improve the strongest existing design.

## 6. Consistent visual language + always-accessible help
Establish a visual language early and maintain it everywhere.
- Settings panels are clear and consistent; controls behave the same across panels.
- Every feature has easy, inline access to help — the user never has to leave the app to
  understand what a setting does.
- Visual consistency is a reviewable property, not a matter of taste-of-the-day.

## 7. YAGNI
Build what is needed now. No speculative features, options, or extensibility "for later."
If we don't need it for the current milestone, we don't build it. (See parked items in
`roadmap.md` — they stay parked until needed.)

## 8. DRY
One source of truth for every behavior and value. The pipeline-stage model exists partly to
serve this: new behavior is a new stage, not copy-pasted special handling. No duplicated
logic across engines, modes, or stages.

## 9. TDD — red to green
Write a failing test that defines the behavior, then make it pass.
- **Strict red→green for all pure logic:** the pipeline and stage ordering, replacements /
  regex, redaction & verbatim token-fencing, mode resolution, model-lifecycle state. This
  logic lives behind thin protocol seams so it is testable without the OS.
- **Thin adapters + integration tests for the system edges:** AVAudioEngine capture,
  Accessibility insertion, global hotkeys, the SwiftUI layer — where a unit test would only
  mock the OS, we keep the adapter thin and verify it with integration tests.
- Not applicable to config, migrations, or pure refactors with no behavior change.

---

## How these interact
- **2 + 8** reinforce each other: a data-driven, branch-free engine is also the DRY one.
- **4 + 6** are the UX spine: progressive disclosure delivered through a consistent,
  self-documenting visual language.
- **1 + 3 + 7** keep the system small and fast: simple architecture and YAGNI are what make
  "insanely efficient" achievable and keep many optimization passes tractable.
- **5 + 9** are the build loop: research the best version, then TDD it into existence.
