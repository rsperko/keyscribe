# KeyScribe — UX & UI Design Contract

> Canonical UX specification for the macOS app. Read with `design.md`, `../reference/config_schema.md`,
> `ui_components.md`, and `icon_design.md`. This document defines the user-facing product
> contract; implementation details do not override it.

---

## 1. Product posture

KeyScribe is a **quiet utility**. It stays out of the way while idle, gives immediate and
truthful feedback while dictation is active, and becomes detailed only when the user asks.

The everyday loop is one gesture:

```
Focus a text field → hold or tap the hotkey → speak → release → result arrives
```

The default user does not need to learn modes, model management, prompts, regular expressions,
or insertion methods. Those capabilities remain available and understandable in context.

### Non-negotiable UX rules

- Never imply that cloud processing, redaction, context reading, or history storage is more
  private or reliable than it is.
- Never hide a consequential state. The user must be able to tell which mode ran, whether a
  cloud request is in flight, what data category may leave the Mac, and whether text was
  inserted or copied instead.
- Do not put raw pipeline concepts in the default path. Say what the feature accomplishes;
  reveal implementation terms only in Advanced.
- Use the same wording for a concept everywhere. A privacy toggle, HUD badge, history badge,
  and help panel must describe the same behavior.
- Prefer a visible explanation to a warning dialog. Ask for confirmation only before actions
  that lose data, send a request, grant a permission, or materially change future behavior.

---

## 2. First run

A cold install cannot perform the one-gesture loop yet: there is no on-device speech model, and
Microphone and Accessibility are not granted. First run is the **single
sequenced experience KeyScribe allows itself** — not a settings tour, not a feature wall, and not a
request for every permission at once. Its only goal is to reach the first successful dictation.

The sequence is short, and each step states its purpose in plain language:

1. **One sentence on what KeyScribe does**, then a single primary action to begin.
2. **Choose and download one on-device speech model.** Show its size and that it stays on the
   Mac; recommend the default English engine. Downloading is required — nothing can be
   transcribed without it. Progress attaches to the choice, not a separate screen.
3. **Grant Microphone, then Accessibility — in that order, each explained beside its request and
   asked just before it is first needed:** Microphone to hear you, Accessibility to detect a
   modifier-key trigger and place text. State what still works if one is declined. (A key+modifier
   trigger registers as a system hotkey and needs no permission; Input Monitoring is never requested.)
4. **Try your voice.** Land the user on a focused text field and let them produce one real dictation;
   completion unlocks only after one succeeds. The instruction names the user's **resolved**
   trigger (never a hardcoded key), and the trial owns that shortcut: an inline **Use a different
   key…** affordance changes the Plain Dictation trigger in place (it edits the Direct mode itself,
   the same data Modes edits — not a duplicate setting), and a Direct mode the migration left with
   no trigger leads with a choose-a-key picker instead of dead-ending. A low-prominence **Skip for
   now** stays available so a hardware or permission snag never traps the user; both it and
   **Continue** lead to the AI opt-in (the AI step's own Finish is one click, so no one is ever
   more than two clicks from done). Taking Skip still records setup as complete, so an incomplete
   setup is a supported, not a blocked, state.
5. **Optional: make rough dictation clear (BYOK).** A slim opt-in card shows a tiny rough-to-polished
   example, an **Add AI cleanup…** action, and a one-click **Finish**. Choosing to connect reveals the compact
   connection form in place. Speech stays local; only a rewrite leaves the machine. Connecting the
   first service auto-enables and links the everyday rewrite modes, then lands on a short
   **playground** that shows exactly what the service does: the two headline rewrite demos —
   clean-up (Polish) and Edit Selection — each naming its real trigger and showing the user's own
   before → after the moment they try it. Dictation itself is not re-taught here (the trial already
   proved it), and Email-style spoken routing is not taught in first run because the suffix is hard
   to observe when it succeeds.

Each step states its purpose in roughly one line — the tone is fewer words, not more. The
permissions relaunch resumes onboarding at the **trial** (the step whose modifier tap the relaunch
exists to revive). A small **step indicator** (dots; the playground shares the AI step's dot) tracks
progress, steps **cross-fade**, and the intro waveform animates a gentle variable-color sweep — all
gated on Reduce Motion (static and identical to a still frame when it is on). Trigger keys render as
**keycap glyphs** in the trial and playground rows.

After first run, every other capability — dictionary, history, additional modes — is introduced
just in time, never as a wall. First run is the only exception, because the everyday loop (and the
one optional taste of rewrite modes) is otherwise impossible to demonstrate.

---

## 3. Progressive discovery and contextual help

Every unfamiliar, advanced, privacy-relevant, or irreversible control uses the same three
levels of explanation:

1. **Label and one-line result.** A setting row answers “what will change?” without opening
   anything.
2. **Inline help.** The help affordance expands in place. It explains what KeyScribe does, what
   it does not guarantee, prerequisites, and a short example if the concept is abstract.
3. **Details.** Only when useful, this expands to technical behavior, file/config references,
   or exact data flow. Details are local to the control; there is no dependency on a separate
   searchable help site.

The default affordance is the `Setting row with help` component from `ui_components.md`.
Do not use unnamed info icons or tooltip-only explanations for information that affects data,
privacy, or output.

### Required help locations

| Concept | Level-1 wording | Must explain in inline help |
|---|---|---|
| Mode | “How KeyScribe handles this dictation” | How automatic selection, one-shot overrides, app rules, and spoken routing interact. |
| Cloud rewrite | “Improve text with a language model” | The provider/model, that only an explicit BYOK connection can run it, and the fallback result. |
| Best-effort redaction | “Hide recognizable sensitive text before cloud rewrite” | It is pattern matching, can miss content, disables all context, and does not make cloud use safe for every secret. |
| Context | “Send useful context with the rewrite” | Exactly which categories are sent and that they cannot be used with privacy mode. |
| Fragment | “Reusable writing instruction” | The fragment is appended to a mode’s rewrite instruction, in order; it is not executable code. |
| Dictionary | “Words KeyScribe should recognize” | Engine support varies; entries always help rewrite prompts when a rewrite is enabled. |
| Replacement | “Change a recognized phrase automatically” | Replacements occur before rewrite; regular expressions are Advanced. |
| Rewrite selected text | “Replace selected text using your spoken instruction” | Selection is copied at trigger time and is sent to the selected rewrite provider when rewrite runs. |
| Insertion method | “How finished text reaches the target app” | Paste is the normal Settings behavior; Insert and Type are TOML-only compatibility escapes. |
| History | “Keep dictations on this Mac” | Audio is never saved; transcript and final text may be sensitive; per-mode exclusion and retention are available. |

### Help writing rules

- Lead with the user-visible effect, not the internal mechanism.
- State limits in the same expansion as the benefit.
- Use a concrete example for fragments, trigger phrases, regex, and redaction.
- Do not bury required permissions in an error after the user configured a feature. Explain
  them beside the setting and request them only when needed.

---

## 4. Visual language

### Character

Native, restrained, and precise. The interface should feel at home beside TextEdit, Terminal,
and developer tools: low chrome, strong hierarchy, no decorative gradients, no mascot imagery,
and no attention-seeking motion.

The visual system distinguishes three kinds of information:

- **Action:** neutral controls and standard macOS accent treatment.
- **State:** recording, processing, success, fallback, or error.
- **Data boundary:** local-only, cloud rewrite, best-effort redaction, or context shared.

Data-boundary signals are semantic labels plus icons. Color may reinforce them but may never be
the only signal.

### Layout and typography

- Use macOS system typography and standard control sizes.
- Use a single comfortable settings column with section cards only where grouping materially
  improves scanning. Avoid a dashboard.
- Settings use a sidebar for top-level destinations and a content column with grouped rows.
- A mode editor is a detail page, not a modal with a long unstructured form. Its footer is an
  action row: **Duplicate Mode** leads, **Delete Mode** sits alone at the trailing edge in red with
  a trash icon and a confirmation dialog — the same destructive-action convention the Speech Models
  and AI Services editors follow (routine actions lead, the destructive one is trailing, red, and
  confirmed; never stacked with routine actions).
- The HUD is intentionally compact and uses sentence-case labels.
- Monospaced text is reserved for hotkeys, model IDs, regular expressions, and code-like
  examples. It is not body-copy styling.

### Color and icons

- Default states use the system label hierarchy and accent color.
- Recording uses a clear active accent plus motion; processing uses a neutral progress state.
- Local/cloud/redaction/context states use the `Data boundary badge` vocabulary. Do not invent
  a competing set of shields, locks, colors, or phrases per screen.
- Symbols support labels. A microphone alone does not mean “recording”, and a shield alone does
  not mean “safe”.

### Motion and sound

- Recording feedback starts on the same run-loop turn as capture.
- The input-level indicator is the only continuous HUD animation. It respects Reduce Motion by
  becoming a changing level value without bouncing or pulsing.
- Sanctioned onboarding motion (all Reduce-Motion gated, no artwork or sound): the intro waveform's
  gentle variable-color sweep and the step cross-fade between wizard steps.
- The HUD recording indicator's red halo and dot are level-driven motion; Reduce Motion falls back to
  the fixed-geometry intensity-only dot.
- Completion, fallback, and errors settle quickly; no celebratory animation.
- Start/end sounds are optional and must have equivalent visual feedback.
- When "mute system audio" is on, other audio is silenced by *ducking* the output (the same call FaceTime
  uses), not by toggling the device's mute flag — so it cannot strand the device quiet (a crash mid-dictation
  releases the duck automatically). The duck lands *after* the start sound finishes (ducking first would
  swallow the cue, which routes through the same output). So with the start sound **off** the silence is
  instant — pick that for a dictation that feels immediate. The output device that was ducked is the one
  restored on completion, even if the default output changed mid-dictation.

---

## 5. HUD

The HUD is a movable, transient status surface. It is not a transcript editor and it never
becomes a second destination for configuration.

### Required states

| State | Primary content | Secondary content | Available action |
|---|---|---|---|
| Ready (one-shot mode picked from the menu) | Mode name | “Next dictation” | None; replaced when recording starts |
| Recording | Mode name + a red level circle (halo + dot; Reduce Motion: intensity-only dot) | “Listening”, or “Listening — tap [trigger] again to stop” for a latched tap-to-toggle recording | Stop if tap-to-toggle |
| Transcribing | “Transcribing” | Mode name | Cancel when safe |
| Rewriting | “Rewriting with [connection name]” | Boundary badges: `Cloud rewrite`, then `Best-effort redaction` or the exact shared context categories | Insert without rewriting after timeout |
| Complete | “Inserted” | Mode name | None; dismiss automatically |
| Target changed | “Copied instead of inserting” | “Focus changed while KeyScribe was working”, or “Accessibility is off — copied to the clipboard. Paste with ⌘V.” when the copy is due to a missing Accessibility grant | Paste last dictation (suppressed when Accessibility is off, since synthetic ⌘V can’t fire) |
| Rewrite fallback | “Inserted without rewriting” — or “Copied without rewriting” if the target also changed | “Rewrite could not be completed”, or the focus-change explanation when copied | Paste last dictation when copied; otherwise View details in History when enabled |
| No speech (real audio, none spoken) | “No speech detected” | Mode name | None; dismiss automatically |
| Nothing heard (mic muted/dead) | “Nothing heard — check your microphone” | — | Open Microphone Settings |
| Error | Plain-language failure | Single next action | Retry, open permissions, or dismiss as applicable |

Badges and explanations never truncate: the badge row wraps to as many rows as needed and the HUD
grows vertically (its per-state height is a minimum, not a cap). The two no-speech outcomes both
record `.noSpeech` in history; they differ only in the render — the microphone repair action appears
only when the take's audio peak never cleared the digital-silence floor.

The local-only states — Recording, Transcribing, Complete, Target changed, and Error — are the
whole HUD for a local dictation. The Ready state is the brief acknowledgment shown only when a
one-shot mode is chosen from the menu; there is no separate ready flash on hotkey invoke, because
recording feedback begins on the same run-loop turn as capture (§4). Rewriting and Rewrite fallback
appear when AI rewrite is enabled for the dictation. There is **one** Rewriting state: a rewrite is
always treated as a cloud data boundary — it names the connection and shows the
`Cloud rewrite` badge even for a local endpoint — so the boundary-badge behavior below always
governs it (KeyScribe does not currently distinguish a "polishing on this Mac" sub-state).

### Rules for cloud and privacy state

- A cloud request always names the selected connection, not a generic “AI” label.
- A cloud request with privacy enabled displays **“Best-effort redaction”**. Its expanded help
  says: “Recognizable sensitive text is replaced before this request. Pattern matching can miss
  content. App and selected-text context are off for this mode.”
- A cloud request without privacy enabled displays every enabled category: `App shared`
  and/or `Selected text shared`.
- While a rewrite is pending, the HUD shows the processing state and never the pre-rewrite
  transcript. KeyScribe cannot know in advance whether a rewrite is light or heavy, so the rule is
  mechanical: rewrite enabled and pending ⇒ no transcript shown. The raw transcript is not the
  expected result and showing it creates false confidence.
- When the wait passes the **max-wait escape-hatch threshold** (`design.md` §4.1 latency
  budgets), show **Insert without rewriting**. This action is always explicit; the HUD never
  auto-inserts the un-rewritten transcript early.

### HUD copy rules

- Describe the current operation, not the pipeline stage number.
- Do not say “secure”, “safe”, “private”, or “protected” for best-effort redaction.
- Completion must report the actual outcome: inserted, copied, local fallback, or no result.
- Inserted-versus-copied is reported even in the fallback states: a local fallback whose target
  changed says it copied, not inserted. Whenever the outcome is copied, the HUD offers Paste last
  dictation.

---

## 6. Menu bar

The menu bar is the app’s control center while keeping the normal interaction hotkey-first.
Opening it must answer: Is KeyScribe ready? What will the next dictation do? Where can I change
that?

### Menu structure

```
KeyScribe
Plain Dictation · Parakeet TDT-CTC 110M

Next Dictation ▸
  Automatic — Plain Dictation ✓
  ─────────────
  Plain Dictation
  Polish
  Message
  Email
  Edit Selection
  Manage Modes…

Paste Last Dictation

────────────────
Add to Vocabulary…

────────────────
Speech Model ▸
  Parakeet TDT-CTC 110M ✓
  Apple Speech
  ─────────────
  Manage Speech Models…
History…

────────────────
Settings…
About & Notices…
Quit KeyScribe
```

The first row is a single status line that answers "ready?", "what mode?", and "which model?" at once.
When ready it reads **`<next mode> · <model>`** — the mode being the pending **one-shot override** if one
is set, otherwise the mode that Automatic resolves to (never the literal word "Automatic"); the model
is the active STT engine. When something needs attention it is **replaced** by the problem text
(config error, a missing permission, or `Relaunch to finish setup`), in that precedence. There is no
separate "Next dictation" row — selecting a one-shot mode is reflected here, in the `Next Dictation`
checkmark, and in the HUD acknowledgement.

`Speech Model ▸` lists the **usable** (installed or system-managed) engines with the active one
checkmarked; selecting one switches the active STT engine (and starts loading + warming it). `Manage
Speech Models…` opens the full Speech Models settings pane for installs, deletes, and self-tests.

The menu leads with actions around the next or most recent dictation. Vocabulary follows as an
in-the-moment correction tool. Speech model selection and History are occasional management tasks,
so they sit together above Settings instead of competing with the primary loop.

> **`Add to Vocabulary…`** opens the standalone vocabulary panel; it is
> always present here and is also bound to a global chord shortcut (default ⌃⌥⇧V, rebindable
> in General ▸ Shortcuts; `[shortcuts]` in `config_schema.md`). The update UX is two complementary
> pieces: a **`Check for Updates…`** item (between `Settings…` and `About & Notices…`) is an on-demand
> check, shown whenever an updater is present (the public build; inert dev/white-label builds omit it);
> and an **`Update Available…`** item plus the amber badge below are the passive "an update is waiting"
> affordance, rendered only when the updater reports one. The public build uses Sparkle (EdDSA-verified);
> a build with no injected updater shows neither.

The modes listed under `Next Dictation` are the user's enabled modes; a fresh install shows only
**Plain Dictation** (the on-device Direct floor, on Fn) until the user adds an AI service. First AI
setup materializes and connects the two headline rewrite modes (Polish and Edit Selection); the other
starters stay available in the Modes pane's **Add Mode…** template chooser. Templates are reusable, so
adding one never removes it from the chooser.

### One-shot manual-mode override

Selecting a mode from `Next Dictation` applies **to the next dictation only**. The submenu states
this in place (`Applies to the next dictation only`), and the HUD briefly acknowledges the choice
in its Ready state (mode name, secondary `Next dictation`) before recording. When that dictation
ends or is cancelled, KeyScribe returns to Automatic mode resolution.

`Automatic — [resolved mode]` is always the first item and makes the resolver’s current choice
visible. Its inline menu description, or adjacent help in Settings, explains that app rules and
spoken routing can choose a different remaining pipeline after transcription.

### Dynamic status

- Idle: show the local STT readiness state, a required permission issue, model download status,
  or an update indicator.
- Recording: reflect that capture is active — the menu-bar glyph **tints red while recording** and
  reverts on commit. The menu remains secondary to the HUD.
- Cloud rewrite: show that a request is in progress and the connection name.
- Do not permanently change the menu-bar glyph to imply that all future dictations use cloud.
  The actual route is determined at dictation time.

### Status badges on the menu-bar icon

Two small corner badges on the menu-bar glyph, distinct by position and color so they read at a
glance and can show simultaneously:

- **Error badge — small red dot, top-left.** Shown when there is a configuration or model problem.
  *Wired to:* a malformed config, any missing required permission, an **unusable active STT model**
  (deleted out from under us), and the AI checks — a **dangling connection** (a mode names a deleted
  connection), a **structurally misconfigured connection** (no model, or OpenAI-compatible with no
  base URL, or token-command auth with no command), and a **failed Test Connection**. Opening
  Settings **flags the offending sidebar pane with a matching red dot** — Maintenance (config) ·
  Permissions · Speech Models (model) · AI Services (connection) · Modes — and the offending connection's row (orange = incomplete, red = test failed)
  and any mode wired to a failed connection (its row, red ⚠) are flagged in-pane. The sidebar polls
  while open and clears the flag the moment it's fixed. **A missing key is not always an error** —
  it is legitimate when an OpenAI-compatible endpoint is set to No Auth, but hosted providers and
  API Key auth require a saved Keychain key before testing or fetching models. **KeyScribe never
  passively probes the provider** (privacy invariant); the only live AI signal is the
  **user-initiated** Test Connection. (Drawn as a separate colored layer so it survives both the
  template glyph's appearance adaptation and the red recording tint.)
- **Update badge — small amber dot, top-right.** Shows when an app update is available. The
  update menu item carries a matching amber indicator so opening the menu reveals the same
  trail without treating the update like an error.

Both are non-modal, dismiss themselves when their condition clears, and never block dictation. Keep
them subtle — they hint, they don't alarm.

---

## 7. Settings

Settings follows the user’s configuration path, from basic behavior to increasingly technical
capabilities. The sidebar order is fixed:

1. **General** — startup, feedback, and model memory behavior.
2. **Speech Models** — active local engine, language capability, download/prepare/select/delete
   (any per-engine preparation step, such as a model conversion, is named for what it does).
3. **Vocabulary** — global recognition terms and automatic corrections.
4. **AI Services** — named BYOK connections; hosted-provider keys live in Keychain.
5. **Modes** — automatic rules and per-mode behavior.
6. **History** — audit/correction/diagnostics of past dictations, with the history enable and
   retention controls inline (see §8).
7. **Permissions** — review and repair macOS access.
8. **Maintenance** — configuration, interface repair, experimental features, and reset.

General, Speech Models, Vocabulary, and Maintenance stand on the local-only product. AI Services, and
the rewrite-related parts of Modes, govern the optional cloud rewrite.

### General

Show the few choices a new user is most likely to need:

- The dictation key, with a clearly exposed **Change key…** button. The key remains owned by Plain
  Dictation (Direct mode), so the button routes to that editor instead of creating a second setting.
- **Audio and system behavior** groups start/stop sounds, keeping the Mac awake, and muting other audio.
- Microphone choice, with a short explanation of following the Mac’s current input
- Open at login
- (History enable and retention live in the **History** pane, not here.)
- **Shortcuts** immediately follows Dictation and shows global chords for **Add to Vocabulary**
  and **Paste Last Dictation**, both of which are always available from the menu. Each uses a
  chord-only **shortcut well** (`None` in its menu clears it; a mouse button is rejected at capture
  with a hint). Add to Vocabulary defaults on to **⌃⌥⇧V**; Paste Last Dictation defaults off. A chord
  that collides with a higher-precedence hotkey, such as a Mode trigger, shows an inline **shadowed**
  breadcrumb and will not fire — mode triggers win.

The warm-up tier lives behind a `Keep speech recognition ready` disclosure pinned above the model
list in Speech Models (collapsed by default; the collapsed row shows the current tier's benefit, such as `Fastest start-up`). Explain Fastest,
Balanced, and Frugal as a memory/first-response tradeoff (it governs both the STT model's memory
residency and idle microphone warm-up), not as cache terminology. The footer copy **never shows a raw
byte count** — it describes behavior, not size.

### Speech Models

Speech Models is a standing master/detail pane on the shared Settings list layout (ui_components.md
"Settings list pane") — the same three-column shape as AI Services, Modes, and History. The pane's
global **Performance** control, **Keep speech recognition ready** (the selected engine's idle memory
and microphone warm-up behavior), is pinned above the list — the same "global controls above the
list" placement History uses for its enable/retention controls.

The left list has two persistent sections — **On This Mac** (usable/downloaded models, including the
always-usable system engine) and **Available to Download** (catalog models not yet on disk; a model
mid-download or verifying stays here until it verifies `Ready`, then promotes). Rows show only names
plus status; there are no radio controls, per-row actions, or bottom download menu — acquisition is
the selected model's own **Download** button. Selecting a model fills the right detail pane, under the
shared detail header (icon + name + **Recommended** badge), with its best-use description, language
coverage, disk requirement, and light/moderate/high memory use, and the one primary lifecycle action:
**Current**, **Use This Model**, **Download**, or its live install/test state. A model in
**Available to Download** shows an `AVAILABLE TO DOWNLOAD` label and a reduced read-only preview — the
facts and the `Download` button only, with no recognition or maintenance controls. Downloaded models do not
become active until **Use This Model** is pressed. Once a model is on this Mac, the detail's
**Recognition and maintenance** disclosure (the shared full-row `DisclosureSection`) holds dictionary-recognition tuning
plus a single maintenance row: **Test model** and **Reinstall model** lead the row, and **Delete
model** sits alone at the trailing edge in red — the destructive action is spatially separated from
routine maintenance, never stacked with it. Exactly one active engine is visually enforced, and
deleting it still requires confirmation.

### Dictionary and Replacements

Both screens prioritize fast correction over configuration theory.

- Add to Vocabulary: one compact composer with two labeled fields, **Word or heard phrase** (with an
  in-field example prompt) and **Use instead (optional)** — each field carries exactly one label, in
  global settings, mode settings, and the standalone panel. Leaving **Use instead** empty adds a
  dictionary word; filling it in creates a replacement. Adding a heard phrase that already has a
  replacement updates that rule in place — never a silent drop or a duplicate row. The first field
  keeps focus after adding so repeated entries are fast. The composer's first level is just the two
  fields, the leave-empty hint, and the Add button; **Match heard phrase as a regular expression**
  lives behind the composer's **Pattern matching** disclosure (regex stays fully available, one disclosure
  away). When regex is on the first label becomes **Heard pattern**, **Use instead** is required, the
  composer can create only a replacement — the leave-empty hint disappears and only the regex help
  shows — and the disclosure stays open so an ON regex toggle is never hidden.
- Dictionary: edit/remove saved words, import/export later only if needed. The first scan says only
  that terms use the intended spelling; model-specific recognition behavior and rewrite sharing live
  behind **How recognition works** inline help.
- **Set expectations honestly in the Dictionary copy** (do not overstate — say what actually
  happens). Recognition bias is a best-effort hint whose strength varies by engine (strongest on
  Apple; a soft nudge on Whisper/Parakeet), and dictionary terms always help the optional rewrite
  regardless of engine. Models without recognition bias should be labeled **No recognition bias**,
  then offer **Dictionary recovery** as a best-effort post-transcription fallback that can be turned
  off if it changes ordinary words. On **Parakeet** specifically, bias runs a second lightweight
  recognition pass over the audio — on the order of **a second on a long dictation, negligible on short
  ones** (measured: `BiasBenchmarkTests`). Frame it as a small, worth-it cost; never imply guaranteed
  recognition or a noticeable wait for normal use.
- Replacements: human-readable `When heard`/`Use instead` rows that wrap long values. Regex rows use
  `Pattern` and retain a visible `Regex` badge.

### AI Services

An AI service is a named connection, not a global provider choice. The persistent list is **Your
Services** only: each row shows its name, health, and provider · model. **Unused** appears only as a
subdued advisory when multiple saved services make it useful. The bottom **Add AI Service…** action
opens a compact provider chooser for hosted providers and **Custom (OpenAI-compatible)**; it previews
the selected provider before adding a seeded service and opening that service’s editor. The chooser has
a visible **Cancel** action as well as the Escape shortcut.

Selecting a **saved** service opens its **live editor directly** — no summary, no *Edit Connection*
step. The editor is immediate-apply and carries **Test Connection** and the trailing-red **Delete AI
Service** in place. Selecting a **provider starter** shows a read-only preview (endpoint known?,
sign-in, model default) with one CTA, **Add Service**: it persists a connection seeded from the preset
immediately, in an honest `No key set` state, selects it, and drops into that editor where the key is
pasted and the connection is Tested. The service is never presented as usable until it passes a Test,
and a failed Test surfaces in the editor rather than removing the row.

Onboarding keeps the stricter **test-then-save** flow (`AIServiceConnector`): its **Connect** button
tests the endpoint and only then saves, rolling the Keychain key back on failure or cancel — that
surface has one shot to produce a working service. The Settings pane deliberately relaxes this so
`Add Service` behaves like `Download`/`Add Mode`. The status vocabulary and error strings are shared
across both surfaces via one helper.

The editor answers the ready path first: its header shows the service name, provider, and latest status;
**Connection** keeps the credential action and **Test Connection** together; **Model** and **Used by**
follow. The latest test result remains in the header and beside the test action.

- Known providers keep their type, endpoint, and authentication mechanism out of the first scan.
  **Connection options** reveals changing the service type; Custom then exposes the endpoint and
  **No Auth**, **API Key**, or **Command** mechanism. Hosted presets pin their own URL and use API keys.
- API key state is singular: **API key saved** + **Replace key…**; no saved key + field + **Save key**;
  or an unsaved key + enabled **Save key**. Command shows its field and an inline required-state message.
  Generated tokens stay in memory only.
- **Model** — model id is always visible. Fetching models is a helper; when fetched models exist, a
  visible picker selects one while the chosen id remains visible in the model field.
- **Connection test** — user-initiated only, disabled until the visible prerequisites are met.

Do not present API parameters until the connection works. Put temperature, output limits, and
compatible endpoint configuration under `Connection options`.

### Modes

The Modes pane’s persistent list is **Your Modes**: Plain Dictation — the Direct floor — plus every
materialized mode. **Add Mode…** opens a compact chooser with **Start from a template** and **New blank
mode**; templates are reusable starting points, so the chooser always shows the full starter catalog and
each template keeps its read-only preview there. The chooser has a visible **Cancel** action as well as
the Escape shortcut, and its preview scrolls only when a smaller window needs it. Pressing **Add Mode**
materializes a fully editable mode, added **Disabled**, keeps it selected, and opens its editor. The
first instance created at a template's free catalog id keeps its seed identity, so it continues to
receive starter updates until the user edits it; adding the same template again creates a fresh,
distinct instance (**Email 2**, **Email 3**, …) with no seed identity. This differs from **Duplicate
Mode**, which copies the selected *customized* mode rather than the pristine catalog template. Existing
installs keep their previously-seeded starter files unchanged.

The Modes list shows the user-visible summary of each mode:

- name and enabled state (a disabled mode reads "Disabled");
- one routing fact and one processing fact, such as `Right-⌥ · On this Mac`, `Safari · Cloud rewrite`,
  or `Say “as an email” · Cloud rewrite`.

The editor presents a short **Mode summary** at the top. The editor is divided into progressive
sections:

1. **Basics** — name and enabled. (There is no "default mode" — the **Direct** system mode is the
   floor and owns Fn; bind Fn to another mode to change the everyday default. Direct's own editor is a
   reduced, mostly-locked form: shortcut + result handling only.)
2. **When to use it** — three plain first-level rows: **Shortcut** (the
   **shortcut well** — one control whose menu offers `None` and the modifier-only keys Fn (Globe),
   Right-⌥, Right-⌘, and ⌃⌥⇧⌘; recording accepts a tap of a modifier-only key on release, while a
   key pressed before release records a chord such as ⌘X; it also captures custom chords or extra mouse
   buttons in place), **Spoken phrase** (the chips + add field, with the actual phrases shown), and
   **Use in** (one unified apps-and-websites rule list; the Add… menu offers running apps, Choose from
   Applications…, Enter Bundle ID…, and **Website…** — a domain-first field that stores a host-anchored
   pattern matching that domain or a subdomain, never a substring). Press style, the window-title regex,
   and the raw URL regex live under `More ways to trigger`. History detail explains **how the mode was
   chosen** (menu / shortcut / app / spoken phrase / fallback).
3. **What it does** — plain dictation, rewrite selected text, live edits, spoken symbols, numbers
   (inverse text normalization), dictionary, and replacements. Dictionary/replacement editing lives
   under `Recognition and replacements`. (Dictionary recovery is no longer a mode setting — it is a
   per-engine option on bias-less speech models; see the Speech Models settings.)
4. **Improve with AI** — disabled by default; connection, plain-language instruction, and the
   mode's **reusable writing instructions** (fragments): listed by name directly under the
   instruction they extend, reorderable (they append in order), edited in place in a popover, and
   added from a single menu of existing instructions or a new one. They appear only once an AI
   service is selected, since a fragment is appended to the rewrite instruction.
5. **Data sent with AI** — visible only after AI rewrite is enabled. Privacy and context are
   mutually exclusive by design; the UI makes the tradeoff explicit before allowing either.
6. **Result handling** — history exclusion, trim trailing punctuation, ending spacing, and read-only
   notes when TOML-only insertion or submit behavior is active.

Plain Dictation stays deliberately small: **Shortcut**, **Spoken editing**, and **Result handling**.
Its spoken-editing control explicitly names phrases such as “insert new line” and “scratch that”; it
does not imply an AI rewrite or a separate expert mode.

When privacy is enabled, context controls remain visible but disabled with the exact reason:
`Privacy mode sends only the redacted dictation. Context is off.` The user should not have to
wonder why a selection/context option disappeared.

### Permissions

Permissions appear where their capability is enabled and in their own unobtrusive Settings section
near the bottom of the sidebar. Each permission row states why it is needed, what works without it, and a direct
repair action; a missing permission makes that action the prominent trailing control. KeyScribe requests permissions just in time, never in a blanket
first-launch wall.

### Maintenance

Separates configuration, interface repair, experimental features, and the destructive reset. (Notices
live in the separate **About & Notices** window, not here.)

- **Reveal Config in Finder** opens the support folder (`~/Library/Application Support/KeyScribe/`,
  `config_schema.md`) so a user can read, edit, back up, or version the plain-TOML config
  directly. This is the answer to "where does my config live" — the files are hand-editable on
  purpose, and revealing the folder removes any need to know the hidden `~/Library` path.
- **Reload Configuration** re-reads the config from disk on demand (edits are also picked up
  automatically; a malformed file surfaces an error rather than being silently dropped).
- *(Parked, not v1:)* a dedicated diagnostics/migration-error surface and a separate `models/`
  weights-folder reveal (the folder is reachable via Reveal Config today); plus an optional
  `KEYSCRIBE_CONFIG_DIR` override for users who keep config in a dotfiles directory — added only if
  asked for (`design.md` keeps Application Support the default; YAGNI).

---

## 8. History

History is a **Settings pane**, not a separate window (UX2 phase 8) — it is the audit,
correction, and diagnostics surface, reached via the menu "History…" / ⌘Y (which opens Settings
on the History pane) and the sidebar. It uses the same list/detail pane layout as Modes: a
left column with one compact History header for enablement and retention (moved out of General), a search field,
the day-grouped list, and the storage-truth statement pinned at the bottom; the right column is
the entry detail. The enable toggle and retention stepper live only here now — General has no
History section. **"Navigated away" equals "closed"**: leaving the pane (or closing Settings)
releases all parsed transcripts and the search cache, and re-entering reloads (signature-gated,
so it is free when nothing changed). "Paste Result" hides Settings, pastes into the previously
focused app, and closes Settings on success (re-presents + copies on failure).

Retention changes are staged until **Apply** is pressed in that header. A lower value confirms once only
when it would remove existing day files; an empty history or a value that removes nothing applies
without confirmation.

### List view

The list is grouped by day and supports search over locally stored text. Each row contains:

- final inserted text preview;
- time and mode;
- outcome (`Inserted`, `Copied`, `Local fallback`, or `Failed`);
- data-boundary badges relevant to that dictation;
- no audio indicator because audio is never stored.

### Detail view

The detail follows the user’s mental model:

```
Heard → Transformed → Result
```

It shows the mode, insertion outcome, correction actions, and a `Result` view with a separate
`Details` view for processing details.
section. Details reveal the exact connection/model when used, whether best-effort redaction was
enabled, which context categories were sent, and the stored prompt. Redaction maps are never
shown or persisted.

Correction actions are directly beside the relevant text:

- **Add to Dictionary** for a term that should be recognized as written.
- **Create Replacement** for a repeated heard-to-intended correction.

Reuse actions (**Copy Result**, **Paste Result**, **Copy Heard**) lead an action row at the top of the
detail. The destructive **Delete Dictation** follows the shared delete convention: it sits alone at the
trailing edge of a footer at the bottom of the detail, in red with a trash icon, and opens a confirmation
("Delete this dictation?" — "This dictation will be removed from local history. This cannot be undone.")
— the same trailing-edge, red, confirmed pattern as the Modes, AI Services, and Speech Models editors.

### Empty state

One centered state when there are no entries: `No dictations yet` with `Future dictations appear
here.` — and, because the enable toggle is inline in the same pane, **no navigation action**; when
history is off the description appends `History is currently off.` and the inline toggle is the
affordance. The storage-truth statement stays pinned regardless.

### Storage truth

The History pane and its empty state must state: `History stays on this Mac. Audio and
password-field dictations are never saved. Stored transcripts and final text can still contain
sensitive information.` Retention and per-mode exclusion are reachable from the pane's inline
controls and each mode's Result handling.

---

## 9. Accessibility and keyboard behavior

- Every action is usable by keyboard and reachable through standard SwiftUI/AppKit accessibility
  semantics.
- Status uses text labels in addition to color, glyphs, and motion.
- HUD content has stable VoiceOver announcements: recording started, processing path, inserted,
  copied instead, and failure. Do not announce continuous input-level changes.
- Expanded help is keyboard reachable and does not steal focus from the active setting control.
- Do not rely on hover for required information.
- Respect Reduce Motion, Increase Contrast, and Dynamic Type/system text sizing where the
  platform supports it.

---

## 10. Implementation acceptance checklist

A UI change is not complete until it satisfies these checks:

- The normal dictation loop works without opening Settings.
- A user can determine the actual data boundary of a cloud rewrite from the HUD and History.
- Every consequential setting has in-place, plain-language help and states its limit.
- Advanced configuration is absent from the first scan of the relevant screen.
- Selecting a menu mode affects exactly one next dictation and is acknowledged by the HUD.
- Disabled controls explain why they are disabled.
- All outcome paths report truthfully: inserted, copied, fallback, or failed.
- New UI uses components and semantic terms from `ui_components.md`; it does not introduce
  competing badges, help affordances, or status vocabulary.
