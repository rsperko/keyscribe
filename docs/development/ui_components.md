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
| `state.recording` | Active capture state; text/icon label required. Red in a dark appearance, burgundy in a light one (`Color.recording(in:)`) |
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
| Recording level indicator | The HUD recording icon — a level-driven `state.recording` halo + dot. |
| Mode summary | Mode editor header, list rows, one-shot HUD ack, menu resolution label — name, state, when it runs, boundary summary. Spoken-phrase modes show their actual first phrase. |
| Settings list pane | The master/detail scaffold shared by Speech Models, Vocabulary, AI Services, Modes, and History (`PaneLayout.swift`): a fixed-width (`PaneMetrics.listWidth`) list column of `PaneListRow`s with `PaneBadge` status pills, then a divider and a detail column led by `PaneDetailHeader` and closed by a trailing-red `PaneDeleteButton` where deletion applies. Vocabulary uses Global, enabled modes, and disabled modes as scopes. Speech Models keeps its available-download catalog in the pane; AI Services and Modes keep persistent lists focused on **Your Services** and **Your Modes** and move provider/template discovery into compact add choosers from the bottom `ListActionBar`. History keeps its own transcript row plus its search/stats chrome; the rest share the row. |
| Example card | "You say / You get" quoted pair on a quaternary rounded background (`ExampleCard`, `ModesSettingsView.swift`), used by the starter-mode preview; the result label can be renamed. |
| Speech model choice | The Speech Models pane: inspect-only list + a detail pane with one primary lifecycle action; testing/reinstall/delete/dictionary-tuning behind its Advanced disclosure. |
| Processing status | HUD/status states: listening, transcribing, rewriting, inserted, copied instead, fallback, no-speech, error. Never show a raw transcript while a rewrite is pending. |
| Correction action | History + global correction panel: `Add to Dictionary`, `Create Replacement` — pre-filled, showing the resulting rule and its scope. |
| Pane notice | A failed operation or unreadable config file in a Settings pane (`PaneNotice` + `PaneNoticeBanner`, `SettingsComponents.swift`): placed above the pane's Form, ScrollView, or list/detail split, never inside it. A short outcome-first `IssueText` title, one plain line (which file needs fixing, what still works), **Show in Finder** for a file, and a collapsed **Technical details** with the parser's position and message. Its owning model keeps the state; there is no global error manager. |
| Vocabulary feedback | Settings and the global correction panel: a checkmark status for an entry that already exists, an info status for an update, and `IssueText` for an advisory. |
| Replacement value field | The shared **Use instead** control: a compact field that grows one→a few lines on composers and quick-correction surfaces; Global and mode Settings composers place **Open in a larger editor…** directly beneath the field. Pasted CRLF/lone CR normalize to LF at the boundary. |
| Replacement text editor | The multiline **Use instead** editor with a live `current / 65,536` count: presented as a sheet from Settings composers and inline in saved-rule edit popovers. Add/Update remains the persistence boundary. |
| Dictionary row | Words to Recognize: the word and a direct **Mishearings in History…** action when readable saved History exists, with an independent trailing red trash control. When the word and action do not fit side by side, the action moves below the word; the word wraps and remains readable. Opening discovery never writes config. |
| History replacement draft row | `HistoryReplacementDraftRow`: a proposed heard phrase with a checkbox. Unchecked, it shows its discovery context and match count in search; checked, its share of the one combined preview, or a pointer to Combined preview when its changes overlap other phrases. Editing opens in place only through **Edit heard phrase**; a manual row uses the same row with its editor visible and stays inactive while blank. Validation and conflicts remain visible outside disclosures. |
| Editable replacement row | Global and mode scopes in Vocabulary: readable rule text with a bounded one-line Use-instead preview, a roomy edit popover with an inline multiline editor, and direct tie-priority reordering with keyboard and VoiceOver alternatives. |
| Shortcut well | Every keyboard/mouse shortcut binding; one control that always shows the current binding with an attached menu (never picker⇄recorder mode-swapping). |
| App chooser | Every place a user picks an app — a mode's **Where it works** and a voice command place: one menu of running apps with their icons, then **Choose from Applications…** and **Enter Bundle ID…**, with room for a surface's own extra items. |
| Voice command choice | The HUD's numbered question for an ambiguous voice command: a title, one row per candidate (number, name, distinguishing detail), the answer hint naming the real shortcut, and Cancel. Rows are clickable but the waiting panel never takes key focus. |
| Heard excerpt | `Heard “…”` under an unrecognized voice command or choice answer: the raw transcript, whitespace folded, at most two lines. The only HUD text that truncates — every other explanation still wraps. Hidden for a password-field or unconfirmed target. |
| Voice command notice | One warning per kind of entry, each written for what that kind can do, shown expanded on every new entry and collapsed when editing. A separate notice about recognition mistakes, window visibility, and scripts and Shortcuts run by voice gates first enabling Voice Commands and is remembered for each configuration. |
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
| `compatibility mode` (Apple Dictation standing in for Apple Speech) | fallback, legacy, older model, degraded |
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
