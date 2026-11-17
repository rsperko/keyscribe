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
| Setting row with help | Every non-obvious, consequential, advanced, permission-gated, or privacy-relevant setting — label, one-line result, control, a visible caption with the brief explanation (one or two short sentences: effect, limit, data boundary), and, when reference is needed, a named help-dialog link under it. Never an expandable `Learn more`. A wide control may sit below its label to preserve both in narrow panes. An error marks the label with the shared red dot. The label and result are grouped for accessibility without replacing child action names. No hover-only tooltip for anything affecting data/privacy/output. |
| Help dialog | Instructions, examples, command lists, troubleshooting, and detailed data flow opened on demand (`HelpLink` → `HelpDialog`, `SettingsComponents.swift`; content as a `HelpTopic` or `HelpSection`s, spoken phrases as `HelpPhraseRow`s): a link naming what it opens (**What can I say?**, **How {agent} connects**, **About reading replies aloud**, **What History keeps**), then a sheet with a clear title, short headed sections of selectable text that scroll when long, and **Done** (Return or Escape). It never holds a setting and never sends the reader to another closed dialog. |
| Advanced disclosure | Advanced/rare config, collapsed by default. Full header row is the toggle target, chevron trailing; the label names the capability, not the mechanism. |
| Data boundary badge | HUD (cloud rewrite only), mode list, History, connection summaries. Categories stay separate badges, never a vague `Context shared`. |
| Recording level indicator | The HUD recording icon — a level-driven `state.recording` halo + dot. |
| Spoken help | The HUD's “What you can say” state: neutral `info.circle`, the mode name, phrase rows (the phrase, then what it does and any note) in one scrolling list, mode suffixes last under “End your dictation with”, and a close button. Rows come only from `SpokenHelp`, which Settings' “What you can say” sections share. |
| Speaking panel | A spoken reply being read (`SpeakingHUDController`, `HUD/SpeakingHUDController.swift`): the HUD card (`HUDCardBackground`) at the dictation HUD's normal width in both states, with a steady rounded-square stop button on a filled rounded-square halo that pulses in opacity only (static under Reduce Motion), the conversation name, "Speaking · Esc stops playback" ("Text only · Esc closes", with close and copy buttons and the text expanded, when the shared voice is Off — text only), and a trailing chevron (tooltip and label "Show spoken text" / "Hide spoken text") that adds the exact spoken text. The text changes only the height and opens away from the anchored edge, so the stop button never moves (`SpeakingHUDLayout.placement`). Never key; Escape is claimed only while it shows. |
| HUD position picker | **Move HUD…** (`HUDPositionPickerController`, `HUD/HUDPositionPicker.swift`): a light dim on the HUD's display only, with one compact rounded button per `HUDAnchor` at the frame `HUDPositionPickerLayout` gives it, named by `HUDAnchor.positionName`. A marker has a material fill, a visible border and a `content.primary` label at rest; hover strengthens fill and border, a press fills with the accent color, keyboard focus adds an outer accent ring, and the saved position adds a checkmark, an accent border and tint, and the selected trait. The centered instructions are plain white text with a shadow over a soft dark gradient that extends past the text and has no edge, never a card or a button. No animation. |
| Mode summary | Mode editor header, list rows, one-shot HUD ack, menu resolution label — name, state, when it runs, boundary summary. Spoken-phrase modes show their actual first phrase. |
| Settings list pane | The master/detail scaffold shared by Speech Models, Vocabulary, AI Services, Modes, and History (`PaneLayout.swift`): a fixed-width (`PaneMetrics.listWidth`) list column of `PaneListRow`s with `PaneBadge` status pills, then a divider and a detail column led by `PaneDetailHeader` and closed by a trailing-red `PaneDeleteButton` where deletion applies. Vocabulary uses Global, shared vocabularies, enabled modes, and disabled modes as scopes. Speech Models keeps its available-download catalog in the pane; AI Services and Modes keep persistent lists focused on **Your Services** and **Your Modes** and move provider/template discovery into compact add choosers from the bottom `ListActionBar`. History keeps its own transcript row plus its search/stats chrome; the rest share the row. |
| Example card | "You say / You get" quoted pair on a quaternary rounded background (`ExampleCard`, `ModesSettingsView.swift`), used by the starter-mode preview; the result label can be renamed. |
| Speech model choice | The Speech Models pane: inspect-only list + a detail pane with one primary lifecycle action; testing/reinstall/delete/dictionary-tuning behind its Advanced disclosure. |
| Processing status | HUD/status states: listening, transcribing, rewriting, inserted, copied instead, fallback, no-speech, error. Never show a raw transcript while a rewrite is pending. |
| Action confirmation | A secondary caption confirming what a button just did (copied, saved, exported), cleared after a few seconds. It sits in the pane's bottom footer, leading the trailing actions, in a slot that always reserves its lines, so appearing and clearing moves nothing. Never inside a button row, where it squeezes the buttons into truncated labels, and never on a line that appears with it, which shifts the whole pane. |
| Correction action | History + global correction panel: `Add to Dictionary`, `Create Replacement` — pre-filled, showing the resulting rule and its scope. |
| Pane notice | A failed operation or unreadable config file in a Settings pane (`PaneNotice` + `PaneNoticeBanner`, `SettingsComponents.swift`): placed above the pane's Form, ScrollView, or list/detail split, never inside it. A short outcome-first `IssueText` title, one plain line (which file needs fixing, what still works), **Show in Finder** for a file, and a collapsed **Technical details** with the parser's position and message. Its owning model keeps the state; there is no global error manager. |
| Wrapping action row | A row of labeled buttons that wraps onto further rows when there is no room, keeping every name whole (`WrapLayout`, `WrapLayout.swift`). Use it where a pane can be narrower than its actions; never let a button label truncate. |
| Copyable value | A path or identifier shown as caption text that copies on click (`CopyableValue`, `SettingsComponents.swift`): the value, then a copy glyph that briefly becomes a checkmark without moving the row. The tooltip is “Copy <what>: <value>” (“Copied <value>” after), and assistive technology hears “Copy <what> for <owner>” with the value. Use it for supporting values a user pastes elsewhere; a primary result copy stays a labeled control (History's **Copy** menu). |
| Vocabulary feedback | Settings and the global correction panel: a checkmark status for an entry that already exists, an info status for an update, and `IssueText` for an advisory. |
| Rule preview | A replacement rule being written (`RulePreviewSection` + `RuleScopePicker`, `Settings/RulePreviewSection.swift`): one behaviour sentence when the rule is not a word fix, advisories for a dropped Return (with **Only Match When Said Alone**) and for matches inside words (with **Match Whole Words…** showing the new pattern before it is used), **Try a sentence**, and the rule replayed over recent History behind one collapsed summary line. The scope override (`RuleScopePicker`) lives under **Advanced**. Used by the composer and the Edit Replacement sheet. |
| Rule check | **Check Rules Against History** in Automatic Replacements (`RuleAuditSection`): every rule in the scope replayed with today's rules, listing the ones that misbehave with one example each. |
| Replacement value field | The shared **Use instead** control: a compact field that grows one→a few lines on composers and quick-correction surfaces; Global and mode Settings composers place **Open in a larger editor…** directly beneath the field. Pasted CRLF/lone CR normalize to LF at the boundary. |
| Replacement text editor | The multiline **Use instead** editor with a live `current / 65,536` count: presented as a sheet from Settings composers and inline in saved-rule edit popovers. Add/Update remains the persistence boundary. |
| Dictionary row | Words to Recognize: the word, the spellings it already corrects beneath it (**Also corrects Cryden, Crayton** — literal replacements in effect there whose output is exactly the word), and a direct **Review mishearings…** action when readable saved History exists, with an independent trailing red trash control. When the word and action do not fit side by side, the action moves below the word; the word wraps and remains readable. Opening discovery never writes config. |
| History replacement draft row | `HistoryReplacementDraftRow`: a proposed heard phrase with a checkbox. Unchecked, it shows its discovery context and match count in search; checked, its share of the one combined preview, or a pointer to Combined preview when its changes overlap other phrases. Editing opens in place only through **Edit heard phrase**; a manual row uses the same row with its editor visible and stays inactive while blank. Validation and conflicts remain visible outside disclosures. |
| Editable replacement row | Global and mode scopes in Vocabulary: readable rule text with a bounded one-line Use-instead preview, a roomy edit popover with an inline multiline editor, and direct tie-priority reordering with keyboard and VoiceOver alternatives. |
| Shortcut well | Every keyboard/mouse shortcut binding; one control that always shows the current binding with an attached menu (never picker⇄recorder mode-swapping). |
| App chooser | Every place a user picks an app — a mode's **Where it works** and a voice command place: one menu of running apps with their icons, then **Choose from Applications…** and **Enter Bundle ID…**, with room for a surface's own extra items. |
| Voice command choice | The HUD's numbered question for an ambiguous voice command: a title, one row per candidate (number, name, distinguishing detail), the answer hint naming the real shortcut, and Cancel. Rows are clickable but the waiting panel never takes key focus. |
| Agent session list | The Agent recording HUD’s frozen list of open sessions (sessions waiting for input first, then the rest, most recent first by the later of last use and start, the others alphabetically — `AgentRoster.recordingOrder`): number, name over agent and project, live state trailing (orange when it cannot receive), the conversation in front at the press highlighted across its row and marked by a separate In front label that never truncates (plain medium-weight text), and one line saying it is the conversation in front, or how to start with a name when none is, with a real example of each address form. Rows truncate in the middle (VoiceOver reads them whole); a list taller than the screen allows scrolls to the conversation in front on each recording admission, without moving it to the top or scrolling again for live status changes. Shares its state words with the Agent mode's conversation list through `AgentRoster`. |
| Agent conversation list | The Agent mode's sheet for managing conversations, opened by **Manage…** on the **Conversations** row that ends its Connections section (its summary counts only what can receive), or filtered to the affected conversations by a warning's **View affected conversations…** link, with a line naming the filter and **Show All**; the filter ends when the sheet closes. It never chooses where instructions go. Title “Conversations”, one line saying it manages conversation names and connections and sends no instructions, search, **Conversations** that can receive, and a collapsed **Not available (N)** `DisclosureSection` group. Rows are ordered by name and keyed by process and start time, so live updates never move a row, focus, the search or the scroll; each is two lines (name, then agent · project · live state, orange semibold only when it waits on the user), with no checkmark and no row click. A **⋯** menu holds Rename…, Show Conversation and Details…, and a Not available row shows its one step (Connect…, How to Connect…, Reconnect). Rows of an agent with more than one configuration folder add that folder to their second line, and details name it. Footer: Check Again and Missing one? leading, Done trailing; Missing one? explains discovery and points to **Add Folder…** under Connections rather than offering its own chooser. Secondary conversation sheets open over the list and return to it unchanged. |
| Integration row | One compact `DisclosureSection` per supported integration in the Agent mode's single **Connections** section (native separators, no per-integration cards): name and a short wrapping status line (`ConnectionSummary`): what is available, led by the setup only when it needs reading (not set up, turned off, in progress, failing), plus the folder count when there is more than one; unavailable conversations are never counted here. The full header expands setup and management inline; **Connect…** stays directly available beside the header when setup is needed and opens the consent sheet. Ordinary inspection opens no dialog and changes no connection. Failures auto-expand the row and show the setup's `IssueText`; manually collapsed, the header keeps its red dot and the failure's `IssueText` stays under it. Discovery advisories stay visible below the header; optional maintenance stays in the expanded content. |
| Configuration folder list | The expanded content of a connector's integration row (`ConnectorRow`): a “Configuration folders” label (plural even for one), one compact row per folder (`ConnectorFolderRow`: shortened path, status word, at most one lifecycle action — Install…, Reinstall, Update, Repair, Try Again, Finish Uninstalling — and a **⋯** menu with Show in Finder, Copy Path, the red Uninstall {Connector or Plugin}… and, for a folder the user added that was never installed, Remove from List), the folder's `IssueText` problems directly under it, then one **Add Folder…** (native folder picker, hidden files shown) for agents that support more than one folder, an advisory counting conversations that still need the agent's reload step, with a small **View affected conversations…** link that opens the conversation list filtered to them, and a collapsed **How {agent} connects** `DisclosureSection` holding the help and general reload advice. The default folder is an ordinary row; an already-listed folder, by any equivalent path, is refused with an advisory. Install… and Connect… share one consent sheet built like the Rename sheet, with bounded scrolling details and a fixed title and action row. Failures join the existing Settings error-marker chain. |
| Conversation name editor | A compact sheet with the spoken name, a live example and validation beside the field. Cancel leaves the name unchanged; Rename closes only after the name has been saved. A failed save keeps the draft editable. |
| Heard excerpt | `Heard “…”` under an unrecognized voice command or choice answer: the raw transcript, whitespace folded, at most two lines. Besides the agent session list’s one-line rows, the only HUD text that truncates — every other explanation still wraps. Hidden for a password-field or unconfirmed target. |
| Voice command notice | One note per kind of entry, each written for what that kind can do and weighted by its risk: a script or shortcut warning is shown expanded on every new entry and collapsed when editing; an app, link, or tab search gets a brief, neutral, collapsed note at the end of its sheet. A separate notice about recognition mistakes, window visibility, and scripts and Shortcuts run by voice gates first enabling Voice Commands and is remembered for each configuration. |
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
| `Answering with {name}` | Thinking, asking |
| `Getting ready to speak` | Loading voice, buffering |
| `Finished speaking · Esc closes` | Done, playback ended |
| `Text only · Esc closes` (a result shown with the voice set to Off — text only) | Muted, silent, not spoken |
| `Off — text only` (the shared voice picker's no-speech choice) | No voice, mute, disabled |
| `Cloud rewrite` | AI mode, remote magic |
| `Cloud answer` (a mode that answers about selected text) | Cloud rewrite (for an answer), AI reply |
| `Reply summary` (a reply update a service summarized, spoken or shown) | AI voice, cloud reply, spoken summary |
| `No cloud rewrite` (rewrite off) | off, don't use AI |
| `Best-effort redaction` | protected, anonymized, safe |
| `Insert without rewriting` | local transcript (implies raw STT), bypass, raw fallback |
| `Copied instead of inserted` | failed paste |
| `Rewrite Again`, `Rewritten later, not inserted` (a fallback rewritten from History) | retry, regenerate, redo, fixed |
| `speech model` / `model` | engine (in user copy) |
| `compatibility mode` (Apple Dictation standing in for Apple Speech) | fallback, legacy, older model, degraded |
| `Rewrite selected text` | edit mode, work on selection |
| `Reusable writing instruction` | prompt fragment |
| `Reasoning`, `Recommended — least reasoning`, `Model default` | thinking, effort, reasoning effort, auto |
| `Minimum output allowance` (with `tokens` beside the field) | max tokens, max_tokens, token limit |
| `Installed` (a connector's files are in a configuration folder) | Ready, connected (for files alone) |
| `Ready` (a conversation whose own connector connected, or whose agent host can reach it) | Installed, active (for a conversation) |
| `Not connected` (no connector has connected for it and no agent host reaches it) | offline, inactive, disabled |
| `Disconnected` (the user disconnected it; stays so when reopened) | excluded, blocked, muted |
| `Last seen` (shown from an earlier check that could not be repeated) | stale, cached |
| `configuration folder` (where an agent loads its configuration, and so its connector) | setup, setup folder, profile, scope, target, install location |
| `In front` / `conversation in front` (where a take without a name goes, captured at the press) | Current, recipient, selected, pinned, chosen |
| `No conversation focused` (nothing identifiable in front at the press) | No recipient, nothing selected |

---

## 5. Accessibility identifiers

Every load-bearing control carries a stable accessibility identifier so UI automation can address it
exactly. These are **frozen API once shipped** — a rename breaks the harness. All identifiers are
constants in `Sources/KeyScribe/AccessibilityID.swift` (nested by surface, registered in
`AccessibilityID.all`); never a string literal at a call site; dynamic rows interpolate the stable domain
id, never the display name. A container's identifier must not stand in for its children's: a disclosure
header and each field inside it keep distinct identifiers (`DisclosureSection(headerID:)` tags only the
header), since an identifier set on a whole section is inherited by every child that lacks its own and
hides theirs. Wiring mechanics (SwiftUI vs AppKit, the `NSMenuItem` exception) are in the
`keyscribe-ui` build guide.
