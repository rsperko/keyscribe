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
   Mac; recommend the default English engine, and offer no legacy model. The built-in macOS model is an
   ordinary entry in the same picker (its action reads `Use <model>` instead of `Download`), never a
   separate shortcut, and every choice states its accuracy label; the selected model's card adds its processing speed. The picker opens on the recommended
   model unless the active model is one the user already downloaded and setup still offers — never on
   the built-in model just because it is active. Downloading is required — nothing can be
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
   Cleanup and Edit Selection — each naming its real trigger and showing the user's own
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
- The recording accent is red on a dark HUD and a darker burgundy on a light one, so the dot keeps
  its weight against a light material instead of reading as a warning light.
- Every window — Settings, History, Add to Vocabulary, first run, About — follows the Mac's
  appearance. Only the HUD, the transient surface that floats over the user's app, takes the
  **HUD appearance** setting (Match System, Opposite of System, Light, Dark; default Match System).
  Opposite of System exists because an overlay sharing the app's appearance loses its edge against
  it. The HUD card also carries a visible hairline border in every appearance, heavier under
  Increase Contrast, and a pinned Light or Dark keeps the high-contrast variant.
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
- "Other audio" chooses what happens to everything else playing while you dictate: **Quiet** (the default)
  turns it down but leaves it audible, **Mute** silences it, **Unchanged** leaves it alone. Quiet is the
  default because going fully deaf mid-dictation costs you a meeting you are half-listening to, and because
  audio still playing is the ambient cue that a latched recording is still running.
- Both Quiet and Mute work by *ducking* the output (the same call FaceTime uses), not by toggling the
  device's mute flag — so neither can strand the device quiet (a crash mid-dictation releases the duck
  automatically). The duck lands *after* the start sound finishes (ducking first would swallow the cue,
  which routes through the same output). So with the start sound **off** the change is instant — pick that
  for a dictation that feels immediate. The output device that was ducked is the one restored on
  completion, even if the default output changed mid-dictation.

---

## 5. HUD

The HUD is a movable, transient status surface. It is not a transcript editor and it never
becomes a second destination for configuration.

**Timing contract: the HUD never appears until speech spoken immediately after its appearance will
be admitted.** The HUD is the visual half of the start cue (start/end sounds are optional and must
have equivalent visual feedback), so it appears at the same instant the cue ends and admission
opens — never at the press. A trigger is therefore acknowledged by *silence*: nothing is shown while
the microphone is brought up, which on a cold Bluetooth route is 200–500 ms (a built-in mic with
sounds off is ~50 ms and reads as instant). Recording is the first thing the user sees; a failed arm
shows Error with no HUD before it; a dictation released or cancelled during bring-up shows nothing at
all. There is no "arming"/"preparing" HUD: a panel that appears before admission grants visual
permission to speak into a window whose audio is discarded, and users react to the panel appearing,
not to its label.

### HUD states

| State | Primary content | Secondary content | Available action |
|---|---|---|---|
| Ready (one-shot mode picked from the menu) | Mode name | “Next dictation” | None; replaced when recording starts |
| Recording | Mode name + a red level circle (halo + dot; Reduce Motion: intensity-only dot) | “Listening”, or “Listening — tap [trigger] again to stop” for a latched tap-to-toggle recording | Stop if tap-to-toggle |
| Recording, near the limit | Same, plus an orange ring around the level circle that drains to empty | “Stops in 0:SS”, counting down | As Recording |
| Transcribing | “Transcribing” | Mode name | Cancel when safe |
| Voice command opening an app | Mode name | “Opening [app]…”, then “Looking in [app]…” while its tabs or sidebar fill | None; shown only once the command is acting, so it is not cancellable and does not take key focus away from the app being opened |
| Rewriting | “Rewriting with [connection name]” | Boundary badges: `Cloud rewrite`, then `Best-effort redaction` or the exact shared context categories | Insert without rewriting after timeout |
| Complete | “Inserted” | Mode name | None; dismiss automatically |
| Target changed | “Copied instead of inserting” | “Focus changed while KeyScribe was working”, or “Accessibility is off — copied to the clipboard. Paste with ⌘V.” when the copy is due to a missing Accessibility grant | Paste last dictation (suppressed when Accessibility is off, since synthetic ⌘V can’t fire) |
| Stopped at the limit | “Stopped at the [limit] limit” (e.g. “5-minute”) | “Inserted without rewriting — dictate again to continue” when the mode rewrites, “Inserted — dictate again to continue” when it does not, or the copied explanation | Paste last dictation when copied |
| Rewrite fallback | “Inserted without rewriting” — or “Copied without rewriting” if the target also changed | “Rewrite could not be completed”, or the focus-change explanation when copied | Paste last dictation when copied; otherwise View details in History when enabled |
| Voice command ran (Voice Commands mode, experimental) | Where it went — the app, the place and its browser (“Gmail · Google Chrome”), or the window and its app (“Budget — Numbers · Numbers”) — or the script or shortcut it ran (“Deploy”); a script that reported a result shows that message instead (“Switched to Inbox”) | “Voice command”, or “Started, still running” when the action has not finished; under a reported result, the script's name. A script's informational result (“Nothing waiting”) shows as an Advisory instead, with no failure styling. A window that closed, moved to another desktop, or could not be confirmed in front, and a search where some app did not list its windows, show an Error saying so (Accessibility off adds **Open Accessibility Settings**); if an action later fails, an Error naming the failure follows unless a dictation is in progress or a voice command choice is on screen, in which case History alone records it | None; dismiss automatically |
| Voice command needs a choice (Voice Commands mode) | “Which one?” for apps, places, and a script's own options, “Which action?” for `run` | Numbered rows, each a name over a detail that tells it apart (app, browser and host, app identity where names repeat, a window's app plus its document or site when two titles are the same, Script/Shortcut, or the name of the script that offered the option), then how to answer with the actual Voice Commands shortcut, led by one line when window rows still read the same (“Same name; the lower number is further forward.” within one app instance, else “Same name; these windows can’t be told apart.”) | Click a row; Cancel. Stays until answered, dismissed, or idle for the timeout |
| Voice command not recognized (Voice Commands mode) | “Command not recognized” | What the speech model heard, before any replacement: “Heard “stitch to Mail”” — omitted when the target was a password field or could not be confirmed | None; dismiss automatically |
| No speech (real audio, none spoken) | “No speech detected” | Mode name | None; dismiss automatically |
| Nothing heard (mic muted/dead) | “Nothing heard — check your microphone” | — | Open Microphone Settings |
| Error | Plain-language failure | Single next action | Retry, open permissions, Open Speech Models when the selected model is not installed, or dismiss as applicable |
| Config problem (idle, after an external edit) | “Couldn’t read [file] — [parser message] — previous version still in use” (or “— ignored until fixed”), or “[file] — “[key]” (did you mean “[key]”?) has no effect” | — | None; dismisses automatically |

**Config problems.** The HUD names only problems an external edit just introduced — each new unreadable
file or unread key once, never during a dictation. Settings → Maintenance keeps listing every current
problem until it is fixed, and an unreadable file also stays in the menu status. An unread key is an advisory, not a
failure: it shows with an info icon rather than the error triangle, and a batch that includes an
unreadable file shows as the failure. While a voice-command question is waiting, the announcement becomes
the question's note instead of covering the list.

**Recording limit.** A single take has a length limit (`design.md` §4.8). Reaching it ends the take
the way a release does — the recording is transcribed and inserted, never discarded. The warning
reuses what the Recording HUD already shows rather than adding to it: in the final stretch a thin
orange ring drains around the level circle and the “Listening” line becomes a countdown. VoiceOver
announces the countdown once when it begins, not every second. A take the limit stopped is inserted
without the AI rewrite, and the completion state says so, so the user never mistakes a raw fragment
for a rewritten result. An edit-in-place take stopped by the limit leaves the selection unchanged and
says so as an Error. It adds that what was said is in History only once that entry has been
confirmed saved — this one write waits for the disk rather than being queued like every other
History write, so a failed save never sends the user looking for an entry that does not exist. A take
stopped by the limit never presses the mode's Return, including a take that is only a spoken Return
command; the latter reports “Stopped at the [limit] limit — Return not pressed”.

**Voice command choice.** The list interrupts the user, so it is used sparingly (`principles.md` §4,
“Asking is a last resort”): navigation settles ties it can order by itself, and the list appears only when
no predictable default exists or a wrong guess would run the wrong action. When a command matches more than
one destination at the same step in those cases, the HUD asks instead of guessing. The user answers with any shortcut (“two”, “the second one”, “the last one”,
“cancel”), by pressing a row's number key, or by clicking a row. A dictation mode's shortcut answers only when
what was said is a number or “cancel”; anything else is dictated into the app as usual and the question
closes, so a list left on screen never swallows real dictation. The list is frozen when it appears: rows never reorder or refill, and a chosen row
that has since disappeared reports that rather than choosing its neighbour. While answering, the list
stays on screen with the normal status (`Listening`, `Transcribing`) in place of its subtitle — never a
microphone-only HUD — and during microphone bring-up the question stays exactly as it was, so the timing
contract above still holds. A reply that is neither a number nor a command keeps the list and shows
what was heard in place of its subtitle (“Heard “tube””), without repeating the answer hint below the
rows; a number outside the list keeps the list and says which numbers are valid. The next answer
recording replaces that line, and nothing restores it afterwards. Silence, a failed transcription, or cancelling the answer recording also keep it; a failure that offers a repair (such as **Open Microphone Settings**) keeps the list and shows its message as the subtitle with the repair button beside **Cancel**. The question is
neither success nor failure, so it plays no cue. It is dismissed by an answer, spoken or clicked
**Cancel**, a new command, the idle timeout (`VoiceCommandRunner.choiceIdleSeconds`, restarted each
time the list is shown again), a dictation that is not an answer, switching to an app other than the one the
command was given in (any app, when it was given in KeyScribe's own window), locking the screen,
sleep, turning Voice Commands off, or editing its saved commands. More matches than
`VoiceCommandChoice.displayLimit` offer no list: the Error asks the user to say more of the name.
A clicked row runs only if no new dictation starts while its destination is being looked up, and its
result appears once any interrupted answer recording has finished unwinding.
**Focus:** the question holds key focus whenever it is on screen, exactly like Recording, since it is
visible and cancellable: **Esc** dismisses it like **Cancel**, and a row's number key, pressed without ⌘, ⌥, ⌃,
or ⇧, chooses that row like a click. Clicking another app returns focus there. There are no arrows or Return for the list (see §9).

Badges and explanations never truncate: the badge row wraps to as many rows as needed and the HUD
grows vertically (its per-state height is a minimum, not a cap).

**Heard excerpt.** An unrecognized voice command, and an answer to a choice that was not understood,
show what the speech model heard so a mishearing is visible at a glance. It is the raw transcript,
never the text after vocabulary replacements, and the HUD does not claim it is what the command
reader received: Preview a command (§7) shows how a typed phrase reads after replacements. It is the one HUD text
that truncates. Whitespace is folded to single spaces, the phrase is cut to
`HeardExcerpt.characterBudget` characters, and it shows at most two lines; a shortened excerpt keeps
its start and ends in a single ellipsis. Titles, choice rows, hints, and actions keep wrapping. The
excerpt is not shown, read by VoiceOver, or kept in a note when the take's target was a password
field or could not be confirmed, the same rule that keeps such a take out of History; History being
off or the mode being excluded from it does not hide it. VoiceOver reads the title, then the excerpt,
once; a retained list announces only the changed line. Timing is unchanged: the standalone Error
dismisses after three seconds and a new recording replaces it. The two no-speech outcomes both
record `.noSpeech` in history; they differ only in the render — the microphone repair action appears
only when the take's audio peak never cleared the digital-silence floor.

The local-only states — Recording, Transcribing, Complete, Target changed, Stopped at the limit, and
Error — are the whole HUD for a local dictation. The Ready state is the brief acknowledgment shown only when a
one-shot mode is chosen from the menu; there is no separate ready flash on hotkey invoke — see the
HUD timing contract below. Rewriting and Rewrite fallback
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

### Reopening when the icon is unreachable

The status item is the control center, but it must never be the *only* way in. KeyScribe has no Dock
icon, so a user whose icon is not reachable — hidden behind the notch, pushed off a full menu bar,
tucked away by a menu-bar manager, or dragged out of the bar — would otherwise have no way to open
Settings at all. Reopening the app (double-clicking it in Finder, which macOS delivers to the running
instance rather than launching a second copy) therefore opens Settings. If onboarding is still open,
reopening re-fronts that window instead, so the wizard is never buried under Settings.

This is a reachability guarantee, not a repair: it does not un-hide the status item, and KeyScribe
never overrides a deliberate hide by forcing the item visible.

### Menu structure

```
KeyScribe
Plain Dictation · Parakeet TDT-CTC 110M

Next Dictation ▸
  Automatic — Plain Dictation ✓
  ─────────────
  Plain Dictation
  Cleanup
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

**Quit** always quits, from the menu bar, from ⌘Q in a Settings window, and when the app relaunches itself
(a permission repair or Erase All). This is a deliberate KeyScribe policy: Quit dismisses open dialogs and
discards unsubmitted drafts, such as a half-filled command sheet, without asking. Settings already applied
remain saved, since panes apply each change as it is made. macOS would
otherwise refuse to quit with a beep, which left Quit dead whenever a command sheet sat in a Settings window
hidden behind other apps, and would leave a relaunch running two copies.

The first row is a single status line that answers "ready?", "what mode?", and "which model?" at once.
When ready it reads **`<next mode> · <model>`** — the mode being the pending **one-shot override** if one
is set, otherwise the mode that Automatic resolves to (never the literal word "Automatic"); the model
is the active STT engine. When something needs attention it is **replaced** by a short, clickable
summary that opens the Settings pane where it is fixed — `Settings file needs attention…` /
`A config file needs attention…` / `N config files need attention…` (Maintenance), a missing permission,
or `Relaunch to finish setup…` (Permissions), in that precedence. It stays the menu's normal width and
color; the detail lives in the pane, and the red badge marks it. A config advisory never appears here. There is no
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

**About & Notices…** names the licenses for bundled libraries and runtime-downloaded models, including
the Silero VAD support model and production-only Sparkle binary. The app bundle carries the GPLv3
license, component index, and resolved dependencies' supplied license/notice files under
`Contents/Resources/Legal` so the notices travel with binary distributions instead of existing only in
the source checkout.

The modes listed under `Next Dictation` are the user's enabled modes; a fresh install shows only
**Plain Dictation** (the on-device Direct floor, on Fn) until the user adds an AI service. First AI
setup materializes and connects the two headline rewrite modes (Cleanup and Edit Selection); the other
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
  (deleted out from under us), a **mode whose shortcut can never fire** (another mode claims the same
  press written a different way, so shadowing drops this one), and the AI checks — a **dangling
  connection** (a mode names a deleted connection), a **structurally misconfigured connection** (no
  model, or OpenAI-compatible with no base URL, or token-command auth with no command), and a **failed
  Test Connection**. The
  **`Settings…` menu item carries a matching red dot** while any of these hold, so opening the menu
  points at where the problem is fixed instead of dead-ending at the glyph. Opening
  Settings **flags the offending sidebar pane with a matching red dot** — Maintenance (config) ·
  Permissions · Speech Models (model) · AI Services (connection) · Modes — and the offending connection's row (orange = incomplete, red = test failed)
  and any mode wired to a failed connection (its row, red ⚠) are flagged in-pane. A mode whose shortcut
  can never fire is flagged the same way, in its Modes-list row (**Shortcut never fires**) as well as in
  its trigger row — the editor alone would hide it behind a selection. The sidebar polls
  while open and clears the flag the moment it's fixed. A config **advisory** — a key a config file
  carries that nothing reads, usually a typo — puts an **amber** dot on the Maintenance sidebar row
  instead, and nothing on the menu bar: it means "an edit did nothing", not "something is broken". Red
  outranks amber on the same row. **A missing key is not always an error** —
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
capabilities. The panes are whatever `SettingsDestination` defines, and their sidebar order is
fixed — a new pane takes its place in this progression rather than being appended:

1. **General** — startup, feedback, and model memory behavior.
2. **Speech Models** — active local engine, language capability, download/prepare/select/delete
   (any per-engine preparation step, such as a model conversion, is named for what it does).
3. **Vocabulary** — global recognition terms and automatic corrections.
4. **AI Services** — named BYOK connections; hosted-provider keys live in Keychain.
5. **Modes** — automatic rules and per-mode behavior.
6. **History** — audit/correction/diagnostics of past dictations, with the history enable and
   retention controls inline (see §8).
7. **Permissions** — review and repair macOS access.
8. **Maintenance** — configuration, diagnostics, interface repair, experimental features, and reset.

General, Speech Models, Vocabulary, and Maintenance stand on the local-only product. AI Services, and
the rewrite-related parts of Modes, govern the optional cloud rewrite.

**Where a failure appears.** A failed operation (save, add, delete) and a config file the pane can't
read appear in a **pane notice** above the pane's scrolling content, so scrolling can never hide them.
The notice leads with the outcome — a short red title saying what didn't happen (`Replacement wasn’t
saved`, `Changes to Notes weren’t saved`) — then one plain line naming the file that needs fixing and
what still works (`Your existing replacements are still working.`, said only when the running app really
kept a previous version), **Show in Finder**, and a collapsed **Technical details** holding the line,
column, and parser message. It sizes to its content up to a fixed height, then scrolls within itself, so
expanding **Show more** or Technical details never squeezes out the pane; it shows two notices before
that link, and never moves focus or scrolls the pane. Field validation stays beside
its field, and advisories beside their setting. A failed add keeps the draft so the user can retry; a
notice clears when that same operation later succeeds, or — for a file it couldn't read — when the file
loads again; an unrelated save or reload never clears it. Speech Models lists each model's download or
test failure there by model name, and the model's list row keeps its status marker.

Editable fields preserve the typed draft while invalid and explain the correction inline. Blank required
fields give a neutral hint; entered invalid values show an inline error. Names, phrases, identifiers,
endpoints, and regular expressions reject empty, multi-line, malformed, or unreasonably large values;
multiline writing instructions remain supported with a visible size limit.
Editable textual input uses leading alignment, so a trailing space stays visible as it is typed. A field
may sit in a trailing form-value column, but its content does not become trailing-aligned; that
alignment is reserved for form labels and comparable numeric scalar values.

For OpenAI-shaped connections, KeyScribe automatically selects the compatible request format from the endpoint's
own response. The setup flow never asks people to choose an API protocol, and detection never infers from a
model name.

### General

Show the few choices a new user is most likely to need:

- A **Plain Dictation** summary showing its current shortcut and press behavior, with a clearly exposed
  **Edit in Modes** button. The shortcut remains owned by Plain Dictation (Direct mode), so the button
  routes to that selected editor instead of creating a second setting. The compact row shows the key and
  its press behavior; its footer explains that Plain Dictation is used whenever no other mode matches.
- **Sound feedback** controls all dictation sounds: starting, completing, canceling, and needing
  attention. Its **Play dictation sounds** switch reveals a continuous **Dictation sounds volume**
  slider with quiet/loud speaker endpoints; turning sounds off hides the slider without resetting its
  value. Maximum plays the sounds at full level and the Mac's output volume still applies. The slider
  defaults to maximum, uses a perceptual attenuation taper, and plays one start-sound preview at the
  selected volume when released — releasing the slider is the only preview, deliberately: hearing the
  level is a consequence of setting it, not a separate button to press. The quiet endpoint reads as a
  crossed-out speaker at zero, where sounds are on but silent; at zero the start cue is skipped outright,
  so recording begins as immediately as it does with sounds switched off (the cue hold exists to fence an
  audible cue out of the take, and there is nothing to fence).
- **HUD** holds the HUD appearance picker (Match System, Opposite of System, Light, Dark). Its footer
  says that every window, Settings included, still follows the Mac.
- **During dictation** groups keeping the Mac awake and muting other audio. Its footer makes clear that
  both apply only while the user dictates.
- Microphone choice, with a short explanation of following the Mac’s current input
- Open at login
- (History enable and retention live in the **History** pane, not here.)
- **Shortcuts** immediately follows Dictation and shows global chords for **Add to Vocabulary**
  and **Paste Last Dictation**, both of which are always available from the menu. Each uses a
  chord-only **shortcut well** (`None` in its menu clears it; a mouse button is rejected at capture
  with a hint). Add to Vocabulary defaults on to **⌃⌥⇧V**; Paste Last Dictation defaults off. A chord
  that collides with a higher-precedence hotkey, such as a Mode trigger, shows an inline **shadowed**
  breadcrumb and will not fire — mode triggers win.
- A **mode trigger well** also records a **modifier-only trigger**: hold one to four modifiers with no
  key and release. It records the physical keys you pressed (**Left-⌘**, not "either ⌘"), however many —
  so a trigger recorded on one side does not fire on the other, and a recorded ⌃⌥⇧⌘ shows as **Custom**
  rather than matching the menu's sideless entry. Left and right of the same modifier cannot be combined,
  and the well says so instead of recording. Its menu still
  offers a short list of the familiar sideless triggers, and anything else you record shows as
  **Custom**. A modifier set that is a strict subset of another
  contending mode's set is *pressed on the way into* it, and the well says so as an advisory; the
  chord grace makes pressing the larger one as a single motion start only that mode.
- Every shortcut well records the **character a key types**, not its position, so a saved chord may
  not exist on another keyboard layout. A chord the active layout cannot produce is never registered,
  and the well says so with a **Not on your current keyboard layout** caption rather than looking
  bound and silently doing nothing.

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
shared detail header (icon + name + **Recommended** or **Legacy** badge), with its best-use description,
its accuracy label (`Top` / `High` / `Good` / `Lower accuracy` — graded without a dictionary against the
best offered model, never a WER figure, so a single-voice benchmark is not presented as a score) followed,
on models that use the dictionary while recognizing speech, by that benefit on the same line; a processing
speed label (`Fastest` / `Fast` / `Slower processing`, never seconds), language coverage, disk requirement, and
light/moderate/high memory use, and the one primary lifecycle action:
**Current**, **Use This Model**, **Download**, or its live install/test state. A model in
**Available to Download** shows an `AVAILABLE TO DOWNLOAD` label and a reduced read-only preview — the
facts and the `Download` button only, with no recognition or maintenance controls. Downloaded models do not
become active until **Use This Model** is pressed. Once a model is on this Mac, the detail's
**Recognition and maintenance** disclosure (the shared full-row `DisclosureSection`) holds dictionary-recognition tuning
plus a single maintenance row: **Test model** and **Reinstall model** lead the row, and **Delete
model** sits alone at the trailing edge in red — the destructive action is spatially separated from
routine maintenance, never stacked with it. Exactly one active engine is visually enforced, and
deleting it still requires confirmation.

**Legacy models** are on their way out: they keep working and stay installable, but first run no longer
offers them, they sort to the end of the list, an uninstalled one's row reads `Legacy · …`, and the
detail shows an advisory `IssueText` — *Being phased out. Switch to <recommended model>, the recommended
model.* — including when it is the active model. The app never switches a user off a legacy model on its
own; that happens only when the model is retired a later release, through the replaced-model notice below.

**Apple Speech** is one entry that runs one of two Apple models. It uses Apple Speech wherever this
Mac and language support it, and otherwise Apple Dictation, Apple's earlier dictation model. The list
name never changes. Its detail shows which model is in play as a plain secondary line under the facts:
`Using Apple Speech`, or `Using Apple Dictation (compatibility mode) — Apple Speech isn’t available
on this Mac` (or `… for <language>`, or `… Apple Speech couldn’t be downloaded yet` when its download
failed and Apple Dictation stood in; the app retries in the background and switches back once it lands).
When neither Apple model covers the user's language, the line
reads `Apple Speech isn’t available for <language>` and claims no model in use. The fallback is a valid outcome, not a problem, so it is not an
`IssueText`. Its Languages fact reads `Languages vary by Mac`, because macOS sets that coverage and it
differs between the two models.

When the saved model can no longer run here — it was retired, or it needs a newer macOS — launch picks
the model deleting the active one would (the default English model if it is usable, otherwise a downloaded
model the user already has — legacy included — and only then Apple Speech on macOS 26+) and saves that choice. The new active model's detail
then shows an advisory `IssueText` naming what changed — for example *Moonshine Base (English) is no
longer included in KeyScribe. Now using Apple Speech.* — or, when nothing usable is installed, asks for a
download. The notice clears when the user selects a model. It does not return after a relaunch, because
the replacement is already saved. A saved model that is known but merely not installed is never
rewritten; dictation shows the not-installed error with **Open Speech Models**.

### Dictionary and Replacements

Both screens prioritize fast correction over configuration theory.

**Vocabulary** is the management home for both global and mode-only vocabulary. It uses the shared
Settings list/detail layout: **Global** is first and applies everywhere; enabled modes follow; disabled
modes remain visible in their own group so their existing vocabulary and pre-enable setup never disappear.
Plain Dictation is not listed: it always uses Global. Voice Commands is listed while its flag is on, and
the correction shortcut can add to it.
Selecting a scope edits only its own words and replacements. A mode detail states whether it also includes
Global vocabulary, rather than mixing inherited entries into its editable lists. Mode editors keep an
always-visible **Recognition and replacements** summary with an **Edit Vocabulary…** action; the full
composer and lists do not live inside the mode editor.

- Add to Vocabulary: one compact composer with two labeled fields, **Word or heard phrase** (with an
  in-field example prompt) and **Use instead (optional)** — each field carries exactly one label, in
  Global, a selected mode, and the standalone panel. Leaving **Use instead** empty adds a
  dictionary word; filling it in creates a replacement. Adding a heard phrase that already has a
  replacement updates that rule in place — never a silent drop or a duplicate row. Entering a
  dictionary word that differs only in casing updates that existing word in place; the composer names
  the current spelling and uses **Update** rather than **Add**. The first field keeps focus after
  adding so repeated entries are fast. The composer's first level is just the two
  fields, the leave-empty hint, and the Add button; **Match heard phrase as a regular expression**
  lives behind the composer's **Pattern matching** disclosure (regex stays fully available, one disclosure
  away). When regex is on the first label becomes **Heard pattern**, **Use instead** is required, the
  composer can create only a replacement — the leave-empty hint disappears and only the regex help
  shows — and the disclosure stays open so an ON regex toggle is never hidden.
  **Use instead** grows from one line to a few on every surface. Global and mode Settings place **Open
  in a larger editor…** directly beneath the field for deliberate macro authoring; quick corrections
  in History and the standalone panel stay compact. A saved rule opens a roomy edit popover with its
  multiline replacement editor already visible, never a sheet over a popover. Replacement content is
  stored exactly as authored (only the heard phrase is trimmed); the editor caps a single replacement at
  **65,536 characters** and refuses to save an over-limit draft rather than silently truncating it.
- Dictionary: edit/remove saved words, import/export later only if needed. The first scan says only
  that terms use the intended spelling; model-specific recognition behavior and rewrite sharing live
  behind **How recognition works** inline help. Dictionary and replacement rows use the shared red
  trash action; deleting either opens an item-specific confirmation that distinguishes global entries
  from mode-only entries.
- **Find replacements in History.** Each Words to Recognize row offers **Mishearings in History…**
  directly when readable saved History exists. The action moves below the word when they cannot fit on
  one line; long words wrap, and delete remains at the trailing edge. There is no word-selection state or separate launch
  button below the list. Availability follows saved records, independently of the History recording
  toggle or History pane filters, and refreshes while Vocabulary is visible. Without readable saved
  History, dictionary rows retain their ordinary text and independent delete controls.
  The action opens a compact editable sheet titled **Mishearings of “{word}”** and searches automatically across all saved History,
  all modes, and all speech models. Period and speech-model filters live in a collapsed **Search
  options** disclosure; changing them searches again on the same surface. Refreshing or narrowing a
  search preserves chosen edits and manually entered phrases. Search filters affect discovery, never
  the destination or the current speech model.
  **Use instead** is always editable and starts with the launching word. Edits change the proposed
  replacement text and previews; they do not rename the saved dictionary word or change the discovery
  target. The launching scope is shown once as **Add to**, with a short explanation of where it applies.
  Discovered phrases start unchecked. An unchecked suggestion shows its Heard sentence context and how
  many times it matched **in search**, straight from discovery; more examples expand in place. Checking
  phrases builds one combined replacement-stage preview over all saved Heard text, and each checked row
  shows its own share of that preview; changes that cannot be tied to a single phrase stay visible in
  **Combined preview**, which appears for several checked phrases or for any such change. A checked row
  whose changes all overlap other phrases points to **Combined preview** instead of claiming no matches.
  Examples outside
  the search filters are labeled. Editing **Use instead** rebuilds only the preview, never the search.
  Each discovered row offers **Edit heard phrase**, which opens an in-place editor and focuses it once;
  focus moves only on that action or on **Add a phrase manually…**, never because a row scrolls into view.
  A manual row stays inactive while blank: it is not counted, previewed, validated, or saved, and it never
  disables Add for other phrases. Typing a phrase includes it; unchecking it afterwards is respected. A
  checked phrase that is invalid shows its error beside the field and blocks Add. Conflicts, existing
  rules, and Global overrides appear beside the affected phrase, outside disclosures, whether or not it is
  checked. **Use instead** may be whitespace or line breaks; it is saved exactly as typed, with the same
  advisory the replacement composer shows. **Add a phrase manually…** remains available when no similar
  phrases are found. Empty results distinguish no possible mishearings from phrases already corrected
  automatically by existing replacements or dictionary recovery.
  **Add {n} replacements** saves the previewed rules in one write to the launching scope and closes the
  sheet; **Cancel** always closes without saving. Add stays disabled while the preview is updating or a
  checked phrase is invalid, and the footer says what is needed. Conflicting or already-saved rules are
  called out and excluded from the save. If words or replacements changed before saving, nothing is
  written: the preview is rebuilt against the current vocabulary, a notice says it changed, and Add must be
  clicked again. If History changed, nothing is written and **Refresh Search** is offered. If the word or
  the destination was removed, nothing is written and the first Add says which. Success appears in
  Automatic Replacements as **Added {n} replacements**. Searching never contacts a network service and
  never changes saved History or the dictionary word. Replacement text remains subject to a later AI
  rewrite unless it consumes the whole utterance.
- **Set expectations honestly in the Dictionary copy** (do not overstate — say what actually
  happens). Recognition bias is a best-effort hint that only some models can take, so let each
  model's own capability drive the copy rather than naming engines here. A model that supports it
  offers a per-model switch for using the dictionary during recognition; a model without it should be
  labeled **No recognition bias**. Independently of the model, KeyScribe repairs near-misses right
  after transcription whenever the mode's dictionary is non-empty — that is always on, so never
  present it as something the user can turn off — and dictionary terms always help the optional
  rewrite. Never imply guaranteed recognition.
- Replacements: human-readable `When heard`/`Use instead` rows, separated by a hairline divider. The
  heard phrase and the `Use instead` value are both primary text (a one-character value such as `.`
  must not read as a disabled hint); a regex pattern is shown monospaced so backslashes, brackets, and
  punctuation stay inspectable. The `Use instead` value shows as
  exactly **one bounded preview line** (line breaks and tabs rendered as `\n`/`\r`/`\t`, a
  whitespace-only value showing its spaces as `␣` so it never looks empty, capped so a row
  never grows with the replacement body); the full value stays available in the larger editor. Regex
  rows use `Pattern` and retain a visible `Regex` badge. Rules match the heard text once and replacement
  output is never matched again. When rules overlap, the longest actual match wins; equal matches prefer
  the selected mode's rule over Global, then the topmost rule within the same scope. The list explains
  that replacements happen before any AI rewrite, which may still adjust the result; a longer phrase wins
  when two rules could match; and, when multiple rules are listed, the higher rule wins if two match the
  same words. Each row has a subtle drag handle and uses the platform table-reordering interaction. The
  system insertion marker appears only at positions that would change the order, never immediately above
  or below the row's current position. A context menu and accessibility actions provide **Move up**/**Move
  down** without permanent arrow-button clutter. The list expands to fit its rows and relies on the
  Settings pane's scrollbar instead of introducing nested scrolling.
  A trailing pencil opens a roomy popover for changing the heard phrase, replacement text, or regex
  behavior; **Update** applies the fields atomically and preserves the rule's position. Dismissing the
  popover leaves the rule unchanged. If the rule changes or disappears outside the editor before Update,
  the popover stays open and explains that it must be reopened instead of pretending the stale edit saved.
  Mode rules with the same identity override their included Global counterpart. Reordering changes only
  the tie priority between rules in the displayed scope.
  Each row's label line carries a right-aligned, single-line secondary-text usage caption (it truncates
  rather than wrapping, so it never adds height) so the user can see which rules earn their place:
  `Used 14 times · last used Oct 19` (`today`/`yesterday` when recent), `Not used since added Aug 2`, or
  `Added today`. A rule that already existed when counting began has no known add date, so it never
  claims one: it reads `No uses recorded since <the day counting began>` (`No uses recorded yet` on that
  day). It counts dictations that reached their destination, independent of History. It is read-only:
  rows keep the user's order because order is tie priority, and nothing is ever removed automatically.
- **The composer says what Add will do before it is pressed in Settings, mode settings, and the standalone panel.** A live status directly below the relevant fields covers
  the non-obvious cases: a duplicate word ("Already in Words to Recognize", or "…already included from
  your global vocabulary" in a mode), an identical replacement, and an update — the button relabels to
  **Update** and the caption names the current output ("…“foo” currently becomes “barn”"). Duplicates
  disable the button but keep the composer populated (a clearly visible existing-entry status, never an error);
  a mode-local rule that overrides a global one adds normally with a caption naming the overridden
  output. Nothing here blocks — deliberate re-entry is answered with facts, not warnings.
  In the standalone correction panel, an already-saved replacement still allows **Add & Replace Selection**;
  the existing rule needs no write, but its correction is still applied to the selected text.
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
  or `Say “as an email” · Cloud rewrite`. Wherever a mode's shortcuts are shown, several are joined
  with “or” (`Fn (Globe) or Mouse Button 4 · On this Mac`), and a shortcut that repeats an earlier
  one on the same mode is not listed.

When a mode's file has an error, its editor is **read-only** and a notice above it names the file and the
parser message, with **Show in Finder**: the mode is running on its last working version, and saving from
Settings would replace the user's broken edit with that version. A key in the file that the app does not
read is named in an advisory above the editor, with a suggestion when it is close to a real key, since
editing it has no effect. Saving from the editor is refused until that key is fixed or removed in the
file, since the save would otherwise delete it; every other in-app save to such a file is refused the same
way, with a notice naming the file and key, and a sheet that refused keeps its draft open.

The editor presents a short **Mode summary** at the top. The editor is divided into progressive
sections:

1. **Basics** — name and enabled. (There is no "default mode" — the **Direct** system mode is the
   floor and owns Fn; bind Fn to another mode to change the everyday default. Direct's own editor is a
   reduced, mostly-locked form: shortcut + result handling only.)
2. **How to start this mode** — keeps the shortcut and **Press behavior** together, followed by an
   optional **Spoken phrase**. The combined press behavior is titled **Hold to talk; tap to toggle**,
   presenting the two supported actions in parallel. The phrase explanation says what the feature does
   and that the phrase is removed from the result. Add controls precede saved phrases. Plain Dictation
   uses the same shortcut structure and adds one concise explanation of its special fallback role.
   The shortcut well edits the mode's **first** shortcut and preserves any others. Additional
   shortcuts written in the mode's file appear here as a read-only **Also starts with …, configured in
   its TOML file.** note, naming an extra shortcut's press behavior when it differs from the first. The
   same note says when a later shortcut is ignored because it is the same press as an earlier one, or
   is listed twice. The conflict caption beside them names the shortcut it concerns whenever that is
   not the first, so a warning under the well is never misread as being about the well's key. A
   shortcut another mode already claims is reported as never firing, in red, even while the mode's
   other shortcuts keep it reachable; only a mode with no working shortcut is flagged in the list.
3. **Where it works** — states whether the mode is available everywhere or only in listed places.
   **Add app or website…** precedes saved places and offers running apps (with their icons), Choose from Applications…,
   Enter Bundle ID…, and **Website…**. Window-title regexes and raw URL patterns live under
   **More precise matching**. Availability is separate from the ways a user starts or selects a mode.
4. **What it does** — plain dictation, rewrite selected text, live edits, spoken symbols, numbers
   (inverse text normalization), and an always-visible **Recognition and replacements** summary. Its
   **Edit Vocabulary…** action opens Vocabulary with that mode selected. (Dictionary recovery is not
   a setting anywhere — it runs automatically whenever the mode's dictionary is non-empty.)
5. **Improve with AI** — disabled by default; connection, plain-language instruction, and the
   mode's **reusable writing instructions** (fragments): listed by name directly under the
   instruction they extend, reorderable (they append in order), edited in place in a popover, and
   added from a single menu of existing instructions or a new one. They appear only once an AI
   service is selected, since a fragment is appended to the rewrite instruction.
6. **Data sent with AI** — visible only after AI rewrite is enabled. Privacy and context are
   mutually exclusive by design; the UI makes the tradeoff explicit before allowing either.
7. **Result handling** — history exclusion, trim trailing punctuation, ending spacing, and read-only
   notes when TOML-only behavior such as a custom insertion method or submit key is active.

Plain Dictation stays deliberately small: the same header card as other modes (name, **Built in**, its
shortcut), then **How to start Plain Dictation**, **What it does**, and **Result handling**.
Its spoken-editing control explicitly names phrases such as “insert new line” and “scratch that”; it
does not imply an AI rewrite or a separate expert mode. What it does also carries the vocabulary row,
which says Plain Dictation uses Global vocabulary and whose **Edit Vocabulary…** opens Global.

**Voice Commands** (experimental, shown only while its flag is on) is a built-in mode. It ships
with no shortcut, and its list row reads `Off — no shortcut` until one is set. Its shortcut is never
shared with another enabled mode. Recording one that another mode uses — for Voice Commands, or Voice
Commands' shortcut for another mode — changes nothing until the user confirms “Use [shortcut] for
[mode]?”. The confirmation names every mode that uses it, says whether the press will run commands or
type speech afterwards, names a key given up under a different name (moving ⌘ takes Left-⌘), and says
which modes are left with no shortcut. On the first Voice Commands shortcut it also carries the
voice-command notice below. **Move Shortcut** removes only the clashing shortcuts from those modes,
keeps their others, and assigns it to the destination in one write; **Cancel** keeps everything. The
check is repeated against the files before writing, and if the modes using the shortcut changed in the
meantime, nothing moves and the pane says to try again. A failed write restores what it had already
written; if a restore also fails, the pane names the modes that could not be put back and shows the
files as they now are, instead of claiming nothing changed. After a move the pane shows “Moved
[shortcut] to [mode] from [modes].” with **Undo**, which stays only until one of those modes changes or
the pane is reopened. Undo rereads the files first and changes nothing if those modes were edited
outside Settings or if another mode has since taken a shortcut it would restore; undoing the repair of
a clash written by hand puts that clash back. Only a newly added
shortcut asks: an unrelated edit to a mode whose shortcut already clashes saves as before, but
recording a different taken shortcut on it still asks. A mode left without a shortcut is
not marked as needing attention; its row already says how it starts. Enabling a mode whose shortcut
clashes is still refused. A clash written into the files leaves the press with the other mode; the
Voice Commands editor says so and offers **Move Shortcut to Voice Commands…**, the same confirmation.
Speech on its shortcut is
never typed: a command it understands runs, one that matches more than one destination asks which one
(§5), and anything else shows an Error naming what was wrong (a command it did not recognize, with what was
heard; no match; or too many matches) and changes nothing.

Before first enabling Voice Commands in Maintenance, a notice titled **Using Voice Commands** explains
that the assigned shortcut switches apps and windows by voice, and users can add commands that run scripts
or Shortcuts. It explains that recognition can get a name or input wrong, bringing an unintended window
into view during screen sharing or starting an unintended saved action. Scripts and Shortcuts run by
voice may act without asking for confirmation and, depending on their steps, can change files, send
messages, or share information.
**Enable Voice Commands** accepts it; **Cancel** leaves the feature off. App names already work without
adding a command, so this notice does not wait for **Add Command…**. If the feature was enabled by editing
the config, assigning a shortcut shows the same notice before applying the shortcut. That acknowledgment
is remembered for this configuration across launches; resetting onboarding or configuration clears it.

Each command sheet carries guidance written for what that kind of entry can do (`VoiceCommandNotices.Kind`),
weighted by what it risks. An app, link, or tab search opens apps and links or switches windows and tabs, so its sheet ends
with a brief, neutral, collapsed **If a name is misheard** note (the wrong app, link, tab, channel, or mailbox
can open, which can bring the wrong content into view while sharing the screen) and never opens with a warning. A script runs
with your account's permissions and can change or delete files; a shortcut can send messages, change or
delete files, or send its input to online services, depending on its steps. A new script or shortcut sheet
opens with that warning expanded, each time, and also says a misheard name can start it; editing one shows
it collapsed below the editable fields and preview.

The editor uses the same grouped form, shortcut controls, vocabulary row, and Result handling vocabulary
as other mode panels. Copy leads with what to say and what will happen. Technical details stay in
collapsed disclosures. Add/edit sheets use a scrollable form with a fixed footer so validation and
Save/Cancel remain visible, even with an expanded notice or a long command. Add actions sit in normal form rows before saved entries, matching Triggers and
Where it works. Vocabulary likewise puts its composer before saved words and replacements. Persistent
master lists (Your Modes and Your Services) keep their bottom action bar.
Its sections are, in order:

1. **Start with a shortcut** — the same shortcut structure as Plain Dictation, labeled **Start shortcut**
   to distinguish it from actions in the Shortcuts app. There is no caption under it: the empty shortcut
   well already asks for one, and the header says what the mode does. Its shortcut can never be shared with another mode: recording one that another
   enabled mode uses (or giving another mode this one's) asks to move it, with Undo afterwards (see the
   Voice Commands paragraph above), and a shared shortcut written by hand shows a red caption here (“…
   also uses this shortcut, so it does not start Voice Commands”) with **Move Shortcut to Voice
   Commands…**, and marks the list row and the menu-bar badge as never firing.
2. **What you can say** — leads with what already works, as a few short examples that need nothing saved
   (`VoiceCommandsEditorView.examples`): “open Mail” (an app, window, or tab), “open Slack general” (something
   inside an app, shown only while **Find items in apps by voice** is on), and “go back”. The longer guide sits
   in a collapsed **More examples** disclosure: a **Your commands** row (say the name of a command saved
   below, then any words it takes), then one row per taught phrase (`VoiceCommandPhrase`, which also writes
   the “Not a command” guidance and the feature's summary): “switch to …” and “open …” for apps, places, and
   open windows and browser tabs by name, “run …” for scripts and shortcuts, and “go back”, which returns to
   the window or app you left. Other app-switching verbs, and common mishearings of them such as “witch to”,
   are also accepted (`VoiceCommandGrammar.focusVerbs`). These prefix alternatives work in live commands and
   Preview a command without changing the original heard text or action input; the panel continues to teach
   the standard phrases. “run …” is presented as optional: a saved action's name alone runs it, including a
   name that starts with an app-switching word (“open notes”); an app-switching word followed by anything
   that is not a saved name never does. Each row briefly explains the result. A caption explains that
   ambiguous commands offer a choice (click a row or use the start shortcut and say its number, or say
   “cancel”) and that an unmatched command is reported instead of typed.
3. **Preview a command** — a field that shows what a typed phrase would do, live, without running anything (a script
   shows the exact command line it would run, a shortcut its name and input). A phrase that would ask which one
   says so neutrally (“Would ask “Which one?””) and lists the numbered choices; it never invites an answer,
   since a preview creates no question to answer. It sits beside the phrases it
   tests and re-checks the typed phrase whenever a place, an action, or the vocabulary changes. When the mode's vocabulary changed the
   phrase, it shows `Read as “…”` above the result. The introduction explicitly says nothing opens or
   runs. **What the preview checks** is collapsed with a visible “May ask for browser access” summary;
   its content explains that matching windows and tabs reads titles, and checking tabs reads addresses
   and may request permission to control the browser.
4. **Commands** — every saved command in one list, in file order, whatever it does. A short introduction
   says a saved command is a name of your own for an app or link, or a script or shortcut to run; the empty
   state reads “No saved commands yet.” **Add Command…** offers outcome-named starting points: **Open
   Current App (name)** and, when that app is a browser that can list its tabs, **Open Current Browser Tab**
   (both read from the app that was frontmost when Settings opened); then **Open an App…**, **Open a Link…**,
   **Run a Shortcut…**, **Run a Script…**, a divider, and **Find a Browser Tab…** (a saved tab search, in any
   browser or one chosen). The outcome is chosen
   once, here: no sheet asks it again, and editing a command opens the sheet for its kind. Until the browsers
   on this Mac have been checked, a disabled **Checking browsers…** item stands where **Open Current Browser
   Tab** would be. Every starting point opens a normal command sheet that saves an ordinary entry in this
   list, edited from its row; there is no separate template lifecycle.

   Every sheet shares one shape: a script or shortcut's warning, **What should happen?** (the app, link, tab search's browser,
   shortcut, or program), **What will you say?**, then the optional input or arguments, and **Preview**; the
   technical details sit last. The target comes first so choosing it can suggest the spoken name, which
   follows the target until the user types their own.
   **What will you say?** has **Spoken name** with a caption saying what saying it does, and a collapsed
   **Other names (optional)** disclosure whose summary shows the names already set (or “None”), holding the
   comma-separated field and a caption suggesting one for a word that is often misheard; it opens itself when
   one of those names has an error. The tab search's spoken-name placeholder is “tabs”, since a browser's
   own name already finds its tabs. There
   is no setting for whether a name works on its own: every saved name does. Any phrase can be a name,
   including one that starts with a command word (“go home”, “open notes”). Below the fields, orange
   advisories (`VoiceCommandConfig.conflicts`) name concrete outcomes: a phrase another command already
   answers to (saying it will ask which one), a longer saved name that takes over some of what this command
   would receive (“slack joe” runs Slack Joe instead), a longer name that takes words away from an existing
   command that takes them (adding Note work beside Note), and a name that catches a built-in command word
   (“Saying “open …” will reach this command instead of switching apps. Say “switch to …” to switch apps.”).
   **Preview** is an example card, “You say” → “What happens”, for a sample utterance (“buy milk” for words,
   “inbox” for a tab search), read through the mode's replacements and checked against the other saved
   commands exactly as a live command would be (`VoiceCommandExample`). When a replacement or another
   command would send the sample elsewhere, or it would ask which one, the card is replaced by an orange
   advisory saying so, quoting what the replacements read it as. It shows only once the draft is
   valid. The same check runs on each **other name** the replacements rewrite, and a lost one is listed
   with the advisories below the fields (`VoiceCommandExample.namesLostToReplacements`). A sheet's title names the starting point when adding (**Open an App**, **Open a Link**,
   **Run a Shortcut**, **Run a Script**, **Find a Browser Tab**) and reads **Edit Command** when editing; its buttons
   are **Add Command**, and **Delete Command** in red at the trailing edge, with a confirmation.

   Each row leads with an icon: the app's own for an app, the chosen browser's for a web page or tab search
   (a globe for **Any browser**), a terminal for a script, the Shortcuts icon for a shortcut, and a generic
   symbol when that app is not on this Mac. Icons come from the installed apps only; no site icon is
   fetched. Each row's `Say:` line shows its spoken names, with `…` when it takes words (“Mail”, “web hooks”,
   “chrome …”, “deploy …”), then where it goes or what it runs,
   then a badge: **App**, **Web page**, **App link**, **Tab search**, **Script**, or **Shortcut**. A script row
   shows its command line and an orange advisory when the program is missing or not executable; a shortcut
   row shows the shortcut's name and input, and an orange advisory when that shortcut is no longer in
   Shortcuts. Any row also shows an orange advisory when your replacements send one of its names to
   something else, so a rule that takes a name away is visible without opening the command. Under the list sit the **Using Voice Commands** notice and a collapsed **Permissions and confirmations**
   disclosure explaining that macOS may request access when an action first controls another app or
   accesses protected data; Shortcuts can offer **Allow Once** or **Always Allow**, and actions can include
   confirmations on every run. A macOS dialog may name the app even when a script triggered it, and a
   permission granted through Terminal may not apply to a run here. The copy distinguishes those prompts
   from the app's own behavior: it starts actions without adding a confirmation, and some actions run
   immediately. An action that seems to be waiting may have an approval dialog open.

   **Open an App** has an **App** row; the app
   is chosen with the same app chooser as a mode's **Where it works** (running apps with their icons,
   **Choose from Applications…**, **Enter Bundle ID…**). The name follows the chosen app or page until the
   user types their own; for an app it is the name shown in the Applications folder, whichever way the app
   was chosen. **Open a Link** has a **Link** field: a web address or a link that opens an app (a chat channel or note link). For a web
   address the caption says it switches to an open tab whose address starts with it or opens the page, and a
   **Browser** picker follows; for an app link the browser picker and **Finding open tabs** are hidden, the
   caption names the app that opens it (“Opens this link in …. Open tabs are not checked.”), and an orange
   advisory says when no app on this Mac opens it. If the current tab cannot be read, the sheet opens on a
   link with that browser chosen and an orange advisory asking for the address. **Find a Browser Tab**
   says to say the name, then words from the tab's title or site, and has the
   **Browser** picker. Tabs that match equally well in one browser always switch to the leftmost match in its
   frontmost window that has one; only ties across browsers offer a choice. Navigation keeps the choice list to
   a minimum: sidebar items tied by name open the first in sidebar order, and a sidebar that could not be read
   in full still opens its match. Finding items inside an app needs **no
   setup** and has no control in the sheet: while the experimental **Find items in apps by voice** flag is on,
   an **Open an App** command's caption reads “Say this name to open the app. Add more words to find a tab, channel,
   mailbox, or other item in it.” (and “Say this name to open it.” while the flag is off). The same works for
   any app's own name after “open” with nothing saved. There is no item list, toggle, or read button in
   Settings; the sidebar is read only when such a phrase is spoken, and a failed lookup says what was searched
   and how to reveal more (expand a section or scroll the sidebar). **Preview** never reads a sidebar: it
   says the phrase would look in that app's sidebar, opening the app first if needed. The phrase fields
   also carry an orange advisory when a spoken name is also an installed app's name (a command named
   “sublime” that opens TextEdit while Sublime Text is installed), since the saved command silently wins.
   A spoken command whose sidebar open cannot be confirmed shows an orange advisory naming the item instead
   of the usual confirmation. Older sidebar commands open as ordinary app commands. The **Browser** picker lists every
   app that opens web links, including ones whose tabs cannot be read (their pages open directly), plus
   **Any browser**. While browsers are being checked, a caption says **Checking browsers…**, and **Any
   browser** or a saved browser stays selected; a refresh never changes a choice the user made. Entering
   Voice Commands, opening the sheet, or returning to KeyScribe while either is open re-checks the browsers
   once the last check is older than the installed-apps refresh window, so a browser installed moments
   earlier can still be missing until that window passes. **Finding open tabs** is a collapsed disclosure
   with a visible permission summary. It explains that it reads open tabs' titles and addresses, that **Any
   browser** checks every running browser that can list tabs, including private windows, and that macOS may
   request permission the first time a browser is checked. A field's problem shows beside that field, and
   **Add Command** stays disabled until the command is valid.

   **Run a Shortcut** is organized into **What should happen?** (the shortcut), **What will you say?**,
   **Input (optional)**, and **Preview**. The shortcut is picked from the user's shortcuts (stored by
   identifier, so renaming it in Shortcuts keeps it working); the name follows the chosen shortcut until
   the user types their own. The optional **Input** uses `{text}` to mark the spoken words. The preview shows the actual input, with and without spoken words. The picker includes
   **Refresh List** and **Open Shortcuts…**; empty and unavailable states explain how to recover. A caption
   says a shortcut may open an app or ask a question, advises checking for a dialog if it is waiting,
   and says its final result appears in History when saving is enabled for this mode. An existing
   shortcut's sheet holds the red **Delete Command** action, with a confirmation saying the shortcut
   itself stays in Shortcuts.

   **Run a Script** is organized into **What should happen?** (the program, a path
   field plus **Choose…**), **What will you say?**, **Arguments (optional)**, and **Preview**. Arguments go one per line, with
   `{text}` marking where the spoken words go. Beside the arguments it says the script should treat
   those words as input, not as code to run; the finer rules (blank lines, when words are
   needed) sit in a collapsed **How scripts run** section. The full-path field says pipes and redirects
   do not work there; the disclosure explains that the program runs without a shell or Terminal window
   and may need full paths or PATH set inside the script. The preview shows the exact command line,
   substitutes “buy milk” when spoken input is required, and never executes the program. **Add Command**
   and **Save** stay disabled until
   the name, program, and arguments are valid; an incomplete or conflicting entry explains what prevents
   saving. A program with a known interpreter file name (a shell or `env`, for example), or a wrapper such
   as `nice` around one, cannot take `{text}` in its arguments; the issue names the interpreter and points
   to choosing an executable script file instead. Saving an edit to a command that was
   deleted elsewhere is refused with a message, and the sheet keeps the draft; a rename elsewhere does not
   refuse it, because a command is edited by its stable id, never its name. A program that is not installed yet remains an advisory. An existing script's sheet holds the
   red **Delete Command** action at its trailing edge, with a confirmation.
5. **Recognition and replacements** — the same vocabulary summary and help as other modes, with
   **Edit Vocabulary…** opening Vocabulary on Voice Commands. Help explains that replacements apply
   before a command is read and can correct frequently misheard names or phrases.
6. **Result handling** — the same **Do not save this mode in history** toggle as other modes, off by
   default. Its help says saved commands include what was said, what ran (including input), and any
   error message, which may include text from a script or shortcut.

When privacy is enabled, context controls remain visible but disabled with the exact reason:
`Privacy mode sends only the redacted dictation. Context is off.` The user should not have to
wonder why a selection/context option disappeared.

### Permissions

Permissions appear where their capability is enabled and in their own unobtrusive Settings section
near the bottom of the sidebar. Each permission row states why it is needed, what works without it, and a direct
repair action; a missing permission makes that action the prominent trailing control. KeyScribe requests permissions just in time, never in a blanket
first-launch wall.

Accessibility's **Allow** (first run: **Grant**) first resets the app's own Accessibility entry, then
requests access. A grant made by a differently signed build of the same app stays displayed as on in
System Settings but no longer applies, and macOS will not prompt while that entry exists; the app cannot
see the entry, so the row says what the button does rather than diagnosing it: “If System Settings
already shows KeyScribe turned on, Allow resets that entry so you can turn it on again.” The reset runs
only on the click, only while access reads as not granted at that moment, and at most once per launch —
a later click only requests, so it can never delete a grant the running process has not observed yet.
If the reset fails, the row says to remove the entry by hand and offers Open System Settings. After a
reset, while access still reads as not granted, Settings offers Quit & Relaunch.

Once first run is complete, a launch that finds Accessibility missing when the previous launch had it
opens Settings on this pane. Without Accessibility the app cannot do its main job, and the red dot alone
does not say so; landing here is the whole remedy, not a wizard or a dialog. The rule keys on the grant,
never on the event tap: Accessibility granted but the tap not yet active is the just-granted state, and
the relaunch banner above already explains it, so nothing opens for it. It opens once per loss, not on
every launch: a launch whose previous launch also lacked Accessibility opens nothing, and the app cannot
tell whether that person declined the permission or has simply not repaired it yet — the menu-bar badge
and status line keep saying so either way. That is the accepted tradeoff against opening a window at
someone who chose clipboard fallback. A launch with no recorded verdict (an install upgraded from a
build that never recorded one) counts as lost and opens the pane once. Onboarding, not this rule, owns
a launch before first run is complete.

### Maintenance

Separates configuration, diagnostics, interface repair, experimental features, and the destructive
reset. (Notices live in the separate **About & Notices** window, not here.)

- **Reveal Config in Finder** opens the support folder (`~/Library/Application Support/KeyScribe/`,
  `config_schema.md`) so a user can read, edit, back up, or version the plain-TOML config
  directly. This is the answer to "where does my config live" — the files are hand-editable on
  purpose, and revealing the folder removes any need to know the hidden `~/Library` path.
- **Reload Configuration** re-reads the config from disk on demand (edits are also picked up
  automatically). Below it, each problem file gets its own entry: a title naming the file by its path
  (`Couldn’t read settings.toml` in red, `modes/notes.toml has a key nothing reads` in amber), a
  plain-language explanation by kind of failure (a formatting mistake near a line and column, a file that
  couldn't be opened as text, a newer version's file, a missing `schema_version`, otherwise a neutral
  "isn't valid for this app"; for an advisory, the unread keys themselves), what is running meanwhile
  (`The previous version is still in use.` / `Default settings are in use until it’s fixed.` / `It’s
  ignored until it’s fixed.` — and, for `settings.toml`, that app-wide settings changed meanwhile are
  temporary and are replaced when the fixed file reloads, while modes and vocabulary save normally), **Show in Finder** selecting
  that file, and a collapsed **Technical details** with the parser's message as selectable text.
- **Copy Diagnostics** puts a redaction-safe summary of the install on the clipboard for a bug
  report: version and revision, granted permissions, speech model, each mode's delivery settings,
  and the most recent dictation outcomes. It carries **no transcript text, clipboard contents, or
  API keys** — the projection from history drops every content field by construction, not by
  filtering. The same report is available headless as `KeyScribe --diagnose` (see
  `docs/troubleshooting.md`). A transient caption confirms the copy; there is no separate window.
- **Experimental features** lists one toggle per flag. A flag that builds on another sits indented under
  it and is disabled while that one is off. **Find items in apps by voice** sits under **Voice Commands**;
  its summary says what to say, what is read, and that some apps turn on their accessibility support to be
  read. Maintenance
  only enables experiments: there is no setup button here.
- *(Parked, not v1:)* a dedicated diagnostics/migration-error surface and a separate `models/`
  weights-folder reveal (the folder is reachable via Reveal Config today); plus an optional
  `KEYSCRIBE_CONFIG_DIR` override for users who keep config in a dotfiles directory — added only if
  asked for (`design.md` keeps Application Support the default; YAGNI).

---

## 8. History

History is a **Settings pane**, not a separate window — it is the audit,
correction, and diagnostics surface, reached via the menu "History…" / ⌘Y (which opens Settings
on the History pane) and the sidebar. It uses the same list/detail pane layout as Modes: a
left column with one compact History section for enablement and retention (moved out of General), a search field,
the day-grouped list, and the storage-truth statement pinned at the bottom; the right column is
the entry detail. The section uses the shared uppercase **History** header, followed by **Keep history
on this Mac** and the subordinate **Keep for** menu. These controls live only here — General has no
History section. **"Navigated away" equals "closed"**: leaving the pane (or closing Settings)
releases all parsed transcripts and the search cache, and re-entering reloads (signature-gated,
so it is free when nothing changed). "Paste Result" hides Settings, pastes into the previously
focused app, and closes Settings on success (re-presents + copies on failure).

History uses the standard immediate-apply Settings model. Retention is a menu of readable periods from
days through one year, so common choices such as two weeks or two months do not require repeated stepper
clicks. A shorter period confirms once only when it would remove existing day files; canceling keeps the
previous period selected. A longer period, an empty history, or a change that removes nothing applies
immediately without confirmation.

### List view

The list is grouped by day and supports search over locally stored text. Each row contains:

- final inserted text preview — or, when nothing was inserted (an edit-in-place take stopped by the
  recording limit), what was heard, in secondary text, so the entry the error pointed to is
  recognizable without opening it;
- time and mode;
- outcome (`Inserted`, `Copied`, `Local fallback`, or `Failed`; a voice command reads `Command`,
  `Command failed`, `Command started`, `Needs a choice`, or `Choice cancelled`);
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
enabled, which context categories were sent, and the raw cloud exchange as sibling disclosures:
**Show exactly what was sent** (the stored prompt) and **Show exactly what was received** (the
provider's reply, verbatim — before any output enforcement, so model misbehavior stays visible
rather than silently corrected). On a local-fallback entry the received view notes the reply was
not used. Redaction maps are never shown or persisted.

A **voice command** entry reuses the same detail: the comparison reads **Heard → Command**, where
Command is what ran — a script's exact command line, quoted the way a shell would so it can be copied
into a terminal, the shortcut and its input, or what a switch did. An action still running when it was
recorded reads **Command started** until it finishes, when the entry is updated to **Command** or
**Command failed**. An open History pane refreshes when that happens and keeps the entry selected, and
the entry can be deleted whether or not the pane saw the update. A command that asked which one is
recorded as **Needs a choice**, its result listing the numbered rows. A spoken answer is its own entry —
heard “two”, its result beginning “Selected Work Mail for “switch to mail”:” followed by what ran — so
the pair reads correctly even when other entries fall between them or a filter hides one. A spoken
cancel reads **Choice cancelled**, and a reply that was not an answer reads **Needs a choice** with the
standard instruction for answering (“Choose 1–2, say “cancel”, or give a new command.”), even when the
HUD showed what was heard instead. Clicking a row completes the question's own entry instead, since nothing was spoken; the
Cancel button marks it **Choice cancelled**. An idle timeout records nothing. A failed command adds a **Why it failed** row in Details explaining the
failure, and a script that reported a result adds a **Reported** row with the message the HUD showed. That row can say more than the compact HUD: an unrecognized command keeps the full “Not a
command. Say …” guidance there while the HUD shows only “Command not recognized” and what was heard. **Paste Result** is hidden for commands, since there is nothing to insert;
**Copy Result** stays. **Add to Dictionary** and **Create Replacement** on a command entry write to the
Voice Commands vocabulary, not the global one, since that is what reads commands. While voice commands
are turned off, a command entry shows no corrections, since that vocabulary cannot be seen or edited. The Voice Commands
editor carries its own **Do not save this mode in history** toggle.

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
  semantics. The Voice Commands choice (§5) is answered by voice, a row's number key, or a click, and
  **Esc** dismisses it; it has no arrow-key or Return selection.
  Its question, numbered rows with their details, status, and Cancel all carry accessibility labels,
  and a new question is announced once with its rows; a retained list is not announced again.
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
