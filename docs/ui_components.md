# KeyScribe — UI Component Contract

> A small behavioral widget library for the SwiftUI/AppKit implementation. It prevents
> inconsistent controls while preserving native macOS behavior. Pair with `ui_design.md`.

---

## 1. Foundations

Use native macOS controls and SF Symbols first. This library defines semantic roles and behavior,
not a custom control kit.

### Tokens

| Token | Use |
|---|---|
| `content.primary` | Main labels, current mode, final outcomes |
| `content.secondary` | Explanations, metadata, examples |
| `content.tertiary` | Supporting timestamps and inactive descriptions |
| `surface.settings` | Standard grouped settings background |
| `state.recording` | Active capture state; text/icon label required |
| `state.processing` | Transcribing or rewriting; neutral, not success-colored |
| `state.success` | Confirmed insertion only |
| `state.warning` | Best-effort privacy, focus fallback, or user attention |
| `state.error` | Actionable failure |
| `boundary.local` | Entire operation remains on the Mac |
| `boundary.cloud` | A named cloud connection processes text |
| `boundary.redaction` | Cloud rewrite with best-effort redaction |
| `boundary.context` | A named context category is shared |

Use system semantic colors for these roles. Do not hardcode colors as the meaning of a state.

### Spacing and hierarchy

- Use standard macOS control heights and target sizes.
- Use an 8-point rhythm for related elements and 16–24 points between sections.
- Keep a settings row’s label, current value, and first-line explanation visible without
  expansion whenever practical.
- Do not make all rows cards. Cards are reserved for engines, mode summaries, and data-boundary
  summaries where a short block of related state needs scanning.

---

## 2. Core components

### Setting row with help

**Use for:** every non-obvious, consequential, advanced, permission-gated, or privacy-relevant
setting.

**Anatomy:** label, one-line result, control/current value, `Learn more` disclosure, optional
dependency reason, optional example.

**Behavior:**

- `Learn more` expands inline and remains expanded until the user closes it or leaves the page.
- The expanded content includes the benefit, limit, and prerequisite. It can link to a nearby
  related setting but never requires an external help site.
- If disabled, leave the row visible and show the dependency reason in place.
- Provide an accessible label that includes the one-line result; disclosure state is announced.

**Do not use:** a bare circled-info icon, hover-only tooltip, or long explanatory paragraph
above a screen.

### Advanced disclosure

**Use for:** regex, connection parameters, model eviction, config file access,
and technical prompt behavior.

**Behavior:**

- Collapsed by default.
- Its label names the capability, not its implementation: `Advanced model behavior`, not
  `Eviction configuration` unless eviction is the only capability.
- Show a one-line consequence before expansion when the setting affects output or data flow.
- Expansion does not alter values or enable functionality by itself.
- **The entire header row is the toggle target** — clicking anywhere on the label, not only the
  chevron, expands and collapses it. The hit area spans the full row width (`contentShape`), and
  the chevron sits at the trailing edge. Never ship a disclosure whose label text is inert while
  only the triangle responds. Every disclosure uses the shared `DisclosureSection` (it owns this
  behavior); the platform's bare `DisclosureGroup(_:)` does not satisfy this rule and must not be
  used.

### Data boundary badge

**Use for:** the HUD, mode list, History, and connection summaries.

> **Where each surface renders these as a badge vs plain text:** **History** renders the full set,
> including `On this Mac`, as badges (`HistoryEntry.dataBoundaryLabels`). The **HUD** shows boundary
> badges **only during a cloud rewrite** — a fully-local dictation shows no boundary badge (it has no
> Rewriting state). The **mode list / mode summary** states the local-vs-cloud boundary as plain
> summary text (“Stays on this Mac” / “On this Mac”), not as a capsule badge.

| Badge | Meaning | Required companion text when expanded |
|---|---|---|
| `On this Mac` | No cloud rewrite is used for this operation. | “Speech recognition and text processing stay on this Mac.” |
| `Cloud rewrite` | The named connection processes text. | Name the connection and model. |
| `Best-effort redaction` | Recognizable sensitive spans are tokenized before cloud rewrite. | “Pattern matching can miss content. Context is off.” |
| `App shared` | App identity is sent with the rewrite. (URL is never sent — it is a local routing key only.) | State this exact category. |
| `Selected text shared` | Selection is sent with the rewrite. | State this exact category. |

**Behavior:** labels are never shortened to an unexplained shield or lock. Multiple context
categories remain separate badges; do not collapse them into a vague `Context shared` label.

### Mode summary

**Use for:** the top of a mode editor, mode list rows, one-shot HUD acknowledgement, and menu
automatic-resolution label.

**Contents:** name, enabled/disabled state, when it runs, processing/data-boundary summary,
and result behavior where it differs from normal insertion.

**Rules:** use user-facing phrases such as `Used in Safari` or `Triggered by Fn`; hide internal
terms such as bundle ID and raw regex behind Advanced.

### Engine card

**Use for:** Speech Models.

**Contents:** engine name, active state, on-device badge, language capability, installed/download
state, size, and a single primary action.

**Behavior:** exactly one card can be active. Progress is attached to the affected card. A
downloaded engine is not implicitly selected after install.

### Processing status

**Use for:** HUD and status rows.

**States:** listening, transcribing, rewriting, inserted, copied instead, fallback (inserted or
copied without rewriting), error.

**Rules:**

- Listening shows a live input-level indicator and concise text.
- Processing uses neutral movement; success appears only after actual insertion.
- Cloud processing identifies the named connection and adjacent boundary badges.
- It does not show a raw transcript while a rewrite that may materially alter it is pending.

### Correction action

**Use for:** History and the global correction panel.

**Actions:** `Add to Dictionary` and `Create Replacement`.

**Behavior:** pre-fill source text, show the resulting rule before save, and state global versus
mode-local scope. Do not make the user reconstruct a dictation from scratch.

### Permission row

**Use for:** microphone, and Accessibility-dependent features (modifier-key trigger detection +
paste/post-event).

**Contents:** capability name, current authorization state, why KeyScribe needs it, what still
works without it, and `Open System Settings`.

**Behavior:** it is explanatory before the OS prompt and actionable after denial. Never label a
permission merely `Required` without the affected feature.

### Retention/destructive confirmation

**Use for:** clearing History, lowering retention when it deletes entries, deleting a model,
and deleting a mode.

**Behavior:** name what is removed and whether it can be recovered. Do not require confirmation
for ordinary reversible setting changes. Deleting the **default mode** is allowed, not blocked: the
confirmation says another mode will become the default, and on delete the default is reassigned to
a remaining mode so it never dangles.

---

## 3. Shared behavior patterns

### Empty states

An empty state explains what the surface is for and offers its primary creation action:

- no modes: create a mode or restore the generic starter modes;
- no history: explain that only future dictations appear and link to history settings;
- no AI services: explain BYOK and add a connection;
- no downloaded engine: choose and download an on-device speech model.

Do not make empty states marketing surfaces.

### Errors and fallback

Errors use one sentence that states the failed operation, followed by one next action. Technical
details are available in a disclosure and can be copied for diagnostics.

Fallback is distinct from error. `Copied instead of inserted` and `Inserted without rewriting`
are valid outcomes that must explain why they occurred and offer the relevant next action.

### Control dependencies

When one option changes another, preserve visibility and explain the dependency. Examples:

- privacy mode locks context off;
- rewrite selected text recommends an AI connection — without one it replaces the selection with
  the literal dictation, so the editor says what it will do rather than blocking the mode;
- TOML-only insertion escapes remain visible as read-only notes when active, rather than becoming
  normal Settings controls;
- regular-expression substitution fields appear only when regex mode is enabled.

Never silently reset a dependent user value. Preserve it for restoration when the dependency is
removed unless retaining it could send data unexpectedly; in that case require explicit choice.

### Copy philosophy

Five rules govern user-facing copy:

1. **Disclose the boundary where there is a real choice; stay silent where there is not.**
   Recording and transcribing are always on-device with no alternative destination, so they carry
   no location words — say `Listening` and `Transcribing`, not "Listening locally". Spend the
   data-boundary signal where data genuinely could leave: the rewrite step, mode summaries, History.
2. **One concrete phrase per concept.** `On this Mac` is the canonical data-location phrase. Do not
   mix in "locally", "on your Mac", or "on this device". *Exceptions:* `on-device` in speech-model
   metadata (a compact capability descriptor) and `local-first` in product positioning.
3. **Name things by result, in plain words.** The rewrite escape hatch inserts locally-processed
   text *minus the AI pass* (not the raw recognizer output), so it is `Insert without rewriting`,
   never "local transcript". Avoid implementation jargon (BYOK, engine, nonce) in user copy.
4. **One word per concept across surfaces.** Rewrite is "rewrite" everywhere (the HUD says
   `Rewriting with {name}`, the badge says `Cloud rewrite`, the hatch says `without rewriting` —
   never "Polishing"). Speech is a "model" everywhere in user copy, never "engine".
5. **Never overstate privacy.** Best-effort redaction stays "best-effort"; no "secure/safe/private".

### Copy vocabulary

Use these terms consistently:

| Prefer | Avoid |
|---|---|
| `On this Mac` | offline-only, private, secure |
| `Listening` / `Transcribing` (no location word) | listening locally, transcribing locally |
| `On-device speech` (idle status) | local transcription |
| `Rewriting with {name}` | Polishing, processing |
| `Cloud rewrite` | AI mode, remote magic |
| `No cloud rewrite` (rewrite off) | off, don't use AI |
| `Best-effort redaction` | protected, anonymized, safe |
| `Insert without rewriting` | local transcript (implies raw STT), bypass, raw fallback |
| `Copied instead of inserted` | failed paste |
| `speech model` / `model` | engine (in user copy) |
| `Rewrite selected text` | edit mode, work on selection |
| `Reusable writing instruction` | prompt fragment |

---

## 4. Implementation checklist

For each new screen or control, establish:

1. Its component type from this document.
2. Its default and advanced visibility.
3. Its empty, loading, disabled, error, and success states.
4. Its keyboard and VoiceOver behavior.
5. Its privacy/data-boundary wording, if it reads, stores, or transmits user content.

If no existing component fits, add the smallest new component to this document before creating
a one-off UI pattern.
