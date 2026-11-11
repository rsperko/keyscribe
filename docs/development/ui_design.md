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

### Voice interactions and confirmations

A prompt adds another interaction to the voice workflow: read the question, decide, start recording
again, speak, and wait for recognition. Even a spoken “yes” adds interruption, latency, and another
chance of being misheard. A small dialog or a voice-answer option does not make that cost negligible.

Do not require a different mode or shortcut to answer a Voice Commands question. A necessary spoken
answer uses the same Voice Commands shortcut; ordinary dictation keeps its own purpose (see §5).
Do not require reaching for the mouse to complete a voice command. Reusing the shortcut preserves
consistency, but the additional recording cycle still needs justification.

Prefer clear intent in the initial command and explicit opt-in to a capability over repeated prompts
or first-interaction approval for every app. One-time enabling consent and confirmations for costly,
hard-to-reverse actions remain appropriate. A proposed prompt must explain the harm it prevents,
why predictable behavior or a clearer command cannot adequately address it, and the complete path
for answering it. Evaluate that path from the initial shortcut press through the final result.

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
be recorded.** The HUD is the visual half of the start cue (start/end sounds are optional and must
have equivalent visual feedback), so it appears at the same instant the cue ends — never at the press.
Speech that starts with the press is recorded too, from the moment the mic delivers, and the cue stays in
the recording, because cutting it out would cut the speech under it. A trigger is therefore acknowledged by *silence*: nothing is shown while
the microphone is brought up, which on a cold Bluetooth route is 200–500 ms (a built-in mic with
sounds off is ~50 ms and reads as instant). Recording is the first thing the user sees; a failed arm
shows Error with no HUD before it; a dictation released or cancelled during bring-up shows nothing at
all. There is no "arming"/"preparing" HUD: a panel that appears before the mic is live grants visual
permission to speak before anything can be recorded, and users react to the panel appearing, not to its
label. A modifier-only shortcut starts the mic as the key goes down, before its chord grace ends, so the
macOS microphone indicator lights briefly when that key turns out to be part of another shortcut; nothing
from that press is kept. A Bluetooth headset input is the exception: it starts when the press is confirmed,
because opening its mic switches it to call mode.

### HUD states

| State | Primary content | Secondary content | Available action |
|---|---|---|---|
| Ready (one-shot mode picked from the menu) | Mode name | “Next dictation” | None; replaced when recording starts |
| Recording | Mode name + a red level circle (halo + dot; Reduce Motion: intensity-only dot) | “Listening”, or “Listening — tap [trigger] again to stop” for a latched tap-to-toggle recording | Stop if tap-to-toggle |
| Recording (Coding agent mode, experimental) | “To [name]” for the frozen recipient (“To [name], disconnected” when it is a disconnected conversation in front), or “No recipient yet”, + the level circle | “Listening” as above, then the open sessions as numbered rows (name over agent and project, live state at the trailing edge, the recipient highlighted and marked Current), then one line saying where the recipient came from and how to name another | As Recording; rows are not clickable while recording |
| Recording, near the limit | Same, plus an orange ring around the level circle that drains to empty | “Stops in 0:SS”, counting down | As Recording |
| Transcribing | “Transcribing” | Mode name | Cancel when safe |
| Voice command opening an app | Mode name | “Opening [app]…” only while “open” starts an app, then “Looking in [app]…” while its tabs or sidebar fill; “switch to” never starts one, so never shows it | None; shown only once the command is acting, so it is not cancellable and does not take key focus away from the app being opened |
| Rewriting | “Rewriting with [connection name]” | Boundary badges: `Cloud rewrite`, then `Best-effort redaction` or the exact shared context categories | Insert without rewriting after timeout (the shortcut does the same once it is shown) |
| Complete | “Inserted” | Mode name, followed by “Spoken edits: …” naming the live edits that ran, each once in the order first used with a count when repeated (“Spoken edits: new line ×2, scratch that”), so a user can tell a spoken edit worked; it stays five seconds. A copied completion keeps its explanation first and names the edits after it | None; dismiss automatically |
| Target changed | “Copied instead of inserting” | “Focus changed while KeyScribe was working”, or “Accessibility is off — copied to the clipboard. Paste with ⌘V.” when the copy is due to a missing Accessibility grant | Paste last dictation (suppressed when Accessibility is off, since synthetic ⌘V can’t fire) |
| Stopped at the limit | “Stopped at the [limit] limit” (e.g. “5-minute”) | “Inserted without rewriting — dictate again to continue” when the mode rewrites, “Inserted — dictate again to continue” when it does not, or the copied explanation | Paste last dictation when copied |
| Rewrite fallback | “Inserted without rewriting” — or “Copied without rewriting” if the target also changed | A short cause, such as “The model reached its output limit while reasoning.”, or “Rewrite could not be completed” when none was recorded. History keeps the full reason and advice. When copied, the focus-change or Accessibility explanation comes first. Stays five seconds when it carries a reason | AI Service Settings… opens the affected service when the failure names one. Paste last dictation also remains available when copied and Accessibility permits it |
| Rewrite skipped | “Inserted without rewriting” — or “Copied without rewriting”; “Dictation failed” when the local text then could not be inserted | “You skipped the rewrite after 17.5 seconds.”, timed from when the rewrite started. The user chose this, so a delivered skip has its own neutral indicator, never success or failure styling; a failed delivery shows the failure styling first and keeps this line as context. When copied, the focus-change or Accessibility explanation comes first. Stays five seconds | No AI Service Settings… action. Paste last dictation remains available when copied and Accessibility permits it |
| Reasoning setting not applied | The completed state’s own title (“Inserted”, or “Copied instead of inserted”) | “Reasoning setting not applied.” followed by a plain explanation naming the service and model — e.g. “[service] didn't accept a reasoning setting for [model], so the model uses its own. Rewrites may be slower.” Stays five seconds | None. Carried by the completion itself — never a second, delayed HUD that a following dictation could cancel unseen — once per connection and model each time the app runs. Shown when a requested reasoning setting had to be dropped and the service did not confirm the model used no reasoning, when no lower level was accepted, or when the model reasoned with reasoning off. Also shown when an OpenRouter route could only be found without guaranteeing the setting. Never after a fallback, whose reason already says what happened. On a copied completion it follows the explanation of where the text went, which is read first |
| Voice command ran (Voice Commands mode, experimental) | Where it went — the app, the place and its browser (“Gmail · Google Chrome”), or the window and its app (“Budget — Numbers · Numbers”) — or the script or shortcut it ran (“Deploy”); a script that reported a result shows that message instead (“Switched to Inbox”) | “Voice command”, or “Started, still running” when the action has not finished; under a reported result, the script's name. A script's informational result (“Nothing waiting”) shows as an Advisory instead, with no failure styling. A window that closed, moved to another desktop, or could not be confirmed in front, and a search where some app did not list its windows, show an Error saying so (Accessibility off adds **Open Accessibility Settings**). A browser that refused control, and a script whose error output carries the Apple Events not-permitted code (`-1743`) on an error line, show an Error with **Open Automation Settings** (“Manager couldn’t control another app. Check Automation access for KeyScribe.”, followed by the script's denial line, which names the app that refused, even when later error lines follow); the button only opens that pane, never retries or asks again; if an action later fails, an Error naming the failure follows unless a dictation is in progress or a voice command choice is on screen, in which case History alone records it | None; dismiss automatically |
| Voice command needs a choice (Voice Commands mode) | “Which one?” for apps, places, and a script's own options, “Which action?” for `run` | Numbered rows, each a name over a detail that tells it apart (app, browser and host, app identity where names repeat, a window's app plus its document or site when two titles are the same, Script/Shortcut, or the name of the script that offered the option), then how to answer with the actual Voice Commands shortcut, led by one line when window rows still read the same (“Same name; the lower number is further forward.” within one app instance, else “Same name; these windows can’t be told apart.”) | Click a row; Cancel. Stays until answered, dismissed, or idle for the timeout |
| Voice command not recognized (Voice Commands mode) | “Command not recognized” | What the speech model heard, before any replacement: “Heard “stitch to Mail”” — omitted when the target was a password field or could not be confirmed | None; dismiss automatically |
| Voice command matched nothing (Voice Commands mode) | What found nothing: “No script or shortcut is called “sorb legs”.”, “No matching app, place, or window found for “kiwi”.”, or “No open tab matches …” | The heard excerpt, under the same rules as above | None; dismiss automatically |
| No speech (real audio, none spoken) | “No speech detected” | Mode name | None; dismiss automatically |
| Discarded by voice (live edits, “never mind” or “start over” ending the take) | “Discarded: nothing was inserted” | — (an Advisory: the user chose this, so no failure styling) | None; dismiss automatically. Nothing is written to History |
| Nothing heard (mic muted/dead) | “Nothing heard — check your microphone” | — | Open Microphone Settings |
| Error | Plain-language failure | Single next action | Retry, open permissions, Open Speech Models when the selected model is not installed, or dismiss as applicable |
| Config problem (idle, after an external edit) | “Couldn’t read [file] — [parser message] — previous version still in use” (or “— ignored until fixed”), or “[file] — “[key]” (did you mean “[key]”?) has no effect” | — | None; dismisses automatically |

**Config problems.** The HUD names only problems an external edit just introduced — each new unreadable
file or unread key once, never during a dictation. Settings → Maintenance keeps listing every current
problem until it is fixed, and an unreadable file also stays in the menu status. An unread key is an advisory, not a
failure: it shows with an info icon rather than the error triangle, and a batch that includes an
unreadable file shows as the failure. While a voice-command question is waiting, the announcement becomes
the question's note instead of covering the list.

**Recording limit.** A single take has a length limit, which can be shorter for a speech model that
loses accuracy on long takes (`design.md` §4.8); the countdown and the stopped-at-limit copy always name
the limit that applied. Reaching it ends the take
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
command; the latter reports “Stopped at the [limit] limit — Return not pressed”. A Coding agent take stopped
by the limit is never sent, since sending submits it: an Error says so and points to Paste last dictation for
what was captured. A Coding agent take whose microphone stopped never selects or opens a conversation either;
it reports that the command did not run.

**Coding agent session list.** A recording in the Coding agent mode lists the open sessions so the user
can address one. Its displayed and spoken name is the name the user sees for it: the user's KeyScribe
override, else what herdr shows on its pane (the pane title a herdr hook sets, else the pane's label), else
the name the user gave the agent in herdr, else the agent's explicit conversation name, else its herdr tab,
else its workspace, else a name generated from the project folder. The pane comes before the agent's own
name because that is what the user sees in herdr, and an agent's own name may be a title it generated. A
deliberate name for one conversation beats a place that can hold several. The same order applies to the
other places a conversation can run in, closest first: a tmux window the user renamed and a tmux session
the user named (only while tmux shows its status line, and a window name only while tmux does not let
programs rename windows), a Zellij tab the user renamed (a Zellij pane title follows the program's own
title, so it is not a name), a Ghostty
terminal or tab name the user set (a tab only in a window without splits, since Ghostty does not say which
split belongs to which tab), and an iTerm tab title the user set. A title a program writes into its
terminal is never a name, and a terminal app is read only when it already allows the app to script it,
so naming never asks for access: saying “open” and a conversation's name there once asks for it. A read of
the terminal app that fails or is not allowed drops only that app's names (keeping its last answer after a
failure) and never makes the conversation's place unknown. Terminal and Warp offer no name the user provably set, so they give none.
Each place is described in its own words (“tmux window backend”, “Ghostty terminal Architect”). A
conversation that runs in herdr inside a named terminal tab gets the herdr name first and the tab after
it. A read that fails keeps the names the conversation had; a conversation that never had a place answers
that it has none, so a failing read never holds dictation for a user who named nothing. A newly named
terminal tab is picked up within about ten seconds; a renamed one within a few.
A name around several conversations, such as a tab holding a tmux client with several agents, is a shared
label and asks. Two panes showing the same
title or label, and two herdr agents whose names sound the same (on separate herdr servers, or differing
only in punctuation), are qualified by their agents like a shared place label, and the bare name asks. Names use the same normalization as Rename. Duplicate names gain a
distinguishing word; an arriving native name never steals an existing handle. Native names and place
labels that cannot be addressed under the reserved row grammar fall through to the next source (a pane to
its tab, then its workspace) before the project. A native rename or a renamed place updates an unaliased
conversation for the next take; a KeyScribe override keeps winning. A tab still on its default number and
a pane never renamed give no name.

A tab or workspace label that covers several conversations names each of them by the label and its agent
(workspace `cos` holding a Claude and a Pi conversation gives `cos claude` and `cos pi`), and two of the
same agent then gain a distinguishing word. A conversation whose pane has its own label still counts, so
workspace `cos` with a pane named `pi` and one unnamed Claude pane gives `pi` and `cos claude`. Said bare,
such a label never picks one: “tell cos to run the tests” and “cos, run the tests” are held and ask
“Not sent: “cos” could be “cos claude” or “cos pi””, adding “Name the panes in herdr to tell them apart.”
when only a distinguishing word separates them. This holds for messages, open, and questions alike. Two
places with the same label, even on separate herdr servers, are one spoken label listing all of their
conversations, and so are two separate places with the same label, each holding one conversation (two
workspaces named `cos` give `cos claude` and `cos pi`, or a distinguishing word for the same agent). A lone
conversation under the label is just `cos`; when a second conversation opens there,
it becomes `cos claude` for the next take, and it keeps that name after the other closes, so the full name
the user learned keeps working (words after a name are the message, so “tell cos claude …” would otherwise
send “claude …”). The qualified name also survives restarting the app while the conversation runs. With
only that conversation left, the bare label reaches it. A new conversation that
opens alone under the label is `cos`. A disconnected conversation still counts.

Each conversation shows one name, and the other names the user deliberately gave it still reach it: its
herdr agent name and its pane label, which reach it like a name. A pane
titled `marvin` whose agent herdr calls `cos` is shown as `marvin`, and both “Ask Marvin what we should do
next” and “Ask cos what's outstanding” reach it; a particular agent named `cos` also beats a workspace label
`cos` several conversations share. A pane title that lost to a KeyScribe name, and the agent's own
conversation name when a herdr name took its place, may be text nobody chose, so they reach it only when
said in full after “tell”, “ask” or “open”; part of one is ordinary message text, because such names are
task phrases that everyday instructions start with. A tab or workspace label of one conversation that lost to a higher name
does not deliver: after “tell”, “ask” or “open” it holds, “Not sent: “chief” is the herdr workspace label of
“marvin”. Try “tell marvin, …”” (“ask marvin, …” when the user said “ask”), and History keeps the line without the suggestion, which appears only while
that conversation can take a message. Another name two conversations have asks which one, and one equal to
a conversation's shown name reaches that conversation. Renaming a conversation to another one's other name
is refused as taken. The conversation list shows the other names under the place (“Also answers to
“cos””), as does the Rename sheet after where the name comes from, and receipts, spoken replies and retry suggestions always use the shown name. A pane title is
display text a hook can change: a take uses the names frozen when its recording started.

Place labels are read in the background when a conversation connects, when the listed conversations
change, and when a recording that could go to a coding agent starts; while Settings is open they are also
read every few seconds while a conversation runs in a named place and less often otherwise. A tab renamed
since the last read takes its new name at the next recording, which reads the labels again. A take resolves
against the names frozen when its recording started, plus any new name a read during the recording gave
one of those same conversations: the recipient chosen at the start and the row numbers never change, and
a new name never takes a frozen one or adds a conversation. When the take is resolved while a read is
still running, it waits for that read up to a second. A take that would go to the current conversation
is held, “Not sent: couldn’t check conversation names yet. Say it again, or start with “tell” and a name or
conversation number.”, if the read still has not finished or the first read of one of the listed conversations has not
finished, because its first words may be a name that read did not deliver; a take that named a known
conversation goes ahead. A read that finishes but fails never holds a take: the conversation keeps the names
last read (or its remembered name), and Settings and the Rename sheet say “Couldn’t read its herdr names
since 3:42 PM. Using the names last read.” from the first failure until a read works again. So a pane renamed just before recording is reached by its new name. A failed read keeps the names last
shown, and so does a read that cannot tell which pane holds the conversation, for that conversation alone;
only a read that shows the label gone, or herdr reporting the pane closed, changes the name. After a
restart, a conversation keeps its remembered name until its place has been checked. A new conversation in the same pane gets
the pane's name once the old one has closed, and nothing else of the old conversation: its held messages,
spoken replies, disconnection and current-recipient status stay with the old one.
Automatically generated titles never rename the destination. For Claude Code, custom names are kept
separate from generated titles, and a fresh registry rename can supersede the last connector report. For
Pi, the name is the session name its user set (`/name`), as the connector reports it.
Each row's second line is the agent's title for the conversation, when it differs from the
name (one the user gave it, else the one the agent generated), and the project folder; the agent is named only when the list mixes agents. A connector that can
show it labels its own session with the same name (the name in quotes on the agent's status line, after the
connector's name, which Claude Code adds and the Pi connector writes itself), so the
terminal on screen can be matched to its row; the label is display only and never renames the agent's
conversation. The user can address a conversation by starting the take with “tell” and its name or its number (“tell docs run the
tests”, “tell conversation two …”); the “tell” (or “please tell”) is optional (“docs, run the tests”), and “conversation” or
“session”, which mean the same everywhere the spoken grammar takes that word, may come before a name as before a number (“session docs,
run the tests”, “open conversation docs”) — a sentence about sessions, such as “Session timeout is too short”, is
still a message, and a conversation whose own name starts with “session” or “conversation” matches whole first. A row number
always needs “conversation” or “session”, and “conversation two” is always row two,
even beside a conversation named two. A name made only of number words — the words a row number accepts,
including “to”, “too” and “for” — is reached only with “tell” or “open”, because a take that starts with a
number is ordinary prose: “One more thing: …”, “For the record, …” and “Two tests failed” go whole to the
highlighted recipient. A number never falls back to a row: “tell two …” or “open two” with no conversation
named two is held with “No conversation named “two””. A name with other words is matched without “tell”,
longest first, so with conversations named two and two bugs, “two bugs, run tests” addresses two bugs. That
has a deliberate cost: “Two bugs are left in the parser” is also an address to two bugs, with “are left in
the parser” as its message, just as “Backend is failing” addresses backend. No guess is made about whether
the name was meant; the session list shows the names, and renaming one avoids the clash. Names match the way Voice Commands targets do (`SpokenNameMatch`): the
whole name, a run of its words, or its words in any order, so “tell jk boots …” and “tell boots jk …” both
reach `foo-jk-boots-manager-1234`. The longest leading run of words that fits a name is the address, and a
comma or colon ends it. Each of the name's words counts once, so “tell build build the project” sends “build the
project”. After “tell” or “ask”, a word said in the singular or the plural matches either form in the name
(`AgentHandles.singular`), so “ask review manager …” reaches `reviews_manager_queue`; two names that differ
only that way count as the same name. Without “tell”, part of a name needs at least two of its words, and
words must match as written, because a single word at the start of a sentence is usually just prose. A take that starts with what sounds like an address
but does not match is held rather than sent to the highlighted recipient: “session to …” (a misheard
row) and a long word one sound away from a name (“keyscrib …”). One exception keeps the take: when that
misheard word sounds like the highlighted recipient itself, it is sent there, since both readings agree.
Without “tell” the whole take is sent, misheard word included; after “tell” the misheard address is removed
like any other. Otherwise the HUD says which name it sounded like.

When the name matches no conversation at all (“No conversation named “architect””), the HUD adds one retry
it would accept: “Try “tell keyscribe, …”” for a message, “Try “open keyscribe”” after a bring-forward word.
It names the highlighted conversation when that one qualifies, otherwise the first that does alphabetically. A
message retry offers only a conversation that can take a message now (its connector is live); an open retry
offers any conversation still running, since bringing a terminal forward needs no connector. Disconnected
conversations are never offered, and when none qualifies the line ends at the problem. A conversation is
offered under its current name, so a pane renamed during the take is offered by its new label, never the one
it left. Its Open Coding Agent
Settings button shows every name and renames a conversation; the spoken rename is not offered here, because
a mode with a fixed recipient renames that recipient, not the conversation in front. History records only
“No conversation named “architect””, since the names offered change as conversations come and go. A status
question about an unknown name never reaches this line: it is a message (see below).

“Ask” works like “tell” for a conversation's name or number (“ask docs to review the changes”, “ask session
two whether it is done”), and a name one sound away is held the same way. An unknown word after “ask” followed
by a question (“ask frontend what changed”, “ask frontend why it is stuck”: “what”, “whether”, “why” or “how”
not followed by “to”, or “if”, “when” or “where” followed by “it”, “they”, “he” or “she”) is held with
“No conversation named “frontend””, since it was plainly meant as an address. With “the” before the word the
take stays a message, as for any “the” that names no conversation (below), so “ask the team whether it is
done” reaches the recipient. A common adverb or a reflexive after “ask” is never taken for an unknown name, so
“ask again if it fails” and “ask yourself whether …” stay messages; after a bring-forward word or
“select” it still holds (“open first” with no conversation named first). Anything else after “ask” is an
instruction for the highlighted recipient, so “ask clarifying questions first” and “ask me before you push”
are messages, not addresses. After “tell” or “ask”, one “the” may come before the name (“ask the docs what
changed”) when the name is followed by a break: the end of the take, a comma or colon, or a word that starts
what is said to it (`AgentAddress` lists them, such as “to”, “that”, “whether” and “what”). Without a break
(“tell the docs run the tests”, “tell the session two run the tests”, “tell the backend team the API
changed”) it is unclear whether the name was meant, so the take is held and never sent to another
conversation: “Not sent: did you mean “docs”? Say “tell docs,” with a pause, or “tell docs to …””. When that
conversation is already the recipient, the whole take is sent to it as said. Words after “the” that name no
conversation (“tell the users that the API changed”) are the message for the highlighted recipient. A
conversation whose own name starts with “the”, or with an opening word such as “so” or “okay”
(“so long”), matches whole first.

An address that matched is always removed from the message, and a name that was said whole is never traded
for a longer one it sounds like: “tell keyscribe glue the adapters together” sends “glue the adapters
together” to keyscribe even when keyscribe blue is current. Short words are left alone without
“tell”, so “build the project” beside a conversation named `builds` is still a message. Words that fit several conversations at the winning address length and match tier go to the
first conversation alphabetically by its displayed name, whatever order the session list shows, except a
place label shared by several conversations, which asks (above). The
current recipient does not override that order. A whole-name match wins over a looser match at the same
address length. The receipt names the selected conversation, which becomes current; no choice is required
for an accepted tie. A first match that is no longer available is held, never replaced by the next one. The list is not a question: a take that does not start with a name or
number from the list sends to the highlighted recipient.
A take that is only an address, with nothing to send (“docs”, “tell docs”, “conversation two”), is held: it sends
nothing, leaves the recipient as it was, and the HUD says “Say “select docs” to choose it. Nothing sent.” A take
that is only “select” or “choose”, an optional “the”, and an address (“select docs”, “choose conversation two”,
`AgentAddress.selectVerbs`) makes that conversation the recipient, sends nothing, leaves every window as it
is, and the HUD shows “Recipient: docs”. It follows the bring-forward rules below for an address that names
nothing (held, never sent) and for more words after the verb (a message, so “select docs rows where active is
true” goes to the recipient as text). An unknown name after “select” offers “Try “select keyscribe””.
A take that is only “cancel” or “never mind” (`VoiceCommandGrammar.cancel`) cancels it locally and the HUD
says “Cancelled. Nothing sent.”; inside a longer take (“tell docs cancel”, “tell docs cancel the deployment”) it
is message text, which is how to send the word to an agent that asked for it.
An optional “please” before or after a recognized command (“please select docs”, “repeat that, please”,
“please rename this conversation to docs”) changes nothing, and an address followed only by “please”
(“docs, please”) is held with the select hint like an address alone.
A take that is only a bring-forward word and an address opens that conversation: the words Voice Commands
uses to bring something forward (`VoiceCommandGrammar.focusVerbs`, such as “open”, “switch to”, “go to”), an
optional “the”, then a name or number that meets the same evidence as an address without “tell” (“open
docs”, “switch to conversation two”). It makes the conversation current, sends nothing, and brings its terminal
forward. A bring-forward word followed by a few words (at most `AgentAddress.navigationWords`) is navigation
even when those words name nothing: the take is held with the reason and never sent, so a misheard name
cannot become a message. The held line names the closest conversation when one sounds like what was heard,
or the equally close ones, without opening any (`AgentAddress.closest`; the narrow sound-alike that
addresses is a separate rule and the only one that may open). “session” after a bring-forward word is
always a name, however long, so “open session zebra” is held, and so is “go to session backend review” when
only “backend” is a conversation: words left over after a name never turn the take back into a message. More words after the verb than that limit
make the take a message, as does a pronoun (“open it”), and the limit is fixed, so which conversations are
running never changes whether a sentence is navigation. An Open that moved focus remembers where the user was
as the one return destination Voice Commands keeps, so “go back” on either trigger returns there and toggles
as it does after a voice command. Where the user was is the conversation shown in the terminal the take was
pressed in, when the terminal can say which one (the same front reading that confirms an Open arrived,
`AgentFront`), otherwise the app and window. The reading names the app, process and window it was taken in,
and the conversation is attached only when those are the ones the take was pressed in, so a user who switched
apps, or windows of the same terminal, while speaking is remembered by the window alone, never by a
conversation seen somewhere else. A destination is recorded
only on evidence of movement: the window changed, or the conversation was selected exactly and differs from the
one left; an Open that brought nothing forward, selected nothing in the same window, found the user already in
front of that conversation, or was cancelled or superseded before it could tell, leaves the earlier destination
in place. Every switch that moves focus remembers the conversation it left the same way, whichever trigger
moved it, and a script run by voice reads nothing. Going back to a conversation opens it the
way Open does, through the same routes, under the take's own stop check (a stop also closes a terminal script
already queued or running, before its next Apple event), without making it the current
recipient, and the destination becomes the conversation the user just left, so two conversations in one window
toggle. A return the user stopped, or that the feature or a system sleep stopped, ends like a stopped voice
command and leaves the destination for another try. A conversation that has ended
or that nothing could show returns to its app and window instead; a terminal that came forward without
selecting the conversation reports that and keeps the destination for another try. A take that is only “go
back” in the Coding agent mode is that return, never a message: it moves focus and nothing else, keeps the
current recipient, sends no pending dictation, and reports what Voice Commands would (“Nothing to go back
to.” when there is no destination). “Go back” inside a longer take, or after “tell” and a name, is ordinary
message text. A take that is only “repeat that” or “say that again” (`VoiceCommandGrammar.repeatSummary`) is
the same kind of local command on either trigger: it replays the last spoken reply that started playing,
exactly as it was heard, ahead of any still waiting, and sends nothing. The replay waits in its own place
rather than the queue, so a newer result for the same conversation does not replace it and an unavailable
notice is never merged again with notices still waiting. It does not repeat the front check, since the user asked for it.
The HUD names the conversation (“docs”), or says “Nothing to repeat yet.” or “Spoken replies are off.”;
History records the command and adds no second copy of the line. Inside a longer take or after “tell” and a name it is
message text. A take that is only “rename this conversation to” or “rename this session to” a new name (“name this
conversation …” and “call this session …” work too) renames the take's recipient, with the same check
Settings' Rename uses (`AgentRename.parse`, then `AgentHub.rename`), and sends nothing. The recipient is
the one an unaddressed take would go to: the conversation in front when it is confirmed, otherwise the
current one; renaming makes it current. The feature is rechecked right before the name is saved. Only the current conversation can be renamed by voice, because
long, changing generated names are hard to say right for one in the background: switch to it first. The
name may run to `AgentRename.nameWords` words and is stored as it will be said (“auth 2” becomes “auth
two”). Once a take starts with “rename this conversation” (or session), it is never sent: no name, a longer one, or more words
after the name's clause ends (“rename this conversation to docs. Run the tests.”) is held with the reason,
so an instruction never becomes part of a name. A take without “this conversation” or “this session” (“rename this to
parseConfig”, “rename this function to parseConfig”) is a message for the agent, and the command is recognized from the words as heard, so replacements never
change it. The mode's local text stages (spoken edits, replacements, numbers), without the AI rewrite, then
run on the words after it before the name is read (`AgentRename.request`, then `AgentRename.name`): “never
mind” at the end discards the take (nothing in History), and “rename this conversation to docs, scratch that,
notes” names it notes. The HUD shows “Renamed keyscribe to auth refactor” long enough to read, so a misheard name is caught
and fixed by saying it again. A name another conversation holds, or a row name such as “conversation three” or “session three”,
is refused with the reason and nothing changes; with no recipient it says “Switch to a conversation, then
say the rename command again” with **Open Coding Agent Settings**. History records Rename, the conversation, the new name and how it was chosen. After “tell” and a
name it is message text.

A take that is only a question about what a conversation is waiting for is answered by KeyScribe and sends
nothing (`AgentStatusQuery`): “what is docs waiting for”, “what does docs need from me”, “is docs waiting
for me”, and the same without a name (“what are you waiting for”), which
asks about the take's recipient. “Blocked on”, “stuck on”, “why is docs waiting” (or stuck), “what is
blocking docs” and “does docs need anything” ask the same thing, and hold with more words after them like the
other forms. Contractions, closing punctuation, an
opening “please”, “hey”, “so” or “okay” (also skipped before “tell”, “ask” or a conversation's name, so
“hey docs, run the tests” addresses docs), “currently”, “still”, and a
closing “now” or “right now” are fine. More words after a question about a named conversation (“what does
docs need from me to continue”, or a second question after it) hold the take, since sending it would put a
question about docs to another conversation: “Nothing was sent. Say “what is docs waiting for?” to check on
it, or start with “tell docs” to send a message”. A longer question about “you” (“what are you waiting for before
merging”) and anything after “ask” and a name (“ask docs what it needs from me”) are messages to
that conversation, and “what is the build waiting for” names no conversation, so it is a message. “Tell docs …”
is always sent, which is how to ask the agent itself. The name must be a conversation's name or number; one
that sounds like a name is held. The answer says only what is reported,
in this order: the prompt's own question when it is short (“docs asks: keep the schema or add a migration?”),
read with the same redaction as a spoken reply, else a description from the chosen summary service (the HUD
says “Checking docs…” while it waits), else the state (“docs is waiting for approval”). The HUD adds “Say
“open docs” to see it”; speech leaves it out. A working conversation is “docs is working. No request for your
input is currently reported.”, an idle one “docs is ready for another message.”, and one that is not
connected is reported as last seen. So is one whose state was carried over because its agent's session list
could not be read: “docs was last seen waiting for approval. I couldn’t check its current status.” A description is used only while the prompt it describes is still the one
pending; if the prompt or state changed meanwhile, the answer is rebuilt from what is pending now. The answer
shows in the HUD, and is read aloud when spoken replies are on, even with the conversation in front; speech
that has to wait (for the dictation HUD, or while its audio is prepared) is dropped if what it reports
stopped being true, its state, prompt, connection or freshness, while “repeat that” still replays it as heard.
An answer replaces a notice about the same conversation that is still waiting to play or being described, so
the same news is not heard twice; finished replies stay queued. A conversation the user disconnected is reported as disconnected, with
**Open Coding Agent Settings**. “Who needs me”, “who's waiting for me”, “who is blocked” (or stuck),
“is anyone waiting for me”, “what is everyone waiting for” and “which conversations are waiting” count the conversations waiting for input, typed turns and conversations without a connector included, and
name them in recording order; a state carried over from an earlier check is not counted. When some agents
could not be checked, a state is carried over, or a conversation without a connector could be waiting without
reporting it, the answer adds “I couldn’t check every conversation.”, and with none to name it says “No
confirmed requests for your input.” instead of “No conversation needs you.”. Spoken, it is dropped if the
names or that completeness changed while it waited. Checking never changes the recipient. History records the
command and the conversation, never the answer.

With the Coding agent feature off, a remembered conversation is only its app and window. While
it looks, the HUD says so (“Opening docs…”). It follows the agent's processes outward and
selects each layer it passes through: the multiplexer pane showing the agent (herdr or tmux, for example — the
`PaneRoute`s in `TerminalRoutes`), then the terminal tab and split holding that pane (or holding the agent directly),
then the terminal app. Each multiplexer is one `PaneRoute` and each terminal app one `TerminalRoute`, listed
in `TerminalRoutes.routes`. Every route answers the same questions inside its own file, so nothing shared
names a particular terminal or multiplexer: what Open does for an agent it holds, and which of its views is
in front. Open's answer is ordered actions, so a terminal that must come forward before it can select a tab
says so itself. A
terminal that names each surface with an id its processes carry (cmux) is selected by that id, so it works
for every agent. When no process shows the agent's surface id, the agent's connector is asked instead:
KeyScribe asks it to focus its own surface, and only a connector that announced it can is asked. An older
connector says how to get there: “Brought cmux forward. Update the Claude Code connector in Settings, then run
/reload-plugins in docs to open its tab”. Every layer is found by something stable — a pane id, a tty, or the terminal's own
session link — never by matching a title, so Open never guesses a pane (`TerminalRoutes`). A terminal with
no route for its tabs, or one Open had nothing to look for (no session link, no tty), only comes forward and
says so (“Select docs’s terminal yourself”). The first Open into a scripted terminal asks for Automation
permission for that terminal, so a user who never says Open never sees the prompt; while macOS asks, the HUD
says what the access is for (“Allow access to Ghostty to open the tab for docs”).
The receipt stays short when it worked: “Opened docs” only when every layer confirmed its selection, and
“Asked Warp to show docs” when the terminal accepted a session link but cannot report which tab it chose.
Anything less says what came forward, what is still missing, and who the recipient now is — “Brought
Ghostty forward. Couldn’t find docs’s tab. Your recipient is docs”. The missing part names the layer that
fell short: the terminal’s tab, a multiplexer’s pane (“Couldn’t select docs’s herdr pane”, or “Couldn’t
confirm docs’s Zellij pane” when a session open in several windows cannot say which one moved), or a
terminal with no tab route, where the next step is the user’s (“Select docs’s terminal yourself”). These
stay up long enough to read. A multiplexer command counts only when it succeeded, or when its own answer
says the pane was already selected — never on an exit status another failure shares. When Automation for that terminal was refused, the HUD is an error with **Open
Automation Settings**, held long enough to use. Cancelling the take stops every pane, tab, or window change
KeyScribe has not started. A request already handed to a connector is best effort: it is withdrawn if the
connector has not collected it, and it carries an expiry, so a connector that collects it late (or after a
reconnect) refuses it instead of moving the terminal seconds later.
Anything after a matched address makes the take a message, so “open keyscribe and run the tests” is sent
as said, and so is a longer instruction after the verb (“open the readme and fix the typo”). A short one is
navigation: “open the readme” alone is held with “No conversation named “readme””, and “tell keyscribe open
the readme” sends it. A misheard name with nothing after it follows the address rule: held, unless it
sounds closely like the highlighted recipient, which is then opened. Words that fit several conversations
choose one as an address does.
Settings has no Open or Talk to button: Settings configures the integration, and choosing or opening a
conversation belongs where the user is already working.

A take that starts with a Coding agent mode whose target is the current recipient follows the conversation
in front: when recording starts, KeyScribe reads which conversation the front terminal shows, through the
same terminal and multiplexer routes that “open” and “go back” use, reading twice and checking that the app
stayed in front. Exactly one listed conversation must be confirmed there, in the app and window that had
focus at the press, for it to be this take's recipient. The read never asks for Automation access, so a
terminal not yet allowed reads as unknown. Unknown, no terminal in front, a different app or window, or a
front view that could belong to another session leaves the current recipient. The read runs beside the
recording, and a reading that lands more than a moment after release is ignored, however long transcription
takes. A spoken name or conversation number still wins and never waits for the read; a mode with a fixed
conversation or set to ask never follows the front, and neither does a take that reaches an agent mode only
through a spoken phrase after the press. A take sent to the conversation in front makes it the current
recipient. When the read lands, only the highlight and the recipient line change: the list keeps its order
and numbers, a list that scrolls brings the new recipient into view, and VoiceOver hears the new recipient
once.

The list opens with the current recipient first, then the sessions waiting for input (approval, an answer,
or an open dialog), then the other sessions; within each group the most recent comes first, where a
session's recency is the later of its last use and its start, so a session just started leads until
another is used after it; sessions with neither follow alphabetically (`AgentRoster.recordingOrder`). A session is used
when a take is sent to it, when it is chosen or opened by voice, or when the user submits a prompt in it,
which also makes it the current recipient; a prompt sent from another device through Claude Code's Remote
Control counts the same way. Slash commands and `!` shell commands never reach the connector, so they are not
use: they neither move the recipient nor reorder the list, and they do not hold a queued take for review. Settings keeps its list alphabetical: it is an inventory, not
an addressing surface. The recipient row is highlighted across the whole row with a subtle accent background and a semibold name. A separate
**Current** label stays visible even when the conversation title truncates; Ready, Working and other
live states remain at the trailing edge. The list is frozen when recording starts — numbers,
order, and names never change for that take, new sessions do not join it, and a session that ended keeps
its row marked Ended rather than handing its number to a neighbour. Live states update in place. A state
that means the session cannot receive (Not connected, Disconnected, Ended) is orange, and the
word itself says so, so colour is never the only signal. The recipient line says where it came from and never claims the screen identified a
conversation it did not: “The conversation in front of you”, “The last conversation you used”, or “Set by
this mode” — followed by a real example of both address forms taken from the list (“docs …” or
“session 4 …”; a bare “four” starts the message, and “tell four” reaches only a conversation named four). With no recipient, nothing is highlighted. A list
taller than the screen allows scrolls to the recipient each time recording starts, and keeps its numbers.
Live status changes do not scroll the list again. A session changing state
during the take is not announced again to VoiceOver. In the usual layout the level circle and title stay where
every other recording shows them: the panel keeps its usual width, and when the HUD sits at the bottom of the
screen the list opens above the header instead of below it. A recipient name long enough to wrap still grows
the header, and a HUD at the middle of a screen edge grows both ways, so its header moves. Wherever the list
sits, VoiceOver reaches the header first. Ordinary dictation never shows the list.

**Coding agent delivery.** A take is sent only to a conversation that is ready for it. While a turn is
running, the take waits and is sent when the turn finishes (“Queued for docs”, “Sends when it finishes”).
When the conversation is waiting on the user instead (an approval, a question, or a dialog), the take still
waits for the turn, and the receipt says what it waits on, how to respond, and what happens to the message
(“Waiting for approval. Say “open docs” to respond; this message stays queued”).
A take that would no longer fit what is on screen is not sent, and never sends later on its own: for
example, the user sent that conversation a message after the take was decided, its question was answered,
or its prompt box already holds text. The HUD says so, why, and how to recover (“Not sent to docs: its
prompt box already has text. Send or clear that text there, then say this again”); it never says who wrote
that text. Text already in the agent's prompt box is left exactly as it was, and what was said stays in
History. With **Read replies aloud** on, a take the conversation did not take is also spoken once, as a short
line naming the conversation and the reason (“docs didn’t take that: its prompt box has text”); what to do
stays in the HUD and History. It is spoken whether that happens at once or after the take was queued, and even with the conversation in front:
it is the only notice of a refusal that comes after the user has moved on. It waits like any spoken reply
while a recording is open, never reads the text in the prompt box or the take itself, does not replace or
get replaced by that conversation's replies, and is not added to History again.

After the user interrupts a Claude Code turn, Claude Code takes only a prompt the user enters until one is
sent, and refuses one the connector submits. The connector then puts the message in the prompt box, only
when the box is empty and only for that refusal; every other refusal leaves the box alone. When that
conversation is confirmed as the one in front, the app presses Return for the user and reports “Sent to
docs” once the connector sees the prompt arrive, or “May not have reached docs” when it does not. Otherwise
Return is never pressed and the advisory says the message is waiting (“Not sent to docs: its last turn was
interrupted, so the message is waiting in its prompt box. Press Return there to send it”). A spoken reply belongs to
that take only for the turn that starts right after the prompt the press sent, within a few seconds; when the
prompt is not seen before the confirmation runs out, when another prompt is typed first, or when no turn starts
(a slash command), no later turn is read as the take's. A connector that
could not fill the box reports “Not sent: docs’s last turn was interrupted, so it takes only a message you
type. Type one there, then dictate again”.

A take addressed to a conversation that is not connected, or that the user disconnected, says so by name
(“Not sent: docs isn’t connected to {app}”, “docs is disconnected”, or “The conversation in front is
disconnected”) with **Open Coding Agent Settings**, and never falls through to another recipient. A
disconnected conversation's name is still recognized for this, but it never appears in the numbered list.
"The conversation in front is disconnected" needs the conversation's terminal facts, which only a connected
conversation sends; one disconnected since before the app last started, in a multiplexer pane, may not be
recognized as the one in front, and the take then asks for a name.
A running agent whose connector has not connected has no name the app could match, so a spoken name meant for
it asks like any unknown name. While such a process is listed in Settings, a spoken name that matches no
conversation, or only sounds like one, says so with **Open Coding Agent Settings**, where the process's row says
what to do. When the name is that process's folder, or its whole description, only it is named (“Not sent: Pi in
reviews isn’t connected yet”); when several processes share that name, all of them are named and none is
picked (“Not sent: Claude Code in reviews and 2 Pi conversations in reviews aren’t connected yet”). The button
scrolls Settings to the first named row and highlights every named row briefly (no animation with Reduce
Motion); a row that has not appeared within a few seconds, because its process ended, is not waited for. Otherwise the line adds what is running but not connected, as Settings describes
it (the first two, then how many more), in place of the retry example (“… Pi in reviews is running but not
connected. Coding agent settings shows how to connect it”). It never connects, reloads or enrolls anything, and never sends to it.
What was said is kept for Paste last dictation, and connecting the conversation never sends it.

**The clipboard in a Coding agent message.** “Insert clipboard contents” and “insert clipboard as code” work
in a Coding agent message as they do in any dictation when the clipboard holds text. When it holds copied
files, the message gets their full paths; when it holds an image or a PDF, the app saves it as a file in the
temporary folder and the message gets that path. A saved file is deleted once it is a day old: by an hourly
check while the app runs, at launch, and on the next save. History keeps the message as sent, path
included. Paths are never put in a code block. Pi also receives the image itself with the message; Claude
Code opens the file from its path. Saying the phrase again before copying anything new reuses the file
already saved. When the clipboard's text is only a web address and it also holds an image, as a browser's
Copy Image can leave it, the image is used. The HUD says what went: “Sent to docs with 1 image” when the
image itself went with the message, “Sent to docs with the path to 1 image” (or “1 file” for a PDF) when only
its path did, and the same after “Queued for docs”. When the clipboard had nothing to insert, the message is
still sent with the spoken words in it, and the HUD says so as an advisory (“Sent to docs, but the clipboard
had nothing to insert, so “insert clipboard contents” went as words”).

**Voice command choice.** The list interrupts the user, so it is used sparingly (`principles.md` §4,
“Asking is a last resort”): navigation settles ties it can order by itself, and the list appears only when
no predictable default exists or a wrong guess would run the wrong action. When a command matches more than
one destination at the same step in those cases, the HUD asks instead of guessing. The user answers with the
Voice Commands shortcut (“two”, “the second one”, “the last one”, “cancel”) or by clicking a row. Another
mode's shortcut never answers: it closes the question and dictates as usual, so a list left on screen never
turns real dictation into a command. The list is frozen when it appears: rows never reorder or refill, and a chosen row
that has since disappeared reports that rather than choosing its neighbour. While answering, the list
stays on screen with the normal status (`Listening`, `Transcribing`) in place of its subtitle — never a
microphone-only HUD — and during microphone bring-up the question stays exactly as it was, so the timing
contract above still holds. A reply that is neither a number nor a command keeps the list and shows
what was heard in place of its subtitle (“Heard “tube””), without repeating the answer hint below the
rows; a number outside the list keeps the list and says which numbers are valid. The next answer
recording replaces that line, and nothing restores it afterwards. Silence, a failed transcription, or cancelling the answer recording also keep it; a failure that offers a repair (such as **Open Microphone Settings**) keeps the list and shows its message as the subtitle with the repair button beside **Cancel**. The question is
neither success nor failure, so it plays no cue. It is dismissed by an answer, spoken or clicked
**Cancel**, a new command, the idle timeout (`VoiceCommandRunner.choiceIdleSeconds`, restarted each
time the list is shown again), starting another mode, switching to an app other than the one the
command was given in (any app, when it was given in KeyScribe's own window), locking the screen,
sleep, turning Voice Commands off, or editing its saved commands. More matches than
`VoiceCommandChoice.displayLimit` offer no list: the Error asks the user to say more of the name.
A clicked row runs only if no new dictation starts while its destination is being looked up, and its
result appears once any interrupted answer recording has finished unwinding.
**Focus:** the waiting question never takes key focus, including when a row is clicked, so typing
keeps reaching the app the user was in; it holds key focus only while an answer is recording or being
transcribed, exactly like Recording. There is no keyboard selection — no number keys, arrows, Return,
or Escape for the list — because the answer is spoken (see §9).

Badges and explanations never truncate: the badge row wraps to as many rows as needed and the HUD
grows vertically (its per-state height is a minimum, not a cap).

**Heard excerpt.** An unrecognized voice command, a command whose script, shortcut, app, place, window,
or tab matched nothing, and an answer to a choice that was not understood, show what the speech model heard so a mishearing is visible at a glance. It is the raw transcript,
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

### The speaking panel

A spoken reply (§7 Coding agent) has its own small panel, separate from the dictation HUD and drawn with the
same card, appearance and anchor, at the dictation HUD's normal width (`SpeakingHUDLayout.width`) whether or
not the summary is shown. Its header shows a stop button, the exact name of the conversation being read with
"Speaking · Esc to stop" beneath it, and a small trailing chevron; a long name wraps within that width. The
stop button is a steady 16-point rounded square on a 26-point rounded-square halo, the same filled-halo
language as the listening indicator; while audio plays the halo's opacity gently rises and falls on a timer,
never its size, and under Reduce Motion it is static. The button's 30-point hit target never changes, and its
accessible label is "Stop speaking". The chevron's tooltip and accessible label are "Show spoken text" or "Hide
spoken text", and VoiceOver hears whether it is collapsed or expanded. The halo does not follow the audio level or
the voice.

Showing the spoken text adds the complete text the moment playback starts: exactly the words handed to speech,
after redaction and cleanup, without the spoken conversation-name prefix the header already shows. The text
wraps at the panel's width and is never truncated or highlighted word by word.
A subtle inset divider separates the expanded caption from the controls, with space on either side; it stays
at that boundary even when the caption scrolls and is absent when the caption is hidden. The divider and an
8-point gap sit outside the scrolling viewport, so clipped text never meets the divider; both are included
in the caption's height budget. The outer card padding also stays outside the viewport while text scrolls.

Showing or hiding the text changes only the panel's height, and never moves the stop button: the header keeps
its screen position and the text opens away from the anchored edge, the same way the Coding agent session list
does in the dictation HUD: above the header for a bottom anchor, below it for a top anchor, and below it for a
side anchor unless only above fits. The chevron points toward the text: down when it opens below, up when it
opens above, right when collapsed. The panel always stays within the screen. On a screen too short for the
whole text, the header keeps its place and the text area is capped to the space left and scrolls, so the
complete summary and the stop button both stay reachable; nothing scrolls on its own.

The choice is remembered across launches and carries to the next summary, whose text replaces the previous
one. Showing or hiding the text never restarts, pauses or changes playback, never clears the queue and never
takes focus. The text exists only while the panel shows it; it is never written to settings, History or logs.

The panel appears when audio actually starts, never while it is being prepared, and disappears when playback
finishes or stops. It never takes key focus. Clicking stop or pressing Escape, in either state, stops playback,
cancels audio and summaries being prepared, drops waiting summaries and hides the panel, leaving the feature on
for the next result. While the panel shows, Escape is consumed: it never reaches the app in front, so stopping the voice
can have no side effect there, and it reaches that app again the moment the panel hides. If Escape cannot be
claimed because another process holds it, the status line reads only "Speaking" and the stop button is the way
to stop. Starting a dictation hides the panel, and releases Escape, before the dictation HUD appears; a
waiting summary starts only once the dictation HUD has hidden again, so the two never share the anchor. The
dictation HUD appearing for any other reason, such as the acknowledgement for a mode chosen under Next
Dictation, likewise silences the summary being read and hides the panel; that summary is not resumed, and the
rest wait. There is no countdown or
waveform.

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
  auto-inserts the un-rewritten transcript early. Until the user acts, the rewrite keeps waiting, so a
  slow model can finish. Only the automatic limits in `design.md` §4.1 end it on its own (a service that does
  not connect within a few seconds, and the whole-rewrite backstop): a dictation then inserts
  the local text with the Rewrite fallback state and History records a reason naming the limit; a
  selection rewrite leaves the selection unchanged and shows the failure in the HUD, without a History
  record. Once **Insert without rewriting** is on screen, pressing the dictation shortcut does the same
  thing; before then a press is ignored with the busy cue, so dictating again right after a release never
  skips that dictation's rewrite. Escape and Insert without rewriting both cancel the request, and a reply
  arriving afterwards is discarded. Inserting without rewriting is a choice, not a failure: the HUD shows
  Rewrite skipped, and History labels the entry `Rewrite skipped` and records how long the rewrite ran.

### HUD copy rules

- Describe the current operation, not the pipeline stage number.
- Do not say “secure”, “safe”, “private”, or “protected” for best-effort redaction.
- Completion must report the actual outcome: inserted, copied, local fallback, or no result.
- A completed rewrite stays a success when its reasoning preference could not be applied. Amber
  rewrite fallback means the local text was kept instead. A fallback shows a short cause and, when
  its service is known, **AI Service Settings…** opens that named service. History retains the full
  reason and advice. The repair action does not replace **Paste last dictation** when paste is available.
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
Read Agent Replies Aloud ✓
Last Reply in History…

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

**Read Agent Replies Aloud** is shown only while the Coding agent feature is on. Its checkmark is the **Read replies
aloud** switch (§7 Coding agent), with the same effects: off stops playback and drops waiting and in-progress
spoken replies, on keeps the configuration and replays nothing. It needs no AI service, since notices are spoken
without one.

**Last Reply in History…** appears once a spoken reply has been saved to History in this session, and opens History
with that entry selected (§8), where its audio can be played again or saved while it is still held. Deleting that
entry hides the item; if History cannot find the entry, the status line says "That reply is no longer in History."

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
  while open and clears the flag the moment it's fixed. The menu-bar dot and the `Settings…` dot are
  driven by the sidebar's flags, never by a check of their own, so every refresh — including that poll —
  moves all three together and they cannot disagree. A config **advisory** — a key a config file
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
  chord grace makes pressing the larger one as a single motion start only that mode. The larger
  shortcut's well says so too, and so does a key-plus-modifiers shortcut whose modifiers include a
  contending mode's modifier-only trigger (⌥/ beside a Right-⌥ trigger): pressed slowly, the other mode
  starts and is then cancelled.
- Every shortcut well records the **character a key types**, not its position, so a saved chord may
  not exist on another keyboard layout. A chord the active layout cannot produce is never registered,
  and the well says so with a **Not on your current keyboard layout** caption rather than looking
  bound and silently doing nothing.

The warm-up tier lives behind a `Keep speech recognition ready` disclosure pinned above the model
list in Speech Models (collapsed by default; the collapsed row shows the current tier's benefit, such as `Fastest start-up`). Explain Fastest,
Balanced, and Frugal as a memory/first-response tradeoff (it governs the STT model's memory
residency, the natural voice that reads Coding agent replies, and idle microphone warm-up), not as cache
terminology. The footer copy **never shows a raw
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
Global vocabulary, rather than mixing inherited entries into its editable lists.
Modes and shared vocabularies may have the same name; each remains a separate selectable row and opens
only its own entries.

**Shared vocabularies** are named sets of words and replacements that selected modes use together
(mode-only overrides shared, shared overrides Global). Someone who never creates one sees the pane as
before, plus one **Add Shared Vocabulary…** action at the foot of the list. It creates an empty vocabulary
used by no mode under the first free placeholder name (**New Vocabulary**, **New Vocabulary 2**, …) and opens
its detail with the **Name** field focused, so it is named in place the way a blank mode is; leaving
without renaming keeps it, as a blank mode is kept. Shared
vocabularies are listed in a **Shared** group after Global, each with the usual count summary, or **Not used
by any modes** / **Used only by disabled modes** when no enabled mode uses it, so saved entries are never
mistaken for active ones. A detail's header names what it is — **Shared vocabulary** or **Mode
vocabulary** — so a shared vocabulary and a mode with the same name are never confused. A shared detail
starts with its **Name** field in an untitled group: Return or leaving the field saves a valid name,
Escape restores the saved one, a problem (empty, Global, or a name another shared vocabulary uses) shows
beside it, and a save that fails — such as a name another vocabulary took meanwhile — keeps the typed name
and says why beside it. **Choose Modes…** saves a typed name first, so its sheet shows the new name, and
stays closed with the problem beside the field when the name cannot be saved. Renaming keeps the
selection and every mode's connection; there is no rename dialog. Next comes **Modes using this
vocabulary**: the mode names, a disabled one marked
(“Email (disabled)”), then what that means (“Changes here apply to both modes.”, “Changes here apply to
Code now, and to Email when it is enabled.”, “Used when these modes are enabled.”, or “Not used by any
modes. Choose modes below to start using it.”), with **Choose Modes…**, then the
usual composer and lists; it ends with the standard trailing red **Delete Shared Vocabulary**, whose
confirmation names the modes it stops applying in and says Global and mode-only entries remain.
**Choose Modes…** lists every mode with its own vocabulary, disabled ones marked, and explains that
selected modes use its words and replacements and future changes apply to them; **Use in Selected
Modes** applies, **Cancel** changes nothing, and an empty choice is allowed. A new mode is never added
automatically; a duplicated mode keeps its choices. Removing a mode from it applies immediately and
keeps every entry; both choosers say so as soon as a mode or vocabulary is unticked (“Markdown will stop
using Programming. Global and mode-only entries will still apply.”), since a choice saved to settle a
disagreement is the mode's own and keeps working. A mode detail edits the mode's entries, not the mode:
its header offers **Edit Mode…**, which opens the mode in Modes, where its name and other settings live.
It then says what the mode uses (“Uses Global and Programming. Entries added below apply only to
Markdown.”); once a shared vocabulary exists, that line heads **Shared vocabularies used by this mode**,
listing each one it uses with **Edit…**, which opens that vocabulary's own detail, plus **Choose Shared
Vocabularies…**, whose sheet is titled for the mode (**Shared Vocabularies for Markdown Mode**) so the
destination stays clear when a mode and a vocabulary share a name. Headings name a group's purpose; none classifies settings as basic. The vocabulary sheets
(**Choose Modes**, **Shared Vocabularies for … Mode**, **Move to Shared Vocabulary**) take the same title,
description, validation, and trailing **Cancel** / primary action treatment as the other Settings sheets. Every change that could leave the shared vocabularies a mode uses disagreeing — attaching,
adding or editing a shared entry, or moving an entry into one — is checked against the state it would
leave, in every mode it reaches, before anything is saved. Saves from outside Settings (the Add to
Vocabulary panel, History's replacement review) pass the same check; a save there that would leave a new
disagreement is refused and says which vocabularies disagree about which phrase in which mode, and where
to settle it — the panel offers **Open in Settings**, which opens that shared vocabulary with the
correction already in its composer, so only the choice is left to make. Where two replace the same phrase or spell the
same word differently, the change shows **“pain” in Code** with one stacked choice per distinct entry: its
full output (**Replace with “pane”** or **Spell it “Kubernetes”**), its sources, and for a replacement
where it acts (**Anywhere in a sentence** or **Only when said alone**), so entries with the same output
but a different scope stay distinct. The chosen entry is saved whole, as an entry of the mode's own that
stays when the shared vocabularies change, together with the change itself; the change's one action
(**Use in Selected Modes**, **Use Selected**, **Move**, **Add**, **Save Changes**) stays disabled until
each disagreement has a choice. A chooser reopened over a disagreement left unsettled shows it again.
Attaching also describes, as a secondary line, any word or replacement that will replace Global's. The
choosers' lists and these choices share one area that grows with its content up to a bound, then
scrolls. A chooser or move saves its whole change in one step or nothing: if it cannot be saved the sheet
stays open with its choices and shows the standard failure notice — which file needs fixing, **Show in
Finder**, and technical details — and, only when putting back an already-written file also failed, says
which ones kept the change instead of claiming nothing changed. Editing a shared replacement that changed
elsewhere since the editor opened keeps the editor and its draft open and says so. There is no priority order to manage. A mode may still add its
own spelling of a word it inherits (**Overrides the spelling “Quorlan” from Programming in this mode.**).
A shared detail's rule preview, rule
check, and **Review mishearings…** run over the dictations of the modes that use it. A shared entry that
does not take effect in a mode using it says so beneath it — **Overridden in Markdown: there it becomes
“panel”.** (or the spelling, or where it acts, whichever differs) — with **Show in Markdown**, which opens
that mode's vocabulary with the overriding replacement's editor open, so a shared change that seems to do
nothing explains itself. A mode detail ends with a collapsed **Included Vocabulary** disclosure listing,
read-only, the words and replacements it inherits that are in effect there. Each source name (Global or
the shared vocabulary's) opens that vocabulary; each replacement says where it acts, and one too long for
its row offers **Show All** to read it whole in place. A mode's own word or replacement offers **Move to
Shared Vocabulary…** in its context menu and as an accessibility action, and the replacement editor shows
it beside **Cancel** (disabled, with a reason, while the editor holds unsaved changes). Its sheet picks an existing shared vocabulary or names a new one, then says
“Move this replacement to Programming?”, who uses it (“Programming is used by Coding agent and Markdown.
Future edits will apply to both.”), and what else the mode starts using; the mode is attached to the
vocabulary so it keeps the entry. A different entry already in the destination blocks **Move** and is
never overwritten. A vocabulary created for a move that then fails is removed again. Mode editors keep an
always-visible **Recognition and replacements** summary with an **Edit Vocabulary…** action; the full
composer and lists do not live inside the mode editor. That summary's help names the shared
vocabularies the mode uses.

- Add to Vocabulary: one compact composer with two labeled fields, **Word or heard phrase** (with an
  in-field example prompt) and **Use instead (optional)** — each field carries exactly one label, in
  Global, a selected mode, and the standalone panel. Leaving **Use instead** empty adds a
  dictionary word; filling it in creates a replacement. Adding a heard phrase that already has a
  replacement updates that rule in place — never a silent drop or a duplicate row. Entering a
  dictionary word that differs only in casing updates that existing word in place; the composer names
  the current spelling and uses **Update** rather than **Add**. The first field keeps focus after
  adding so repeated entries are fast. The composer's first level is just the two
  fields, the leave-empty hint, and the Add button; **Match heard phrase as a regular expression**
  lives behind the composer's **Advanced** disclosure (regex stays fully available, one disclosure
  away). When regex is on the first label becomes **Heard pattern**, **Use instead** is required, the
  composer can create only a replacement — the leave-empty hint disappears and only the regex help
  shows — and the disclosure stays open so an ON regex toggle is never hidden.
  **Use instead** grows from one line to a few on every surface. Global and mode Settings place **Open
  in a larger editor…** directly beneath the field for deliberate macro authoring; quick corrections
  in History and the standalone panel stay compact. A saved rule opens the **Edit Replacement** sheet with
  its multiline replacement editor already visible. Replacement content is
  stored exactly as authored (only the heard phrase is trimmed); the editor caps a single replacement at
  **65,536 characters** and refuses to save an over-limit draft rather than silently truncating it.
- **What a rule will do, before it is saved.** Where a rule acts is a default, not a question asked of
  every rule: an ordinary replacement fixes words inside sentences, and a new rule whose replacement
  ends in `<CR>` matches only when said alone. Existing rules keep what they do; editing one never
  changes it. The explicit override (**Anywhere in a sentence** / **Only when said alone**) sits
  under **Advanced**. When the composer or the Edit Replacement sheet holds a replacement, it shows, in
  order:
  - one sentence when the rule is not an ordinary word fix: **Matches only when said alone. Presses
    Return.** (or without the second sentence);
  - in the composer, for a new one-word rule that writes a lowercase word and whose plural has no rule
    yet, an unchecked **Also replace “pains” with “panes”** checkbox; checked, Add saves the plural as a
    second, ordinary rule that appears in the list. Rules are never widened at dictation time;
  - an advisory when a Return-pressing rule can act mid-sentence (**This rule also replaces words within
    sentences, where Return is skipped.**), shown whether or not History has an example, with **Only
    Match When Said Alone** beside it. That repair changes where the rule matches — the same setting as
    under Advanced — and takes effect on save; it never runs anything. It is distinct from **Match Whole
    Words…**, which stops the rule changing parts of words;
  - an advisory when the rule changes text inside other words, naming one example. For a regex rule,
    **Match Whole Words…** first shows the rewritten pattern, and **Use This Pattern** puts it in the
    draft. It is an advisory, not an error: a substring rule can be intended;
  - **Try a sentence**, directly below, which shows the result and whether the rule would press Return or skip
    the AI rewrite, so a rule can be checked with no History;
  - the rule replayed over the user's recent dictations in that scope, as one collapsed line that
    expands to the examples. An edit is compared with today's saved rules (**Saving this changes N of M
    recent dictations**), so a repair shows the damaged text coming back; a rule opened unchanged is
    compared with the scope without it (**Changes N of M recent dictations**). Warnings stay above the
    line, never inside it. A change in behaviour (Return, skipping the AI rewrite) counts as a change even when
    the words are the same. Each example names its mode and time, lists every changed span, and expands
    to the whole dictation; the first few show, and **Show All N Changes** lists the rest. It is labelled
    as local processing with today's settings, because an AI rewrite can still change the result. With
    History off it says there is nothing to check against.
- Dictionary: edit/remove saved words, import/export later only if needed. The first scan says only
  that terms use the intended spelling; model-specific recognition behavior and rewrite sharing live
  behind **How recognition works** inline help. Dictionary and replacement rows use the shared red
  trash action; deleting either opens an item-specific confirmation that distinguishes global entries
  from mode-only entries.
- **Find replacements in History.** Each Words to Recognize row lists the spellings the word already
  corrects (**Also corrects Cryden, Crayton**) and offers **Review mishearings…**, so teaching a name its
  next mishearing has one obvious place to return to. The action appears when readable saved History
  exists. The action moves below the word when they cannot fit on
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
  Adding a dictionary word, from the Vocabulary composer or from History, runs this search at once and
  opens the sheet only when it finds likely mishearings, so a new name is taught in one step. Opened
  that way, the sheet is titled **“{word}” added** and its dismiss button reads **Not Now**, because the
  word is already saved. A single suggestion is asked as one question — **Also correct “Cryden” to
  “Kryten”?** with its sentence and **Correct “Cryden”** — rather than a list to tick. Suggestions lead
  the sheet, followed by one line, **Selected spellings will always become “Kryten” in this scope.**;
  the replacement text and its scope sit in a collapsed **Replacement and scope** disclosure below, which
  opens itself when the text has a problem, and **Search options** follows it. With nothing found the
  sheet says **No other spellings found in saved History yet.** and how to teach the next mishearing.
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
- **History's Add to Dictionary never dead-ends on a known name.** When the selected words differ from a
  term already in Words to Recognize (select “Crayton”, enter “Kryten”), the sheet offers **Correct
  “Crayton” to “Kryten” from now on** with the one-line scope warning, and saves that literal correction
  through the same path as History's other corrections, instead of a disabled Add.
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
  A trailing pencil (and **Edit Rule** in a rule check) opens one **Edit Replacement** sheet, presented by
  the Vocabulary pane rather than anchored to the row, in the same treatment as the voice command editor
  sheets' title and padding, and is laid out so an ordinary short rule fits without scrolling: one compact
  group (**Heard phrase**, **Use instead** — one line that grows for multiline text, with **Open in a
  larger editor…** — and beneath them **Plain phrase · Use a regular expression**, or **Regular
  expression** with its capture help), then the rule preview above, then **Advanced** (the scope
  override). Fields span the sheet's width. The sheet is as tall as its content, so a short rule leaves no
  gap above the buttons; expanded examples scroll within a bounded height instead of growing the sheet,
  and **Cancel** / **Save Changes** stay fixed at the trailing edge below it. The character count appears only near the limit.
  **Save Changes** applies the fields atomically and preserves the rule's position; **Cancel** leaves the
  rule unchanged. If the rule changes or disappears outside the editor before saving, the sheet stays
  open and explains that it must be reopened instead of pretending the stale edit saved.
  Mode rules with the same identity override their included Global counterpart. Reordering changes only
  the tie priority between rules in the displayed scope.
  Each row's label line carries a right-aligned, single-line secondary-text usage caption (it truncates
  rather than wrapping, so it never adds height) so the user can see which rules earn their place:
  `Used in 14 dictations · last used Oct 19` (`today`/`yesterday` when recent), `Not used since added Aug 2`, or
  `Added today`. A rule that already existed when counting began has no known add date, so it never
  claims one: it reads `No uses recorded since <the day counting began>` (`No uses recorded yet` on that
  day). It counts dictations that reached their destination and that the rule actually affected — a
  match that left the words and the behaviour unchanged is not a use, and neither is one that changed
  only text inside other words — independent of History. It is
  read-only: rows keep the user's order because order is tie priority, and nothing is ever removed
  automatically. Below the row, an advisory names problems the rule caused as it is now: `Changed text
  inside other words in 6 dictations`, `Did not press Return in 2 dictations, because it matched
  mid-sentence`. Editing the rule starts these counts over (`Since you edited it: …`), so a fixed rule
  never carries an old warning; the use count carries over. These describe what happened when the
  dictations were made.
- **Check Rules Against History** (Automatic Replacements, when History exists) reads History again on
  every click, replays every rule in the scope over recent dictations with today's rules, says how many
  dictations it checked, and lists each rule that changes text inside other words or would drop its
  Return (even where the words come out the same), with one example and **Edit Rule**, which opens that
  rule's editor. With no dictations in scope it says there is nothing to check. It is labelled as what
  today's rules would do, not a record of what happened, and covers rules edited by hand. A hand-edited rule that cannot run at
  all (a pattern that does not compile or could take too long, or `<CR>` not at the end) is reported as
  a config advisory naming the file and rule; the rest of the file keeps working.
- **The composer says what Add will do before it is pressed in Settings, mode settings, and the standalone panel.** A live status directly below the relevant fields covers
  the non-obvious cases: a duplicate word ("Already in Words to Recognize", or "…already included from
  your global vocabulary" in a mode), an identical replacement, and an update. The button always says
  what it will save — **Add Word**, **Add Replacement**, **Update Word**, or **Update Replacement** — and
  an update's caption names the current output ("…“foo” currently becomes “barn”"). Duplicates
  disable the button but keep the composer populated (a clearly visible existing-entry status, never an error);
  a mode-local rule that overrides a global one adds normally with a caption naming the overridden
  output. Nothing here blocks — deliberate re-entry is answered with facts, not warnings.
  In the standalone correction panel, an already-saved replacement still allows **Add & Replace Selection**;
  the existing rule needs no write, but its correction is still applied to the selected text.
- **The standalone Add to Vocabulary panel is the quick correction surface, with the same behaviour as
  Settings and History.** It keeps two fields, the **Save to** destination, and the action row, with one
  hint beneath **Use instead** (**Leave Use instead empty to add a word.**) and no repeated explanation.
  Regex and the where-it-acts override sit under **Advanced**; the matching defaults, behaviour sentence,
  and Return advisory with **Only Match When Said Alone** are the composer's. A replacement shows one
  summary line (**Replace “Cryden” with “Kryten” in modes that include Global vocabulary.**), and the
  destination reads **Saved on this Mac.** followed by **Applies in modes that include Global
  vocabulary.** or **Applies only in {mode}.** Shared vocabularies follow the modes under a **Shared**
  heading; one reads **Applies in {modes}.**, adds **and in {disabled modes} once enabled**, reads **Saved
here. Applies once {modes} is enabled.** when only disabled modes use it, or **Saved here, but not
currently used by any mode.** The
  default destination is unchanged, so a correction never reaches more modes than before unless the user
  picks a shared vocabulary. It has no History preview. A word already added never
  dead-ends: it offers **Review Mishearings…**, and when the panel opened on selected words that differ
  from it (“Crayton”), **Correct “Crayton” to “Kryten”**. Adding a word runs the same mishearing review
  as Settings: it opens over the panel only when History holds likely mishearings, offered unchecked;
  otherwise the word is saved and the panel says **“Kryten” added**, that no other spellings were found
  yet, and how to teach the next one, with **Done**.
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
**Connection** holds credentials, then **Model** leads directly to **Test Connection** and its result.
**Connection options** and **Rewrite settings** follow, then **Used by** and the separate delete action.
The latest test result remains in the header and beside the test action.

- Known providers keep their type, endpoint, and authentication mechanism out of the first scan.
  **Connection options** reveals changing the service type; Custom then exposes the endpoint and
  **No Auth**, **API Key**, or **Command** mechanism. Hosted presets pin their own URL and use API keys.
- API key state is singular: **API key saved** + **Replace key…**; no saved key + field + **Save key**;
  or an unsaved key + enabled **Save key**. Command shows its field and an inline required-state message.
  Generated tokens stay in memory only.
- **Model** — model id is always visible. Fetching models is a helper; when fetched models exist, a
  visible picker selects one while the chosen id remains visible in the model field.
- **Connection test** — user-initiated only, disabled until the visible prerequisites are met. A passed
  test adds one secondary line naming where reasoning landed for this model (“Reasoning: Off”,
  “Reasoning: Low — the lowest this model accepts”, “Reasoning: Off — requested; the service doesn't confirm it”), so
  a model that would not lower its reasoning is visible before the first dictation.

Keep API parameters out of the first scan. Endpoint and authentication configuration live under
**Connection options**. **Reasoning** and **Minimum output allowance** live under **Rewrite settings**;
its summary names the reasoning choice. They
are not gated on a passed test, because a model that reasons too much is exactly the case where the
connection only half works.

- **Reasoning** — **Recommended — least reasoning** (the default) asks for the least reasoning the model accepts and
  may land on a low level rather than off; **Model default** sends no setting. Between them, only the
  levels the service lists for the selected model, when it publishes that (fetched with the models);
  otherwise the full vocabulary, with the row reading “Supported levels unknown” and help saying that a
  level the model rejects stops the rewrite and says so. A chosen level is used exactly or the rewrite falls back with
  that reason — it is never silently swapped for another level. A stored level the model does not list
  stays selectable and reads “Not listed for this model”. A model that always reasons says so.
- **Minimum output allowance** — the base room for the rewritten text, a whole number of at least 256,
  with **tokens** beside the field. The caption explains that the app increases the allowance for longer
  dictations and reasoning, and suggests increasing it when rewrites are cut off.
  Long dictations are given more, and extra room is added whenever the model may reason; a ceiling the
  service publishes for the model is shown and never exceeded. A ceiling saved for one model or endpoint
  is dropped when either changes, rather than applied to the new one. An entry that is not a valid number
  marks the section like any other error, and the caption names the value rewrites still use.

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
  one on the same mode is not listed. Stop-only shortcuts are omitted from these start/routing summaries.

When a mode's file has an error, its editor is **read-only** and a notice above it names the file and the
parser message, with **Show in Finder**: the mode is running on its last working version, and saving from
Settings would replace the user's broken edit with that version. A key in the file that the app does not
read is named in an advisory above the editor, with a suggestion when it is close to a real key, since
editing it has no effect. Saving from the editor is refused until that key is fixed or removed in the
file, since the save would otherwise delete it; every other in-app save to such a file is refused the same
way, with a notice naming the file and key, and a sheet that refused keeps its draft open.

The editor presents a short **Mode summary** at the top. The editor is divided into progressive
sections:

1. Name and **Enabled**, together in an untitled group directly under the summary. (There is no "default mode" — the **Direct** system mode is the
   floor and owns Fn; bind Fn to another mode to change the everyday default. Direct's own editor is a
   reduced, mostly-locked form: shortcut + result handling only.)
2. **How to start this mode** — keeps the shortcut and **Press behavior** together, followed by an
   optional **Spoken phrase**. The combined press behavior is titled **Hold to talk; tap to toggle**,
   presenting the two supported actions in parallel. The phrase explanation says what the feature does
   and that the phrase is removed from the result. Add controls precede saved phrases. Plain Dictation
   uses the same shortcut structure and adds one concise explanation of its special fallback role.
   The shortcut well edits the mode's **first** shortcut and preserves any others. Additional
   shortcuts written in the mode's file appear here as a read-only **Also starts with …, configured in
   its TOML file.** note, naming an extra shortcut's press behavior when it differs from the first; a
   stop-only shortcut is listed as **Stops with …** instead. The `start` and `stop` press styles are
   TOML-only: an existing value appears as read-only **Start only · configured in its TOML file** or
   **Stop only · configured in its TOML file**, replacing the press-behavior picker while leaving the
   shortcut well editable. The same
   note says when a later shortcut is ignored because it is the same press as an earlier one, or
   is listed twice. The conflict caption beside them names the shortcut it concerns whenever that is
   not the first, so a warning under the well is never misread as being about the well's key. A
   shortcut another mode already claims is reported as never firing, in red, even while the mode's
   other start shortcuts keep it reachable; an unshadowed stop shortcut does not make a mode reachable
   from a start key. A shared shortcut with opposing start/stop actions gets its own advisory: the
   first registered binding determines the action, and the user should choose different shortcuts.
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
Its spoken-editing control explicitly names phrases such as “insert new line”, “scratch that”, and
“never mind”; it
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
2. **What you can say** — a brief introduction (“Open apps by name. Nothing to configure.”), then short,
   concrete examples (`VoiceCommandsEditorView.examples`): “open Mail” opens Mail or brings it forward,
   “open Slack general” opens general in Slack (shown only while **Find items in apps by voice** is on),
   and “go back” returns to where you were. A caption then draws the one distinction a user must know
   (“Open” can start an app. Use “switch to” to stay with what’s already running.), and a final caption
   says a command saved below is reached with “open” and its name for a place, or “run” and its name for a
   script or shortcut. There is no expanded phrase guide here. Spoken input is explained beside the script and
   shortcut input controls; choosing a match is explained in the choice panel when it appears. The FAQ
   carries the fuller phrase reference, including “switch to …” and “run …”. Alternative verbs
   and their common mishearings (`VoiceCommandGrammar.focusVerbs`) still work in live commands and Preview
   a command without changing the original heard text or action input. A saved name never acts on its own:
   a place, link, or tab search follows “open” or “switch to”, and a script or shortcut follows “run”, so a
   name that starts with a verb or matches a built-in phrase cannot take it over. A saved name said alone
   runs and opens nothing and says the phrase to use (“Say “run new note buy milk” to run it.”). A take that
   is only “cancel” or “never mind” runs nothing and says “Cancelled. Nothing ran.”, and an optional
   “please” before or after a recognized command (“please open Mail”, “repeat that, please”) changes nothing,
   except that a closing “please” stays in the words a script or shortcut that takes words receives. A name a
   place and a script share offers both verbs (“Say “open docs” to open it or “run docs” to run it.”), and a
   bare saved name while a numbered choice waits keeps the choice and asks again.
3. **Preview a command** — a field that shows what a typed phrase would do, live, without running anything (a script
   shows the exact command line it would run, a shortcut its name and input). A result is two short lines: the
   outcome (“Switch to Gmail”, “Open Example Page”, “Run Deploy”) and what kind of thing it is and where (“Window
   in Brave Browser”, “example.com in Google Chrome”). An app reads “Open Slack” / “App · starts it if needed”
   only when the phrase would start it; a running app, or any app after “switch to”, reads “Switch to Slack” /
   “App”. “Switch to” naming something that is not open shows “Nothing to switch to” with the phrase that
   would open it. “Open” searching a browser that is not running cannot be checked, since the preview starts
   nothing: it reads “Open Chrome and find “github”” / “Chrome isn’t running, so the preview can’t check its
   tabs.”, never a missing tab. Window and tab titles carry whatever their app appends, so
   the outcome names the parts of the title that hold the words the phrase used. A script's or shortcut's command is
   shown in full. When the outcome shortened a title or a saved page shows only its site, a collapsed **Details**
   disclosure under the result holds the full title or address, reachable by keyboard, and only then is the outcome
   cut to one line; otherwise it wraps, so every name stays readable without hovering. A phrase that would ask which one
   says so neutrally (“Would ask “Which one?””) and lists the numbered choices one per line, each name in full
   (wrapping when long) beside the context that tells it apart (app, browser, or site); it never invites an answer,
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
   is no setting for whether a name works on its own: none does, since every saved name follows its verb
   (“open” for a place, “run” for a script or shortcut, which the field captions say). Any phrase can be a name,
   including one that starts with a command word (“go home”, “open notes”). Below the fields, orange
   advisories (`VoiceCommandConfig.conflicts`) name concrete outcomes among commands reached by the same
   verb: a phrase another command already answers to (saying it will ask which one), a longer saved name that
   takes over some of what this command would receive (“run slack joe” reaches Slack Joe instead), and a
   longer name that takes words away from an existing command that takes them (adding Note work beside Note).
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
   says to say “open” and the name, then words from the tab's title or site, and has the
   **Browser** picker. Tabs that match equally well in one browser always switch to the leftmost match in its
   frontmost window that has one; only ties across browsers offer a choice. Navigation keeps the choice list to
   a minimum: sidebar items tied by name open the first in sidebar order, and a sidebar that could not be read
   in full still opens its match. Finding items inside an app needs **no
   setup** and has no control in the sheet: while the experimental **Find items in apps by voice** flag is on,
   an **Open an App** command's caption reads “Say “open” and this name to open the app. Add more words to find a tab, channel,
   mailbox, or other item in it.” (and “Say “open” and this name to open it.” while the flag is off). The same works for
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
   field plus **Choose…**), **What will you say?**, **Arguments (optional)**, and **Try it**. Arguments go one per line, with
   `{text}` marking where the spoken words go. Beside the arguments it says the script should treat
   those words as input, not as code to run; the finer rules (blank lines, when words are
   needed) sit in a collapsed **How scripts run** section. The full-path field says pipes and redirects
   do not work there; the disclosure explains that the program runs without a shell or Terminal window
   and may need full paths or PATH set inside the script. **Try it** combines editable **Sample words**,
   a compact preview of what the person would say and what would happen, and **Run Once** in that order.
   The sample starts as “buy milk” and updates the preview as it is edited; the preview still checks spoken-name
   conflicts and replacements. Long command text is limited to two lines, with the full text available on hover
   and the program path still editable above. The preview itself never runs anything. **Run Once** runs the draft through the same resolver and
   runner a spoken run uses — the same program, arguments, environment, working folder, report window,
   choice handling, and choice limit — with the same **Sample words** standing in for the spoken part
   (required, and the button stays disabled without them, when the arguments use `{text}`). Its caption says
   plainly that the program really runs and that closing the sheet does not stop a script still running.
   The result shows what the HUD would: the done or info message, the failure, “Started, still running”
   followed by the late result, or the offered choices as buttons that run it again with that choice. Results
   appear below the run button and scroll into view when they arrive, without moving keyboard focus. A
   collapsed **Details** section always holds the program, working folder, PATH, exit status, and the
   script's output and error streams, each capped separately and marked when cut; they are kept in memory
   only. Each result belongs to the draft and sample words that produced it: any edit clears it, along with
   its choices, even while the run is starting. **Run Once** stays disabled until the script it started
   ends, even when an edit cleared that result, so one press never overlaps another script's side effects;
   a script that never ends keeps it disabled until the sheet is reopened. Details give the exit status, or
   “Not started” when the program never ran. **Add Command**
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

**Coding agent** (experimental, shown only while its flag is on) opens, after its shortcut, with **What you
can say**, built like the Voice Commands section of that name: one introduction (“Start with “tell” and a
conversation’s name to send it an instruction.”), then short examples with what each does
(`CodingAgentPhrasesSection.examples`): “tell” and a name with an instruction, “select” and a name, “open” and a
name, “what is” a name “waiting for?”, “who needs me?”, “go back”, “cancel”, and “repeat that” only while
**Read replies aloud** is on. The examples use the name of the conversation the
guidance below would use, a placeholder when there is none, and “conversation two” while names are unavailable.
Captions then say where an instruction without a name goes, that the numbers shown while recording can be
said as “conversation” and the number, and how to rename a conversation by voice. Every example is one the
take's own parsers read as described, checked by test. It then puts an always-visible
**Conversations** section before connector setup. One block shows **Current recipient: {name}** or
**No current recipient**, with brief guidance underneath. With no recipient and a connected conversation,
the example uses a real name and the mode's first recording shortcut (“Use Fn (Globe) and say …”, which reads
right whether the shortcut is held or tapped); when none is assigned it says to
start recording without inventing a shortcut. With a current recipient it explains that
instructions go there unless another conversation is in front, and another name switches the recipient. Compact rows follow, each its own native row of the grouped form (native insets and separators). Rows carry no numbers: Settings is an inventory, not
an addressing surface, so row numbers appear only on the recording HUD, where “conversation two” is said and the
numbering is frozen for the take. Each row is identified to assistive technology by its conversation name.
The first line holds the name, Current and the text-only live state, with small, native bordered actions
visibly distinct from the status labels. Actions stay aligned at the trailing edge; the name wraps within
the remaining space to two lines and its full text remains available on hover. When the heading is too
narrow, the state moves below the name while the actions stay on the right. The context line shows
the directory on the left and the terminal/multiplexer on the right, with the agent type before the
directory only when the list contains different agent types. The directory abbreviates the home folder
with `~`, truncates in the middle when needed, and exposes its full path in a tooltip. Clicking it copies
the full, unabridged path; it is a `CopyableValue`, whose copy icon briefly becomes a checkmark without moving the row. The directory
is a keyboard-accessible button named for its conversation. There is no action menu, details popover,
session id or process id in these rows. Conversation titles remain available to the recording HUD:
the title is the one the user gave the conversation, reported by the connector, else the title
Claude Code generated, read best effort from the end of the session's own transcript (only the title is kept,
and it is never logged); a brand-new conversation has neither yet. An empty
list explains how to open a conversation instead of inventing a name to say. Choosing or opening a
conversation is done by voice (see the Coding agent session list in §5), and
the current one is marked Current. The guidance names only what can be said. The list remains available
while connector setup is unavailable, so a connected conversation never disappears behind installation
status or a collapsed disclosure.

**Spoken replies** sits between the conversations and connector setup, and its everyday view is three rows
and one disclosure. **Read replies aloud** is its own switch, off by default, with "Hear replies to messages
you dictate or ask the agent to read aloud, and know when it needs you." as the row's always-visible caption. Its help explains
that replies are skipped while the conversation is in front, how short replies and longer summaries differ,
and that it also announces approval requests and disconnections. It reads a reply or summary when a turn
the user's dictation started finishes, or a turn the user asked from inside the agent to hear, and a notice when it
needs attention (below). Replies waiting together are read in the order the turns were asked for, not the
order their summaries finish. A turn that ends with an error is announced as "Ended with an error.", one the agent declines
as "Couldn’t complete the request.", and one that ends without a reply, or ends while its connector is away, as
"Replied. Open the conversation for the result." (`SpokenResult.ending`); a turn the user interrupts is not announced.

A request to read a reply aloud comes from the agent's connector: a tool the model calls when the user explicitly asks
for it, or the connector's own command (`/keyscribe`, `/keyscribe cancel`, named for the connector). It covers the turn
running, or the next one when the agent is idle, and only that turn. A requested turn that finishes with no text to
read is announced as "Finished without a written reply. Open the conversation for the result." Asking to hear a turn
whose wait was skipped because the conversation was in front announces that wait then; one already queued or heard
is not repeated. The app answers whether spoken replies are on, so
the agent never claims a request that was not accepted; with the switch off nothing is armed for later. The request
lives in the hub's memory only; a reconnect that reports the same running turn keeps it, as it keeps a dictated
turn's, and turning the switch off, disconnecting, or quitting drops it. A reconnect from a new connector instance
never carries a request over: turn ids are unique to the instance that reported them. While a request stands, and until
its reply is audible, the conversation's row in the session list shows "Reply will be read aloud." ("Next reply will
be read aloud." while it waits for the next turn) with a **Cancel** link; cancelling there or with the command drops any
summary being made, waiting, or handed to the voice but not yet audible, but not audio already playing. A requested
reply is superseded only by another requested reply from the same conversation, which also stops one handed to the
voice but not yet audible; a later automatic reply queues behind it. The command's answer is shown to the user, never added to what the model reads. Turning it off stops
playback, cancels any summary being made, and drops spoken replies still waiting, while the chosen service,
speaker and instruction are kept; turning it back on applies to the next reply and replays nothing.
The **Read Agent Replies Aloud** item in the menu bar menu (§6) is the same switch. The rest
of the section shows only while it is on.

A notice is a fixed sentence after the conversation's name, in the session list's own words: "Waiting for
approval." and "Waiting for an answer." when the agent's own state says so (`AgentLiveState`), and
"Disconnected before it finished." when the connector, or the conversation itself, stays gone for
`AgentHub.defaultDisconnectGrace`, so a reload does not announce itself; a conversation that vanished is still
named, and its earlier notice is withdrawn at once since nothing is left to answer it. A notice needs no AI
service and sends nothing anywhere, except a Pi prompt's: Pi says only that an extension prompt is open, not
whether it asks for approval or an answer, so the connector reports what it can see: the prompt's kind and title, the
most recently started tool call still running (its name and capped arguments), and a capped tail of the agent's
last words before it asked. Pi runs each tool's approval gate in start order before running any of them, so a
gate's prompt belongs to that latest tool; a question tool's own arguments are the only place its question and
options exist. Attribution is best effort: a dialog opened by a shortcut while a tool runs, or by a question tool
running beside another tool, can be reported with the wrong tool, and the instruction tells the model the tool
call may be unrelated and that the title wins. With a service chosen that context, redacted, becomes one spoken line saying what it asks
(`SpokenResult.waitingPrompt`), under a budget shorter than a summary's so a slow service does not hold the
notice; without a service, or when that fails or runs out of time, it is "Waiting for you." The hub forgets a
prompt's context once its session is no longer live. A Pi prompt shows in the session list as a dialog. Each is spoken once when the state begins; a notice whose state ends (the
approval was given, the connector or the conversation came back, the turn finished) before it is audible is withdrawn rather than
played late, even while the voice is still preparing it, and a finished turn's summary replaces it. A new
notice supersedes an earlier turn's summary still being made for that conversation. A
Claude Code user dialog, or a turn the user typed without asking for it to be read aloud, is never announced. Notices share the summaries'
queue, in-front skip and speaking panel, and "repeat that" replays them too; a replay the user asked for plays
even if its state has since ended.

**AI service** picks **None** or one of the saved AI services, used for summaries and for describing a Pi prompt. No
service is ever chosen for the user. With **None**, a short finished reply is still read as it is, a longer one is
announced as "Replied. Open the conversation for the result.", and a Pi prompt is "Waiting for you."; the row's caption
says so. A chosen service that no longer exists is an `IssueText`, and a longer reply
is then spoken as unavailable. With no saved services, an advisory saying summaries need one and what plays without it,
and **Open AI Services**, take its place. While a service is chosen, the row's caption
states the data boundary in one line, naming the service ("Long replies and waiting prompts go to {name}
after best-effort redaction."); its help adds that short replies are read without any service and that the app, named with
`Branding.appName`, does not save replies or summaries, with no claim about what the provider keeps.

**Voice** is one row, with **Preview Voice** beside its control, wrapping below it only when the pane is too
narrow. Preview speaks a sample in whichever voice would read a summary now, never while recording, and
interrupts a summary rather than overlapping one. Before the voice is installed, the row's caption reads
"Using the macOS voice. Download the natural voice for better speech." and its prominent button names the
language and download size; enabling the switch never downloads anything. While installing, the row's status
reads "Downloading N%" and then "Testing…" with the phase beside a spinner. Once installed, the row's control
is the speaker picker, listing `SpokenVoices.all` by name and accent with the recommended speaker first and
marked "(Recommended)"; only English speakers the voice's authors grade C+ or better are offered, every one
downloaded with the voice. A voice that makes no sound, whose files went missing (found at launch or when a
result fails to speak), or whose delete removed only some files reads "Needs attention" with an `IssueText`
and **Reinstall voice** in the row. When an installed voice fails to read a summary and the macOS voice reads
it instead, an advisory under the row says so, with the reason ("The macOS voice read the last spoken update because the
natural voice took too long."), until the natural voice plays again. It covers replies, notices and repeats; a
**Show in History** link appears only once History has saved the very reply it describes, and opens that entry. A
**Preview Voice** that falls back says so on its own line ("The preview used the macOS voice because …") and never
changes that advisory. That includes audio the voice made that is
unusable (invalid samples, none, or no audible level): it never plays, and the reason names what was wrong with it,
never that garbled speech was detected. A reply or a preview that arrives while
earlier audio is still being made, for example just after a stop, waits up to two seconds for it before the macOS
voice reads it instead. A macOS voice that is cancelled, or
never finishes, ends playback; one that never reports finishing is ended after `NaturalSpeech.fallbackLimit`,
which grows with the text, so the speaking panel and its Escape are never held. An installed voice still
preparing its audio after that same limit hands the text to the macOS voice, and new speech skips the natural voice
while stalled preparations are still running. Progress, failures and that
advisory always sit at the Voice row, never inside the disclosure.

**Advanced** is one collapsed `DisclosureSection`, with no disclosure nested inside it. It holds the **Summary
instruction** prompt editor, seeded with the default instruction, and **Reset to Default**, enabled only once
it was changed; then, once the voice has files to delete, its language and size on this Mac, a note that
deleting returns playback to the macOS voice until it is downloaded again and keeps the speaker and summary
settings, and the red trailing **Delete Voice**, which confirms first and stops anything the voice is speaking.
A missing voice file is never fetched in the background: only **Download** or **Reinstall voice** downloads.
Speech is made on this Mac; only summarizing may use the chosen service. The voice's speakers are English, so
a non-English summary is read by an English speaker or the macOS default voice.

Every summary starts with the exact name of the conversation that produced it, even with only one open, and
the default instruction asks for 15 to 25 words and never more than 40, leading with failures, open questions
and decisions and keeping uncertainty and skipped tests. A summary that cannot be made (the service fails,
times out or returns nothing) is spoken as "{name}: The spoken summary is unavailable.", never a guess.
Unavailable summaries waiting together are read as one notice naming each conversation ("{name} and {name}:
The spoken summaries are unavailable.") in the place of the first, ahead of summaries that finished between
them, so an outage does not repeat the same sentence once per result. A conversation named twice is named once,
and one whose name is gone is left out of the list. A reply the user asked to hear is never merged:
its notice is read on its own, so cancelling it stops only that conversation's notice. A
summary over `SpokenResult.summaryWordLimit` words is asked for once more, shorter, within the same deadline;
a second overlong one counts as unavailable rather than being cut off, since cutting could drop the failure or
decision it ends with. One
summary plays at a time and only the latest waiting one per conversation is kept. Nothing plays while a
recording is open or the dictation HUD shows: summaries wait and play once it has hidden, and starting a dictation stops playback and any audio
being prepared; the interrupted summary is not resumed. While a summary is audible, the speaking panel (§5)
shows it. Only turns the user's own dictation started, or that the user asked to hear, are spoken; another typed prompt's reply is
not. A conversation that is in front when its turn finishes is neither summarized nor read: the user is already looking
at the reply. Leaving it afterwards does not bring the reply back. When History keeps the dictation that started the
turn, its “What happened” steps say so (“Not read aloud: docs was in front when it finished”), so a reply the user
expected to hear can be explained. A turn the user asked to hear is the exception, with its notices: the user asked, and may have stepped
away with the terminal still in front. The check uses the same front reading as voice commands, but reads once: voice commands read twice
and act only on an unchanged view because they act on another app, while a wrong skip costs one summary, so the
second read and the window lookup it compares are left out. When what is in front cannot
be confirmed, the summary plays. This check never asks for Automation access: a terminal whose permission is undecided or
unknown counts as unconfirmed, and the scripted read sends its events without prompting for consent. Its reads
run on their own queue, so agents finishing never delay a voice command's terminal read. The row's help says the
summary plays when the front cannot be confirmed. A value
redaction hid from the service is spoken as "a hidden value", never read aloud.

Connector setup is one section per agent, each drawn from that agent's own adapter, holding one block per
setup: the folder an agent loads its configuration from (Pi's agent folder, Claude Code's config folder). The
setups shown are the default one, the ones a connector is installed in, and the ones open conversations were
found using, read from each conversation's own process, so a Finder launch and a terminal launch show the
same setups; finding a setup never installs into it. With one setup the section looks like a single
connector: a `SettingRow` with the status and one primary action, the folder as a `CopyableValue`, a line
naming the conversations that use it ("Used by Atlas and Build API." or "No open conversations use this
folder."), its issues, reload advice while a conversation using it is not connected or still runs the previous
connector, and **Uninstall Connector…** alone at the trailing edge. More setups
repeat the same block, each titled with its folder; there is no chooser or extra disclosure around them.
Installing, updating or uninstalling one setup's connector never disconnects another setup's or another
agent's conversations. When an agent's conversations cannot all be checked, its section says so as an
advisory and the conversations last seen stay listed rather than vanishing; only those are marked Last
seen. When `connectors.json` cannot be read, a **Connectors** section above the agents says no connector
can connect, shows why, explains that removing the file means installing every connector again, and offers
**Try Again**, which reads the file again, and **Show in Finder**.

**Install…** on a setup and **Connect…** on a conversation open the same consent sheet, presented like the
Rename sheet: the title "Connect conversations using this {agent} setup?", then the open conversations it
affects by name and that future conversations using the setup connect too ("Atlas, Build API, and future
conversations using this setup will connect to {app}. You can disconnect individual conversations later."),
a `DisclosureSection` for a longer list, the conversations that stay disconnected (one being reconnected is
listed with those that connect), that other setups are
unaffected, that the app keeps this connector up to date and open conversations keep the version they loaded
until they reload, the folder it installs in as a `CopyableValue`, and the reload advice when conversations
are already open. The details grow only to a bounded height and then scroll, while the title and
**Cancel** and **Install and Connect** remain visible. The buttons carry the standard cancel and default shortcuts.
Opening the sheet changes nothing, and Install and Connect is the consent: there is no second confirmation
and no result sheet. Progress and the outcome appear in the setup's block and the conversation rows.

A setup's status says what its files show: **Installed**, **Update available**, **Not installed**, the
agent's own turned-off wording when the agent's configuration turns the connector off, **Uninstall not
finished** with **Finish Uninstalling**, or a failure with what went wrong and **Try Again**, which repeats
the step that failed. A failed install is not Installed: its conversations still offer **Connect…**. Installed is
never Ready: a conversation is Ready only when its own connector has connected. When the app starts it
updates the connector in every setup it is installed in, never one it is not installed in or one the agent
has turned off; a conversation still running the previous connector says so under its row, and that
connector keeps working until the conversation reloads.

Failed connector operations and unreadable or unsaved conversation choices use the same error-marker
chain as other Settings failures: the connector label where applicable, Coding agent in the mode list,
Modes in the sidebar, and Settings in the menu. Not installed, Not connected and deliberate disconnections
do not create errors. Lifecycle and help buttons retain their own action names in accessibility.

**Uninstall Connector…** asks for confirmation first, which says that conversations using this setup
disconnect at once, new ones will not connect, work already sent may still finish, each open conversation
unloads the connector with its agent's reload command (`/reload-plugins` in Claude Code, `/reload` in Pi) or
a restart, and the app's names and disconnected conversations are kept. The setup stops admitting its
connectors before anything is removed. For Claude Code, the uninstall is done only once Claude Code no longer
lists the plugin or its marketplace in that setup; a step that reports something already gone is not a
failure. A setup that is not installed but still has a connected conversation warns that the conversation
keeps receiving instructions until it reloads, which happens when the connector was removed outside the app.
An uninstall that did not finish shows **Uninstall not finished** as soon as it fails, with what the agent
said, explains that its conversations no longer connect, and offers **Finish Uninstalling**; finishing never
lets them connect again. When the agent's command cannot be found but the connector's files are still in
place, the block keeps **Uninstall Connector…** and lists the terminal commands that finish the job, each
copyable, named for this copy of the app and its setup. A copy of the app that is missing its connector shows
the connector as Unavailable, with guidance to reinstall the app; nothing else in the app is affected.

The Pi connector is files only: Install writes an extension folder into the setup's `extensions/` folder,
which every Pi using that setup loads on its own, and Uninstall deletes that folder; Pi is never asked to run
a command. Because Pi is only consulted for its version, a Pi older than the first version the connector
works with (`PiCLI.minimumVersion`) shows **Pi too old** with that version and advice to update, and offers
no Install; when the folder is in place it still offers Uninstall Connector…, since removal needs nothing
from Pi.

**Conversation rows and their connection.** Besides the conversations whose connectors connected, the list
shows agent processes found without one, described honestly ("Pi in atlas", Not connected) with no Rename
until the agent identifies the conversation; when it does, the same row is updated in place, matched by
process and start time, and focus and position stay put. Otherwise identical process-only rows add their
start date and time for recognition, including in the consent list; this context never becomes a spoken
name. A row whose setup has no connector offers
**Connect…**. A row whose setup has a connector but which has not connected says "Connector installed. Run
/reload in this conversation." with the command as a `CopyableValue`, **Show Conversation** (which only brings
it forward and never types) when it can be located, and **Try Again**; the app never infers a reload is needed
from process age or a missing hello. A row's terminal line names the place its conversation runs in
when it has a label ("Ghostty · herdr workspace cos", naming the multiplexer once), so a name that came from the place matches
it, and a name that won over the place still shows where it runs. A connected row offers **Rename…** and **Disconnect**. Connecting never
changes the current recipient or sends anything.

**Disconnect** takes effect at once without confirmation: the conversation leaves the recipients and the
recording HUD's numbered list, stops being the current recipient, and its held hand-offs and waiting spoken
replies are dropped; work the agent already accepted may finish. It then appears under a **Disconnected
conversations** `DisclosureSection`, shown only when needed, which says once "These conversations stay
disconnected when reopened. New conversations connect normally." Each row has its name, folder and
**Reconnect**, which takes effect at once without a reload, or opens the consent sheet when the setup was
uninstalled and reconnects the conversation once the install succeeds. A disconnected conversation keeps
its name, and no other conversation takes it. A disconnection that could not be saved stays in effect for this session, with "Disconnected for
now. Couldn't save this choice for the next launch." and **Try Again**. While the saved choices cannot be
read, no conversation connects, the names problem says so, the list says "Conversations stay disconnected
until names.json can be read.", and nothing is offered for Reconnect.

**Conversation missing?** is a `DisclosureSection` under the list with **Try Again**, a plain account of what
discovery can miss (agents started through unusual wrappers or hosted inside other programs), and a
**Choose {agent} Setup Folder…** button per agent. A chosen folder that does not look like that agent's setup
is explained beside the buttons; one that does opens the consent sheet. These actions stack vertically
when they do not fit across the pane, keeping their labels whole. Choosing a folder says where to
install, not which conversations use it. With nothing found the list says "No open conversations found.", and
when some conversations could not be checked it says so instead; neither claims no agent is running.

**Rename…** opens a compact sheet, focused on the existing name, with a live spoken example. When fewer of
the name's leading words already reach only this conversation, the example offers them as well (“Say “fix
authentication retries, run the unit tests.” “fix authentication, …” also works.”): the shorter form is
checked against the same matcher a take uses, is never offered when another conversation shares it, and never
ends on a connecting word such as “the”. The available
conversation title and abbreviated directory provide recognition context above the field, with their full
text available on hover and selectable for copying. Empty,
reserved and already-used names are explained beside the field before submission. A save failure
keeps the sheet and draft open for correction or retry, with the diagnostic reason under Technical
details; Cancel makes no change. Under the field a quiet line says where the name comes from (“This name
comes from its herdr workspace.”, or “from its herdr pane title.”); when the conversation has a KeyScribe name, it names the name it would
have without one, with any distinguishing word it would need (“Default name: cos claude, from its herdr
workspace.”). When the conversation has a KeyScribe name, **Use Default
Name** leads the action row: it drops that name, saved first, and closes the sheet; a save failure keeps
the name and the sheet open with the same explanation as a failed rename. When the conversation runs in a
herdr pane, labelled or not, the sheet adds “This name follows this conversation, including when you resume it. To name
future conversations in this pane, rename the pane in herdr.” Renaming changes the
name used in KeyScribe and leaves Claude Code's own title alone. A chosen name stays with its session
across restarts of either app and is held for it while it is closed. A name KeyScribe gave a session
stays with it across KeyScribe restarts while that session keeps running, and is free once it closes. If those names
cannot be saved, Conversations shows an orange advisory that they may change when the app restarts, with
the reason beneath it; saving is retried and the advisory clears once it succeeds. The name is saved before it takes
effect. It overrides subsequent native renames; without a KeyScribe override the native conversation
name is used automatically.

If saved names cannot be loaded, Conversations explains what still works and offers **Try Again**.
The diagnostic reason and **Show in Finder** live under **Details**; removing the file is explicitly
described as forgetting the chosen names. Rename is unavailable, and a take starting with “tell” that
is not a row number (“tell session 2 …”) is held instead of sent, including prose such as “tell me …”.
A take starting with a name but no “tell” cannot be recognized and goes to the current conversation.
The HUD offers row numbers while names are unavailable, and the Settings example points to the number
shown while recording without naming one, since the Settings list and the recording list are ordered differently. Choosing or renaming a
conversation never retargets a take already recording: its list and recipient stay frozen.

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
- outcome (`Inserted`, `Copied`, `Local fallback`, `Rewrite skipped`, `Rewritten later, not inserted`, or `Failed`; a voice command reads `Command`,
  `Command failed`, `Command started`, `Needs a choice`, or `Choice cancelled`);
  an entry that recorded its own summary shows that instead, so a Coding agent take reads `Sent to backend`,
  `Queued for backend`, `Opened backend`, or why nothing was sent, never a generic `Inserted`;
- data-boundary badges relevant to that dictation;
- no audio indicator because audio is never stored.

### Detail view

The detail follows the user’s mental model:

```
Heard → Transformed → Result
```

It shows the mode, insertion outcome, correction actions, and a `Result` view with a separate
`Details` view for processing details.
section. Details reveal the exact connection/model when used, where its reasoning setting landed
(**Reasoning**, the same words as the connection test), whether best-effort redaction was
enabled, which context categories were sent, and the raw cloud exchange as sibling disclosures:
**Show exactly what was sent** (the stored prompt) and **Show exactly what was received** (the
provider's reply, verbatim — before any output enforcement, so model misbehavior stays visible
rather than silently corrected). Whenever local text was kept, even if delivery later failed, the received view notes the reply was
not used. Redaction maps are never shown or persisted.

A **voice command** entry reuses the same detail: the comparison reads **Heard → Command**, where
Command is what ran — a script's exact command line, quoted the way a shell would so it can be copied
into a terminal, the shortcut and its input, or what a switch did. An action still running when it was
recorded reads **Command started** until it finishes, when the entry is updated to **Command** or
**Command failed**. An open History pane refreshes when that happens and keeps the entry selected, and
the entry can be deleted whether or not the pane saw the update. A command that asked which one is
recorded as **Needs a choice**, its result listing the numbered rows. A spoken answer is its own entry —
heard “two”, its result beginning “Selected Work Mail for “open mail”:” followed by what ran — so
the pair reads correctly even when other entries fall between them or a filter hides one. A spoken
cancel reads **Choice cancelled**, and a reply that was not an answer reads **Needs a choice** with the
standard instruction for answering (“Choose 1–2, say “cancel”, or give a new command.”), even when the
HUD showed what was heard instead. Clicking a row completes the question's own entry instead, since nothing was spoken; the
Cancel button marks it **Choice cancelled**. A take that is only “cancel” or “never mind”, with no question
waiting, records nothing, in either action mode, like a dictation discarded with “never mind”. An idle timeout records nothing. A failed command adds a **Why it failed** row in Details explaining the
failure, and a script that reported a result adds a **Reported** row with the message the HUD showed. That row can say more than the compact HUD: an unrecognized command keeps the full “Not a
command. Say …” guidance there while the HUD shows only “Command not recognized” and what was heard. **Paste Result** is hidden for commands, since there is nothing to insert;
**Copy Result** stays. **Add to Dictionary** and **Create Replacement** on a command entry write to the
Voice Commands vocabulary, not the global one, since that is what reads commands. While voice commands
are turned off, a command entry shows no corrections, since that vocabulary cannot be seen or edited. The Voice Commands
editor carries its own **Do not save this mode in history** toggle.

A **Coding agent** entry is an attempted action, not a text transformation, so every one of them (Open,
choosing a recipient, a sent, queued, kept or refused message) uses one presentation instead of the
comparison. Its Result view leads with the outcome in large type, red when it failed (*Sent to backend*,
*Opened backend*, *Not sent: start with a conversation’s name*). The header carries no outcome badge or
second copy of it. Below it come what was heard, on its own and selectable for corrections, then the
**Message** that was sent or kept when it differs from what was heard. **What happened** follows:
labelled lines recorded when the take happened (the command, the spoken address, the conversation, or
*None resolved*, and how it was chosen, and the default recipient), then, once a queued
or uncertain message settles, a timed line for each result in order. Those lines are as they were at the
time, so a later rename or reorder does not change them. When an AI rewrite ran, **Compare with the AI
rewrite** offers the usual comparison, collapsed, with the final text called **Result**. A message whose
rewrite fell back or was skipped stays **Local fallback** or **Rewrite skipped** after it is sent. The
text and Markdown exports carry the same summary and lines, and say why local text was kept.

What a spoken reply (§7 Coding agent) read aloud is kept as it was heard, once it was audible: never a reply
withdrawn or skipped before it played, and never a second copy for “repeat that”. A reply to a message the user
dictated joins that message's entry, and only when that entry was kept; a reply the user asked for from inside
the agent is an entry of its own under the Coding agent mode, reading *Reply from backend*, kept only while
History is on and the mode is not left out of History. A notice (an approval or a wait) is not kept: a long
session would fill History with them, and the agent's own screen already shows them. Either way a
**Read aloud** section shows the line, selectable, with the conversation it came from (**From**), when it was
read and, for a summary, **Summarized by**
and the service; the entry's badges add **Spoken summary** and **Best-effort redaction**. The line is never
offered for corrections, since it is the agent's words, not the user's. Search finds it, and the exports carry it. An entry that is only a reply is not a dictation: the History stats, the mishearing search and its count, and
the diagnostics report leave it out, and its export has no Result line. Its action bar offers **Copy Reply** in
place of Copy Result and has no Copy Report. A dictation with a reply joined to it offers **Copy Reply** beside
Copy Result, and its **Copy Report** says it includes what was read aloud.

The **Read aloud** section also says which voice read the line (**Read by**: Natural voice or macOS voice) and
why the macOS voice read it (**Why**), both kept with the entry, and, while its spoken audio is held, its playback (**Playback**: Not started,
Playing, Played to the end, Stopped before the end, or Failed). **Read with macOS Voice** reads the line again with the macOS voice
for as long as the entry exists; while the user is dictating it reads nothing and the status line says why. Whichever
of Read and Play is speaking turns into **Stop**; choosing another entry or closing History stops it. **Play Generated Audio** and **Save Generated Audio…** appear only while the audio is held. Play plays the exact
audio the app generated for that reply, which for a reply the macOS voice read is the natural voice's rejected take
(the caption says so), through the same rules as any speech (dictation stops it; while dictating it plays nothing and the
status line says why), and records nothing. It is disabled while that reply is still being read aloud, and a player
that refuses the audio says "Couldn't play the generated audio." rather than showing Stop.
Save asks for a folder, then writes the audio and a report (the text read, the voice and its details, how playback
ended) there as two files named for when the reply was read, in local time, numbering the name ("… 2") rather than
replacing a file already there; if either write fails it removes what it wrote, so a retry starts clean. It then
selects the audio in Finder, says so in the status line, and sends nothing anywhere. A caption under the
buttons says the audio is kept for an hour while the app is running; once it is gone, a reply the natural voice
read says "The original audio is no longer available." and the save action is not offered, since making the
audio again would not be the audio that played.

A dictation in which live edits ran, including a Coding agent message (beside its recipient lines), adds a
**What happened** row, **Spoken edits**, with the same words as the completion HUD (“new line ×2, scratch that”), so the user can tell afterwards whether a spoken edit fired.

Under the comparison of a dictation (not a command or a Coding agent message), a line names each likely
mishearing of a dictionary word that applied to it and that no rule or near match already fixes:
**“Cryden” may be “Kryten”**, with **Review Mishearings…**, which opens the **Mishearings of “Kryten”**
sheet in the scope the word lives in (Global, or the mode whose own dictionary holds it). One line per
word, its likeliest spelling. It uses the History finder's scoring on that one dictation, so a common
word that sounds like a name can be named too; the user judges it, and nothing is changed or sent anywhere.
The line goes away once a rule fixes the phrase.

Correction actions are directly beside the relevant text:

- **Add to Dictionary** for a term that should be recognized as written.
- **Create Replacement** for a repeated heard-to-intended correction.

Reuse actions (**Copy Result**, **Paste Result**, **Copy Heard**) lead an action row at the top of the
detail. On a dictation whose rewrite fell back or was skipped (not a Coding agent message, which was
already sent), **Rewrite Again** follows them. It runs the AI rewrite again, with the
mode as it is now, on what was heard (less the spoken phrase that chose the mode), without context: the
original take's context was never stored, and the screen now is not what was dictated into. Redaction
stays on when the original take had it, even if the mode has turned it off since. It shows a small
spinner while it runs, Delete Dictation is unavailable until it finishes, and it inserts nothing. On success the entry is updated in place to **Rewritten later, not inserted**, its Result is the
new text, and the status line says which service rewrote it and to copy or paste the result. When it
cannot run (the mode is gone or has no AI service, the dictation inserted the clipboard, a rule took the
whole dictation) or the service fails again, the entry is unchanged and the status line says why. If the
dictation was deleted meanwhile, the rewrite is dropped and the status line says so; if History could not
save it, **Copy Rewrite** appears beside the other actions so the text is never lost and the clipboard is
changed only when the user asks.
**Copy Report** follows, which copies that one dictation for a bug report: every field the
entry recorded, including what was said, the request sent to an AI service and its reply, plus the install
summary Copy Diagnostics produces. Nothing is redacted. The report's first lines, the button's help, and
the confirmation after copying all say it includes what was said and any AI request and reply (which can
hold selected text or text from the app), so the user can remove anything private before sending. The destructive **Delete Dictation** follows the shared delete convention: it sits alone at the
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
  semantics. The Voice Commands choice (§5) is answered by voice or a click; it has no keyboard selection,
  so it never takes typing away from the app the user was in.
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
