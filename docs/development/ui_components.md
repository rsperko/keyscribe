# KeyScribe — UI Component Contract

> The committed contract for the SwiftUI/AppKit UI: the semantic roles, the component inventory, the
> shared-behavior invariants, and the user-facing copy vocabulary. It prevents inconsistent controls
> and divergent wording while preserving native macOS behavior. Pair with `ui_design.md`.
>
> **Construction how-to** — each component's anatomy, behavior rules, and the exact shared Swift type
> to reuse, plus the accessibility-identifier mechanics and the build/ship checklists — lives in the
> `keyscribe-ui` build guide (agent-facing). This document stays the source of truth for *what the
> components are and what words to use*; that guide is *how to build them*.

---

## 1. Foundations

Use native macOS controls and SF Symbols first. This defines semantic roles and behavior, not a custom
control kit. Use system semantic colors for the roles below — never hardcode a color as the meaning of a
state. 8-point rhythm within a group, 16–24 between sections; cards only for engines, mode summaries, and
data-boundary summaries, not every row.

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

---

## 2. Component inventory

The blessed set. Reuse the named component; if none fits, add a one-line entry here **before** building
it as a shared type — never a one-off inline pattern. (Anatomy, behavior, and the Swift type: see the
`keyscribe-ui` build guide.)

| Component | Use for |
|---|---|
| Setting row with help | Every non-obvious, consequential, advanced, permission-gated, or privacy-relevant setting — label, one-line result, control, inline `Learn more`. No hover-only tooltip for anything affecting data/privacy/output. |
| Advanced disclosure | Advanced/rare config, collapsed by default. Full header row is the toggle target, chevron trailing; the label names the capability, not the mechanism. |
| Data boundary badge | HUD (cloud rewrite only), mode list, History, connection summaries. Categories stay separate badges, never a vague `Context shared`. |
| Recording level indicator | The HUD recording icon — a level-driven red halo + dot. |
| Mode summary | Mode editor header, list rows, one-shot HUD ack, menu resolution label — name, state, when it runs, boundary summary. Spoken-phrase modes show their actual first phrase. |
| Settings list pane | The master/detail scaffold shared by Speech Models, Vocabulary, AI Services, Modes, and History (`PaneLayout.swift`): a fixed-width (`PaneMetrics.listWidth`) list column of `PaneListRow`s with `PaneBadge` status pills, then a divider and a detail column led by `PaneDetailHeader` and closed by a trailing-red `PaneDeleteButton` where deletion applies. Vocabulary uses Global, enabled modes, and disabled modes as scopes. Speech Models keeps its available-download catalog in the pane; AI Services and Modes keep persistent lists focused on **Your Services** and **Your Modes** and move provider/template discovery into compact add choosers from the bottom `ListActionBar`. History keeps its own transcript row plus its search/stats chrome; the rest share the row. |
| Speech model choice | The Speech Models pane: inspect-only list + a detail pane with one primary lifecycle action; testing/reinstall/delete/dictionary-tuning behind its Advanced disclosure. |
| Processing status | HUD/status states: listening, transcribing, rewriting, inserted, copied instead, fallback, no-speech, error. Never show a raw transcript while a rewrite is pending. |
| Correction action | History + global correction panel: `Add to Dictionary`, `Create Replacement` — pre-filled, showing the resulting rule and its scope. |
| Vocabulary feedback | Settings and the global correction panel: a checkmark status for an entry that already exists, an info status for an update, and `IssueText` for an advisory. |
| Replacement value field | The shared **Use instead** control: a compact field that grows one→a few lines on composers and quick-correction surfaces; Global and mode Settings composers place **Larger editor…** beside the label. Pasted CRLF/lone CR normalize to LF at the boundary. |
| Replacement text editor | The multiline **Use instead** editor with a live `current / 65,536` count: presented as a sheet from Settings composers and inline in saved-rule edit popovers. Add/Update remains the persistence boundary. |
| Editable replacement row | Global and mode scopes in Vocabulary: readable rule text with a bounded one-line Use-instead preview, a roomy edit popover with an inline multiline editor, and direct top-to-bottom reordering with keyboard and VoiceOver alternatives. |
| Shortcut well | Every keyboard/mouse shortcut binding; one control that always shows the current binding with an attached menu (never picker⇄recorder mode-swapping). |
| Keycap glyph | *Displaying* (never editing) a trigger as small physical keys — onboarding trial/playground, the General trigger pointer. |
| Step indicator | The onboarding wizard's progress dots. |
| Permission row | Microphone and Accessibility-dependent features — state, why, what still works without it, `Open System Settings`. |
| Retention/destructive confirmation | Clearing History, retention cuts that delete entries, deleting a model or a mode. Name what is removed and whether it recovers. |

---

## 3. Shared behavior invariants

- **Empty states** explain what the surface is for and offer its primary creation action — never a
  marketing surface (no modes → create/restore starters; no history → inline enable toggle; no AI service
  → explain BYOK + add; no engine → download one).
- **Error vs fallback are distinct.** An error is one sentence + one next action (detail in a copyable
  disclosure). A fallback (`Copied instead of inserted`, `Inserted without rewriting`) is a valid outcome
  that explains *why* and offers the next action — not a failure.
- **Control dependencies preserve visibility and never silently reset a dependent value.** Privacy mode
  locks context off; rewrite-selected-text without a connection says what it will do rather than blocking;
  regex fields appear only when regex is on. Preserve a dependent value for restoration unless retaining it
  could send data unexpectedly — then require an explicit choice.

---

## 4. Copy

### Philosophy

1. **Disclose the boundary where there is a real choice; stay silent where there is not.** Recording and
   transcribing are always on-device with no alternative destination — say `Listening` and `Transcribing`,
   not "Listening locally". Spend the data-boundary signal where data genuinely could leave: the rewrite
   step, mode summaries, History.
2. **One concrete phrase per concept.** `On this Mac` is the canonical data-location phrase. *Exceptions:*
   `on-device` in speech-model metadata, `local-first` in product positioning.
3. **Name things by result, in plain words.** Avoid implementation jargon (BYOK, engine, nonce) in user copy.
4. **One word per concept across surfaces.** Rewrite is "rewrite" everywhere (HUD `Rewriting with {name}`,
   badge `Cloud rewrite`, hatch `without rewriting` — never "Polishing"). Speech is a "model", never "engine".
5. **Never overstate privacy.** Best-effort redaction stays "best-effort"; no "secure/safe/private".

### Vocabulary

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

## 5. Accessibility identifiers

Every load-bearing control carries a stable accessibility identifier so UI automation can address it
exactly. These are **frozen API once shipped** — a rename breaks the harness. All identifiers are
constants in `Sources/KeyScribe/AccessibilityID.swift` (nested by surface, registered in
`AccessibilityID.all`); never a string literal at a call site; dynamic rows interpolate the stable domain
id, never the display name. Wiring mechanics (SwiftUI vs AppKit, the `NSMenuItem` exception) are in the
`keyscribe-ui` build guide.
