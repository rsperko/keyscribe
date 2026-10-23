# KeyScribe — Mode & Config TOML Schema

> Companion to `../development/design.md` (§4.3 modes, §4.6 settings, §5 storage, §5.1 versioning).
> Defines the on-disk config: one TOML file per mode plus the shared config files modes
> reference. Every config file carries `schema_version`; older versions are normalized on read
> (`../development/design.md` §5.1).

---

## Directory layout

```
~/Library/Application Support/KeyScribe/
  settings.toml            # general settings + active STT engine
  connections.toml         # named LLM connections (BYOK)
  dictionary.toml          # global dictionary
  replacements.toml        # global replacements
  voice_commands.toml      # places and actions for the Voice Commands mode (experimental)
  fragments/               # shared prompt fragments (one file per fragment)
    my-voice.md            #   markdown body + YAML frontmatter
  modes/                   # one file per mode; filename stem = mode id
    _direct.toml             # the Direct system floor (reserved `_` id)
    _voice_commands.toml     # the Voice Commands system mode (experimental; seeded only while its flag is on)
    email.toml
    pig-latin.toml
  history/                 # append-only local history, one JSONL file per day
    2026-06-20.jsonl
  usage/                   # replacement use counts (see "Replacement usage")
    replacements.json
  lkg/                     # last-known-good mode copies + seed-ledger.toml (design.md §5.1)
  models/                  # downloaded STT weights, one dir per model (design.md §4.1)
    parakeet-tdt-0.6b-v3/
```

- **Mode id = filename stem** (kebab-case). The id is stable; `name` is the display label and
  can change freely.
- **System modes use a reserved `_`-prefixed id** (`_direct.toml` = the Direct floor, shown to users
  as "Plain Dictation", `design.md` §4.3). The kebab-case slugger never emits a leading underscore, so user modes can't collide. Only the built-in ids are treated as system modes; any other `_`-prefixed file is an ordinary mode. The
  file is auto-seeded and re-normalized on load: only its editable fields (trigger keys, insertion,
  trailing, submit, clipboard modifier, live-edits, **and exclude-from-history**) are honored; the
  locked guarantees (no AI rewrite, dictation/cursor only, global vocabulary) are enforced regardless
  of edits. Direct owns Fn by default and records to history per the global setting unless turned off.
- **`_voice_commands.toml`** is a built-in system mode, behind the `voice_commands` experimental flag.
  It is seeded (with no shortcut) only while the flag is on; turning the flag off hides it but leaves the
  file, so a later opt-in keeps the shortcut. Only `trigger_keys[]`, `enabled`, and its own vocabulary
  (`[dictionary]` and `[replacements]`, which leave out global vocabulary unless `include_global` says
  otherwise) are honored; everything else is forced (`output = "voice_command"`, no rewrite, no spoken
  editing commands, no phrases or constraints). `exclude_from_history` is honored too and defaults to
  `false`, so a voice command is recorded like a dictation: Heard is the transcript and Result is the
  command it ran (a script's program and arguments, quoted the way a shell would), with the reason
  when it failed. It is never the fallback: only its own shortcut starts it. **Its shortcut may not
  be shared with any other enabled mode**, whatever that mode's context: Settings offers to move it, and a
  shared press written by hand stays with the other mode — the Voice Commands binding is dropped, and the
  Modes list and the menu-bar badge mark the mode's shortcut as never firing.
- Config files are human-editable text. **Model weights** are downloaded at runtime (never
  committed) into `models/`, consolidated under the KeyScribe support dir.
- **History records** (`history/<day>.jsonl`, one JSON object per line) are additive: each dictation
  writes `mode`, `heard`, `result`, `outcome`, boundary metadata, and two **optional**
  fields, `mode_choice` (`one_shot` / `trigger_key` / `context_rule` / `spoken_phrase` / `fallback`)
  and `routed_phrase` (present only for `spoken_phrase`). A cloud rewrite also stores the optional
  `received` — the provider's raw reply, verbatim (pre-enforcement, carrying `⟦SN:…⟧` tokens like
  `prompt`, never their originals) — behind History's "Show exactly what was received". Old rows
  lacking optional fields decode as absent — History renders without the corresponding line. Audio
  and the redaction map are never stored.
  Each record also carries an optional `id`, fixed when it is written, which an in-place update (a late
  command result, a clicked choice) keeps; History matches rows and deletes by it. Older rows without one
  are matched by their content.
  A **voice command** writes `outcome = "command"`, `"command_failed"`, or `"command_started"` (an
  action still running, later rewritten to one of the first two). A command that matched more than one
  destination writes `"command_needs_choice"`, its `result` listing the numbered choices; a spoken answer
  is a separate entry whose `result` starts `Selected <name> for “<command>”:`, and a cancelled choice
  writes `"command_cancelled"`. A choice answered by clicking rewrites the question's own entry. Its `heard` is the
  transcript, `transformed` the text after the Voice Commands vocabulary, and `result` what ran: a
  script's command line, quoted the way a shell would, or the description of a switch. A command that
  matched nothing has an empty `result`. A failed command adds the optional `failure_reason` — the
  message the HUD showed, which for a script can include the last line it wrote to standard error.
  An app older than this change skips these rows rather than failing to load history.

### Model storage

All KeyScribe data — including STT weights — lives under the one support dir. KeyScribe **points each
engine SDK at `models/<model-id>/`** where the SDK exposes a configurable download directory; where
it does not, KeyScribe manages the SDK's own location through that SDK's API and the result is the
same single disk-usage / delete story for Speech Models settings. **Apple's speech
models are system-managed** when available and have no entry here.

- **Application Support, not Caches** — weights must not be purged mid-session; they are
  re-downloadable, so deletion is always safe and the dir is marked excluded-from-backup so
  Time Machine does not store re-downloadable data.
- The `models/` dir is **not** versioned config and carries no `schema_version`.

---


## Replacement usage

`usage/replacements.json` records how often each configured replacement changed a dictation that
reached its destination. It is app-written state, not config: it carries a JSON `schemaVersion`, it is
never hand-edited, and a write to it does not reload configuration.

- One entry per rule, keyed by scope (`global` or `mode:<id>`), kind (`l` literal, `r` regex), and the
  heard text — lowercased for a literal, verbatim for a regex. The replacement output is not part of
  the key, so rewording **Use instead** keeps a rule's count; changing the heard text or the regex flag
  starts a new one. Renaming a mode carries its rules' entries to the new id.
- The file stores `trackingSince`, the day counting began. Each entry stores `count` (dictations, not
  matches — a rule matching twice in one dictation counts once), `lastUsed`, and `since`: the day the
  rule first appeared, or absent for a rule that already existed when counting began, whose real add
  date is unknown. Dates are local days (`yyyy-MM-dd`), never timestamps, and no dictation text is
  stored.
- A rule counts only when the dictation was inserted or copied; a cancelled, empty, or failed one
  never counts. For a voice command, a rule counts only when the command ran (it finished or started);
  an unrecognized, refused, or failed command never counts, and neither does one that asks which
  destination to use. The spoken answer to that question counts its own rules when the chosen command runs. A whole-utterance replacement counts only the rule that owns the utterance. A count
  lands only on a rule that is still configured when the dictation finishes: one removed mid-dictation
  is not brought back, and one whose mode was renamed mid-dictation counts under the new id.
- A failed write is logged and retried on the next change; the in-memory counts are never discarded.
- Counting is independent of the History setting. Entries for rules that are no longer configured are
  dropped whenever configuration loads cleanly; a config file that fails to load leaves the counts
  untouched. A usage file that cannot be read (corrupt, or written by a newer version) is moved aside
  to `replacements.json.unreadable`, logged, and counting starts fresh — it is never silently
  overwritten. Only the most recent unreadable copy is kept; if it cannot be moved, counts are kept in
  memory only until the next launch rather than written over it.

## Mode file — annotated example

`modes/email.toml`

> **TOML ordering (load-bearing).** Every root-level scalar key (`name`, `enabled`,
> `trigger_phrases`, `source`, `output`, `insertion`, `exclude_from_history`) must appear
> **before** the first table or array-of-tables header (`[[trigger_keys]]`, `[constraints]`,
> `[commands]`, …). A root key written after a `[[table]]` header silently parses as a member of
> that table, not the mode. So: all the mode's scalars first, then the table sections.

```toml
schema_version = 2
name = "Email"
enabled = true

# source: "dictation" (default) or "selection" (edit-in-place: capture the current selection as
# content, dictation becomes the instruction). output: "cursor" | "replace_selection".
source = "dictation"
output = "cursor"

# Trigger phrases. One or more spoken phrases matched at the END of the transcript
# (raw-suffix routing). Matching is case-insensitive, tolerates trailing punctuation/whitespace
# that STT appends, and honors word boundaries — so a bare phrase just works:
trigger_phrases = ['as an email']
# A phrase is itself a regex, so power users can write one for alternation/optional words:
trigger_phrases = ['as (a |an )?(draft|note)']
# Do NOT add (?i), \b, or a trailing $ — the matcher already supplies case-insensitivity, word
# boundaries, and end-anchoring AFTER trimming the punctuation/spaces STT appends (so a literal $
# would match anyway, but it is redundant). Use (?-i) only to force case-sensitivity. Optional.

insertion = "paste"          # "paste" (default) | "insert" | "type"
trailing = "space"           # "none" | "space" (new-mode default) | "newline" — appended INSIDE the atomic insert
submit = "none"              # "none" (default) | "return" | "shift_return" | "cmd_return" — keystroke AFTER a verified insert
paste_key = "command+v"      # chord posted to paste an insert (same grammar as trigger_keys[].key); e.g. "control+shift+v" for a Linux guest terminal
copy_key = "command+c"       # chord posted to capture a selection (source = "selection" modes)
# clipboard_sync = true      # leave the scratch clipboard readable + unrestored for a guest/remote clipboard agent.
                             # Defaults to true when paste_key has no ⌘; set it explicitly for a target that
                             # translates ⌘V remotely (RDP) but still syncs the clipboard across the wire.
paste_settle_ms = 0             # 0 (default) | ms to wait after writing the clipboard, before the paste keystroke; for a synced guest/remote clipboard whose host→guest propagation lags
trim_trailing_punctuation = false  # strip a final . ! ? (and trailing whitespace) from the result, BEFORE `trailing` is appended
exclude_from_history = false

# ── When it runs ─────────────────────────────────────────────────────────────
# Trigger keys. Each has a press style: "hold-or-tap" | "hold-only" | "tap-to-toggle".
# "hold-or-tap" = push-to-talk while held, OR fires on a quick tap.
[[trigger_keys]]
key = "right_option"        # canonical key descriptor; also e.g. "fn", "left_command+left_control",
                            # "control+`" (see "Key descriptor format" below)
press_style = "hold-or-tap"
tap_threshold_ms = 250      # release under this = a tap (latches on); over = push-to-talk hold

# A further entry starts the same mode, each with its own press style. Settings edits only the first.
# [[trigger_keys]]
# key = "mouse4"
# press_style = "hold-only"

# Context eligibility. Empty = eligible everywhere. A constraint ANDs its fields; any of
# bundle_id (exact), bundle_prefix (case-insensitive bundle-id prefix), url_pattern (regex, when
# detectable), window_title (regex). Also constrains which phrases can route here. Specificity ranks
# url_pattern > window_title > bundle_id > bundle_prefix (design.md §4.3).
[[constraints]]
bundle_id = "com.apple.mail"
# bundle_prefix = "com.jetbrains."        # optional; matches all bundle ids under the prefix
# url_pattern = 'mail\.google\.com/.*'    # optional; best-effort
# Pair url_pattern with bundle_id in the SAME block to also release the trigger key outside that
# browser: a url-only rule cannot be disproved without probing, so its key stays claimed everywhere
# and an out-of-scope press starts and cancels. With the bundle present the press resolves before the
# mic opens and is a silent no-op (design.md §4.3).
# window_title = '(?i)pull request'       # optional; regex against the focused window title
# The editor's friendly "Website…" field stores a generated host-anchored url_pattern
# (host = the entered domain OR a subdomain of it), e.g. github.com →
# (?i)^[a-z][a-z0-9+.-]*://([^/?#]*\.)?github\.com([/:?#]|$). The on-disk shape is unchanged (still a
# url_pattern regex); a hand-written pattern keeps today's unanchored substring semantics.

# ── Pipeline commands (spoken-command / pipeline features, opt-in per mode) ──
[commands]
live_edits = true           # spoken commands: "insert new line" / "insert new paragraph" /
                            #   "insert tab character" / "scratch that" / "insert clipboard contents"
                            #   (pastes the clipboard, protected like verbatim) /
                            #   "begin verbatim".."end verbatim" (verbatim is a live edit)
privacy    = false          # best-effort redaction (the mode's privacy toggle).
                            #   When true, context is forced off (see [ai_rewrite].context).
numbers    = false          # inverse text normalization: "twenty five" -> "25"
                            #   (leaves year idioms like "twenty twenty six" as words)
# (Dictionary recovery is not a mode command and has no toggle: it runs automatically whenever the
#  mode's merged dictionary is non-empty. The one mechanism control is the per-engine recognition-bias
#  disable under settings.toml [stt]; see recognition_bias_disabled_engines.)

# ── Vocabulary (mode-local; may exclude the global sets) ─────────────────────
[dictionary]
include_global = true
words = ["KeyScribe", "Parakeet"]

[replacements]
include_global = true
[[replacements.rules]]
heard = "at gmail dot com"
replace = "@gmail.com"
regex = false
[[replacements.rules]]
heard = '(\d+) dollars'
replace = '$$$1'
regex = true                # regex allows capture-group substitutions

# ── AI rewrite (optional; omit the whole [ai_rewrite] table to disable) ──────
[ai_rewrite]
connection = "gemini-flash"     # references a [[connection]] in connections.toml by id
prompt = "Rewrite the dictation as a clear, professional email. Keep my meaning."
fragments = ["my-voice"]        # shared prompt fragments, appended in order
# Context opt-in (what gets sent to the LLM):
context = { app = true, preceding_text = false }
                                                     # selection is sent when source = "selection".
                                                     #   preceding_text = bounded text before the caret
                                                     #   (native-only, best-effort via AX).
                                                     #   Forced to all-false when commands.privacy = true.
```

### Mode field reference

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | Required. Current: `2`. Older versions are normalized on read; v1→v2 migrates the retired `clipboard_modifier` key (`"control"` → `paste_key = "control+v"` + `copy_key = "control+c"`; `"command"` was the default and just drops). |
| `name` | string | Display label. |
| `enabled` | bool | Disabled modes are ignored by the resolver. |
| `trigger_keys[]` | table[] | `key` (canonical descriptor) + `press_style` + `tap_threshold_ms` (default 250). Zero or more; every entry starts the mode. Settings edits the **first** entry and preserves the rest. Further entries are TOML-only and appear in the mode editor as a read-only "Also starts with" note; a later entry that is the same press as an earlier one (`command` after `right_command`, or the same key twice) is ignored at runtime, the note says so, and it is left out wherever the mode's shortcuts are listed. There is no separate global hotkey — whichever mode owns Fn (the Direct floor by default) is "the global hotkey". |
| `trigger_phrases` | string[] | Spoken phrases matched at the transcript end post-STT — case-insensitive, word-boundary-honored, trailing punctuation/space tolerated. Each is a regex, so power users can write one (`(?-i)` opts back into case-sensitivity). Zero or more. |
| `constraints[]` | table[] | Any of `bundle_id`, `bundle_prefix`, `url_pattern`, `window_title` (ANDed). Empty ⇒ eligible everywhere. |
| `source` | enum | `dictation` \| `selection`. |
| `output` | enum | `cursor` \| `replace_selection` \| `voice_command`. `voice_command` is the Voice Commands system mode's output: the take is run as a command (`voice_commands.toml`) and nothing is inserted. Any other mode file that sets it fails to load. |
| `commands.live_edits` | bool | Opt-in to the spoken-command list (insert new line, insert new paragraph, insert tab character, scratch that, **insert clipboard contents**, **begin/end verbatim**). |
| `commands.privacy` | bool | Opt-in to best-effort redaction. When true, **context is forced off** — `ai_rewrite.context` is locked to all-false so only the redacted transcript leaves. |
| `commands.numbers` | bool | Opt-in to inverse text normalization ("twenty five" → "25"); bails on ambiguous/year-like runs. |
| `dictionary` | table | `include_global` + `words[]`. |
| `replacements` | table | `include_global` + `rules[]` of `{heard, replace, regex}`. |
| `[ai_rewrite]` | table | Absent ⇒ no rewrite. `connection`, `prompt`, `fragments[]`, `context`. |
| `ai_rewrite.context` | inline table | `{ app, preceding_text }` booleans. `preceding_text` sends bounded text before the caret (native-only, best-effort via AX). (URL is a routing key only — `constraints[].url_pattern` — never sent to the LLM.) |
| `insertion` | enum | `paste` (default) \| `insert` \| `type`. `type` synthesizes real keystrokes for a target that ignores a synthesized paste (a VM guest): each character is mapped to a virtual key through the active keyboard layout, with shift/option posted as physical key events — the only form a hypervisor can deliver, since it translates the event's key code and drops its Unicode payload entirely (verified in VMware Fusion: payload events arrive as keycode 0, a literal `a`, even one character per event). Characters the layout cannot produce (emoji, composed accents) fall back to Unicode-payload events, which land in native apps but never in a guest. `type` touches the clipboard not at all — so `paste_key`, `copy_key`, `clipboard_sync`, and `paste_settle_ms` are **all ignored** under it; setting them alongside it does nothing. The insert holds the dictation in its inserting state for the whole run; a trigger pressed during that window is refused with the error sound. |
| `trailing` | enum | `none` \| `space` \| `newline`. Literal text appended to the transcript, inside the atomic insert (one ⌘Z still undoes it all). New modes created in Settings default to `space`; omitted TOML decodes as `none` for compatibility with existing config files. |
| `submit` | enum | `none` (default) \| `return` \| `shift_return` \| `cmd_return`. A keystroke synthesized after a **verified** insert (outside the undo atom). Never fires on a clipboard fallback — the text never reached the target. |
| `trim_trailing_punctuation` | bool | `false` (default). Strip a final `.` `!` `?` (and trailing whitespace) from the result, applied to the restored final string **before** `trailing` appends its suffix. Deterministic enforcement for command/identifier/subject-line modes (e.g. seeded **Shell** ships `true`) that should not end in sentence punctuation — the rewrite prompt can request this but cannot guarantee it. Closing quotes/parens/backticks/fences are left untouched. |
| `paste_key` | string | `command+v` (default). The chord posted to paste an insert, in the **same grammar as `trigger_keys[].key`** (`control+shift+v`, `ctrl+y`, aliases `cmd`/`ctrl`/`alt` accepted) — including its layout resolution, so a printing key is posted at whatever position types that character on the **host's** active layout; a chord the active layout cannot produce is logged and not posted, so the insert fails visibly rather than landing on the wrong key. A guest or remote session reads that position with its own layout, so it must match the host's (a Dvorak host driving a QWERTY guest posts the Dvorak position). Must be a chord — the trigger-only descriptors (`fn`, `left_command`, `mouse3`) are rejected. An unparsable value falls back to `command+v` at runtime but is **kept verbatim in the file** so a typo stays visible instead of being erased on the next save. Governs the paste keystroke only, never `submit`; ignored under `insertion = "type"`, which never touches the clipboard. TOML-only; no Settings UI. |
| `copy_key` | string | `command+c` (default). Same grammar and rules as `paste_key`, for the synthesized copy that captures a selection (`source = "selection"` modes). Selection capture in a guest or remote session is **best-effort** — the host-pasteboard bump it waits on is driven by that session's clipboard-sync, not the OS, so its timing is not guaranteed. |
| `clipboard_sync` | bool | Defaults to **on when `paste_key` has no ⌘**, off otherwise. When on, the scratch clipboard is written **un-concealed** (so a guest's or remote session's clipboard agent will pick it up) and is **never restored** — the dictated text stays on the clipboard, like a manual copy. Set it explicitly for a target whose client translates ⌘V for the remote side but still syncs the clipboard across the wire (RDP/Citrix/VNC): those clients fetch the clipboard back **at paste time**, so a restore racing that fetch would hand the remote app your previous clipboard. Setting it `false` alongside a non-⌘ chord restores the native behavior. Independent of the chord in both directions. |
| `paste_settle_ms` | int | `0` (default). Milliseconds to pause after writing the clipboard and before the paste keystroke. `0` = paste immediately (native apps — no delay). A positive value covers a **remote-session clipboard** (RDP/Citrix/VNC) whose eager cross-wire sync merely lags the paste, which otherwise pastes stale content; tune it up until paste is reliable. It cannot cover a target whose sync is **event-driven rather than lagging** — a local hypervisor (verified in VMware Fusion) syncs host→guest on window-focus changes, which never happen mid-dictation, so every settle value still pastes empty or one dictation behind; those targets need `insertion = "type"`. Independent of `paste_key` and `clipboard_sync` — a pure timing knob, applied to any paste, and ignored under `insertion = "type"`, which never touches the clipboard. TOML-only; no Settings UI. |
| `exclude_from_history` | bool | Skip writing this mode's dictations to history. |

There is **no "default mode"** setting. The **Direct** system mode (`_direct`, §"System modes" above)
is the single floor and owns Fn by default; the everyday mode is simply whichever mode is bound to Fn.
(Older `settings.toml` files may still carry a `default_mode_id` key — it is ignored and dropped on the
next write.)

The mode editor surfaces `source = "selection"` + `output = "replace_selection"` together as a
single **"Rewrite selected text"** checkbox; the two-field model stays in TOML for flexibility.

### Settings UI vs advanced TOML

The Settings UI exposes mode behavior in user-facing terms. Some fields stay available in TOML
without being normal editable controls because changing them casually can make a mode feel broken
or make global behavior hard to reason about.

| TOML field | Settings behavior | Why it is advanced |
|---|---|---|
| `insertion` | New and edited modes use `paste` in Settings. If a mode file sets `insert` or `type`, Settings shows a read-only note that a custom insertion method is active. | `insert` and `type` are compatibility escapes for unusual targets. They need Accessibility permission and can fail app-by-app, while `paste` is the predictable default. |
| `submit` | New and edited modes use `none` in Settings. If a mode file sets `return`, `shift_return`, or `cmd_return`, Settings shows a read-only note that the mode sends a key after insertion. | Submit keystrokes can send unfinished messages or commands in the target app. They are useful for deliberate automation modes, not casual editing. |
| `dictionary.include_global` | No per-mode toggle in Settings; global dictionary terms stay included by default. | Turning this off makes a mode stop using vocabulary the user expects to apply everywhere. |
| `replacements.include_global` | No per-mode toggle in Settings; global replacements stay included by default. | Turning this off creates surprising mode-specific replacement gaps. |
| `source` + `output` | Shown as one “Rewrite selected text” control. | The app-supported selection workflow is the paired shape: capture the current selection and replace it with the rewritten result. |
| `trigger_keys[]` beyond the first, `tap_threshold_ms` | The first entry's key and press style are editable in Settings (“Shortcut” and “Press behavior”). `tap_threshold_ms` and every entry after the first are TOML-only; further entries show as a read-only “Also starts with” note in the mode editor and are preserved when the first is edited. | One shortcut covers nearly everyone; a second is a routing detail, and the shortcut well stays one control showing one binding. |

---

## Seeded starter modes

A fresh install writes **only `_direct.toml`** (the Direct floor). The starter modes below are
**templates**, not files: at first launch each catalog id is recorded in the seed ledger as an
**offer** (a `seed-ledger.toml` entry with a nil fingerprint), and the modes materialize on demand
from the Modes pane (Add Mode menu + template gallery) or when the first AI service connects
(Cleanup + Edit Selection). A materialized template written at its catalog id IS a seed — it keeps
`seed_id`/`seed_version` and gets a real ledger fingerprint, so unedited materialized seeds still
participate in seed updates; a second copy of the same template is a plain user mode (suffixed id, no
seed identity). They are ordinary mode files — nothing about them is special-cased in source — and the
user can edit or delete any of them. **Existing installs keep their previously-seeded starter files**
unchanged. Plain local dictation on Fn is provided by the **Direct** system mode (`_direct`, see
"System modes"). This set is the canonical one the menu and onboarding refer to (`ui_design.md` §6
menu bar).

| id | name | Shape | Rewrite |
|---|---|---|---|
| `polish` | Cleanup | `source = dictation`, `output = cursor`, trigger `right_option` | light cleanup (fillers, grammar, punctuation) that keeps wording and tone. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌥**. |
| `message` | Message | `source = dictation`, `output = cursor` | **disabled by default.** casual chat-style message; no greeting/sign-off. A discoverable example enabled in Settings. |
| `email` | Email | `source = dictation`, `output = cursor`, phrase `as an email` | **disabled by default.** polished professional email with greeting + closing; never invents names/facts. A discoverable example enabled in Settings; once enabled, route to it by ending a dictation with **"as an email"**. |
| `edit-selection` | Edit Selection | `source = selection`, `output = replace_selection`, trigger `right_command` | transforms the selection from a spoken instruction. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌘**. |
| `ai-prompt` | AI Prompt | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation into a clear instruction for an AI assistant, preserving technical terms; never answers it. Intended as a smart-model example. |
| `code` | Code | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation for IDEs, code review, issues, commits, and coding assistants while preserving technical identifiers. |
| `markdown` | Markdown | `source = dictation`, `output = cursor` | **disabled by default.** Reformats dictation into raw Markdown (headings, bullet/numbered lists, bold, blockquotes, inline/fenced code) without wrapping the output in a code fence. |
| `shell` | Shell | `source = dictation`, `output = cursor` | **disabled by default.** Turns a spoken command or description into a single terminal-ready shell command, mapping spoken symbols ("dash dash", "pipe", "tilde slash") to shell syntax; emits only the command, never runs or explains it. |

The template catalog defaults (`enabled = false` in the catalog, `polish`/`edit-selection` carrying
Right-⌥/Right-⌘ and `email` carrying the "as an email" phrase) describe the mode a template
materializes into: materializing sets `enabled = true`, drops any trigger already held by an enabled
mode, and prefills the connection when exactly one exists. `message`, `ai-prompt`, `code`, `markdown`,
and `shell` are added from the gallery/menu when the user wants them.

The **Direct** system mode (`_direct`, shown to users as **"Plain Dictation"**) works with zero
configuration (it's the Fn default). When the first AI service is added, onboarding materializes and
connects `polish` and `edit-selection`; the remaining starters stay as templates for deliberate setup.
The default English engine plus **Direct** is the minimum first-run target (`ui_design.md` §2 first
run). Mode prompts instruct, never answer, keep redaction tokens intact, and avoid bracketed signature
placeholders.

### Seeded example replacements

Four starters ship worked **per-mode replacement rules** — ordinary, user-editable data in the mode's
`[replacements]` table, each teaching one technique behind a deliberate trigger phrase that plain
prose can't fire. The phrase language is uniform: point insertions say **"insert …"** (optional "a",
like the live-edit commands) and paired spans say **"begin …" / "end …"** (like verbatim):

| Mode | Say | Inserts | Teaches |
|---|---|---|---|
| `markdown` | "insert checkbox" | `\n- [ ] ` | `\n` output + boundary classes that absorb STT pause punctuation; `check ?box` covers both spellings |
| `markdown` | "insert horizontal rule" | `\n\n---\n\n` | the left class is `[\s,]*` (space/comma only) so a preceding sentence period survives |
| `markdown` | "begin/end bold", "begin/end italic" | `**` / `*` hugging the span | the smart-quote recipe (tips doc): the open marker hugs the next word, the close marker the previous one |
| `markdown` | "begin/end code block" (or "… code fence") | `\n```\n` | a symmetric block marker eats both sides so fences land on their own lines |
| `code` | "insert todo" | `\n// TODO: ` | `to[- ]?do` alternation for STT's "todo" / "to do" / "to-do" renderings |
| `message` | "shrug emoji" | `¯\_(ツ)_/¯` | a literal rule inserts its output verbatim; spoken alone it is a whole-utterance replacement and skips the rewrite |
| `email` | "my sign off" | `\n\nBest,\nYour Name` | a personalizable stub — say it once, then edit the rule into your own signature |

There is deliberately **no bare "begin/end code"** inline pair — "front end code" is everyday dev
prose and would false-fire; inline code stays a judgment call in the Markdown prompt. The prompts
pair with their rules: Markdown's no longer interprets spoken markers, it only preserves the Markdown
syntax the rules emitted (and still converts *implicit* structure — headings, lists, blockquotes,
inline code); Email's explicitly keeps a closing or signature already present in the dictated text
(the model is otherwise told never to add one). As with any replacement, output that flows into an AI
rewrite is not protected — only a whole-utterance match bypasses the model. Editing or deleting these
rules marks the mode edited and opts it out of future template updates, like any other seed edit.

### Seed reconcile & the `seed_version` discipline

Each starter carries `seed_id` (its catalog lineage) and `seed_version` (the catalog revision it was
written from). After the one-time seeding, every launch runs **seed reconcile** (`design.md` §5.1):
unedited starters are silently carried forward as the catalog drifts — renamed, newly added, or
**prompt-revised** — while hand-edited or deleted modes are never clobbered or resurrected. "Unedited"
is judged by a **template fingerprint** that excludes the `connection` and `enabled` user-knobs, so a
starter you connected during onboarding still receives updates; only editing its prompt/shape opts it
out.

> **Discipline:** whenever you change a starter's template in `starterModes()` (prompt, fragments,
> source/output, commands, trim), **bump that starter's `seed_version`**. The version bump is the *only*
> signal that carries the revision to existing installs — change the prompt without it and the
> improvement ships to fresh installs only, never to anyone already running. The
> `revisingAStarterTemplateRequiresAVersionBump` test pins each starter's `(seed_version, template
> fingerprint)` and fails on an un-versioned template change to enforce this.

> **Sequencing footgun:** never ship a starter's *first-ever* `seed_version` bump in the same release
> that introduces or changes the fingerprint scheme — split them across two releases. The first reconcile
> on an upgrading install writes that install's template fingerprint; a bump in that same pass has no
> baseline to match yet, so reconcile skips it (the self-heal needs the on-disk template to still equal
> the catalog, which a bump breaks). The mode is left on its *prior, still-working* prompt — no crash or
> corruption — but the revision never reaches that narrow population (upgraders who connected/enabled but
> never edited the mode). Fresh installs are unaffected. Let this introducing release settle the
> fingerprints first; bump in a later one and it lands cleanly.

---

## Referenced config files

### `connections.toml` — named LLM connections (BYOK)
```toml
schema_version = 1

[[connection]]
id = "gemini-flash-lite"        # referenced by modes
name = "Gemini Flash Lite"
provider = "gemini"             # "openai" | "anthropic" | "gemini" | "openai_compatible"
model = "gemini-flash-lite-latest"
key_ref = "keyscribe.llm.gemini-flash-lite"   # Keychain item id — the key itself never lives in TOML
# auth_method = "api_key"       # "api_key" | "token_command" | "none"; defaults to "api_key"
# base_url = "https://..."      # required for openai_compatible endpoints
# token_command = "..."         # required when auth_method = "token_command"
[connection.params]
temperature = 0.2
max_tokens = 2048   # floor; raised per request for long edit-in-place selections (prompt_design.md budget policy)
reasoning_effort = "none"      # OpenAI defaults only
gemini_thinking_level = "minimal" # Gemini defaults only
```

**`reasoning_effort` is provider-specific — do not copy it across providers.** Valid values differ by
backend and even by model (native OpenAI accepts `none`; many OpenAI-*compatible* proxies require one of
`minimal|low|medium|high` and reject `none` with a 400). KeyScribe does not validate the value on our
side, because "valid" is defined by the server, not us. Instead, if the endpoint rejects the parameter,
the client automatically drops `reasoning_effort` and retries (remembering the working shape for that
connection), and any rewrite that still cannot run records the reason in History under *Why local was
kept* instead of falling back silently. Use **Test** in the connection editor to confirm a value works.

The editor's hosted quick-setup presets (OpenRouter, Groq, Mistral) are **not** distinct providers on
disk — each persists as a `provider = "openai_compatible"` connection with the preset's `base_url` and a
lightweight default `model` (e.g. OpenRouter → `https://openrouter.ai/api/v1` /
`google/gemini-3.1-flash-lite`, Groq → `https://api.groq.com/openai/v1` / `openai/gpt-oss-20b`,
Mistral → `https://api.mistral.ai/v1` / `mistral-small-latest`). The preset only seeds the draft so the
user just adds a key; reopening the connection recovers the preset from its base URL.

`auth_method` controls how requests are authenticated:

| `auth_method` | Meaning |
| --- | --- |
| `api_key` | Read the secret from Keychain using `key_ref`. Hosted providers require this. OpenAI-compatible endpoints may use it when a proxy expects a bearer token. |
| `token_command` | Run `token_command` before requests and send its output as `Authorization: Bearer …`. The generated token is kept in memory only and never written to disk. |
| `none` | Send no Authorization header. Valid for local/no-auth OpenAI-compatible endpoints. |

For OpenAI-shaped connections, KeyScribe automatically selects the compatible request format for each model
endpoint. Responses requests map the rewrite system instruction to `instructions` and the user text to `input`,
send `reasoning.effort` when set, and size `max_output_tokens` with the reasoning-safe floor when a reasoning
effort is active. Every Responses request is stateless — `store = false` is load-bearing for privacy and is never
dropped: an endpoint that rejects it fails the rewrite rather than silently allowing server-side storage. A
gateway that rejects `reasoning` self-heals by dropping it (remembered per host). KeyScribe reads typed
`output_text` content and treats an incomplete response as a rewrite failure, preserving the existing validation,
retry, and local-fallback path.

`token_command` stdout may be a raw token on the first line, `Bearer <token>`, OAuth-style JSON
(`access_token`, `token`, or `id_token`), or Kubernetes ExecCredential-style JSON
(`status.token`). If stdout includes `expires_in`, `expiration`, `expires_at`, or
`status.expirationTimestamp`, KeyScribe honors that expiry with a short refresh skew; otherwise the
token is cached in memory for five minutes to avoid re-running the command for every rewrite.

### `fragments/<id>.md` — shared prompt fragments (one file per fragment)
Prose lives best as a markdown body with a small YAML header; structured config stays TOML.
```markdown
---
schema_version: 1
name: My Voice
---
Write in my voice: warm, terse, plain. Spell out contractions.
```
Fragment id = filename stem (`my-voice`). The body is the fragment text, appended verbatim.

### `dictionary.toml` / `replacements.toml` — global sets
```toml
# dictionary.toml
schema_version = 1
words = ["KeyScribe", "Parakeet", "Anthropic"]
```
```toml
# replacements.toml
schema_version = 1
[[rules]]
heard = "teh"
replace = "the"
regex = false
```

### `voice_commands.toml` — places and actions for Voice Commands (experimental)

Read only while the `voice_commands` flag is on. The Voice Commands mode understands
an app-switching verb followed by a target (`VoiceCommandGrammar.focusVerbs`), `run <action> [words]`, and `go back`, matched against the whole
utterance (case and punctuation ignored; a leading "the" is dropped from an app-switching target, so
`switch to the browser` looks for `browser`, but not from a `run` action name). The app-switching prefixes also accept
`which to` and `witch to` for `switch to`, and `two` or `too` in place of `to` after `switch`, `which`,
`witch`, or `go`. These are exact prefix alternatives, not transcript replacements: target names,
action input, and the original heard text are preserved. They apply equally to live commands and
**Preview a command**. Other command words, including `run` and `go back`, have no sound-alike alternatives.
An app answers, in every tier, to the name shown in the Applications folder and to the name in its own
menu bar when the two differ; the name KeyScribe shows and sorts by is the Applications-folder one.
A target is a running app, an app installed in an Applications folder (or one folder down inside it),
or a place from this file:

```toml
schema_version = 1

[[place]]
name = "Mail"                    # display name; also always a spoken name. Unique, ignoring case.
say = ["male", "email"]          # optional misheard form or preferred nickname
app = "com.apple.mail"           # bring this app forward, opening it if needed

[[place]]
name = "Gmail"
url = "https://mail.google.com/" # focus an open tab whose address starts with this; else open it
browser = "com.google.Chrome"    # optional: only look in, and open with, this browser

[[script]]
name = "Deploy"                  # display name; also always a spoken name. Unique among places and scripts.
say = ["ship"]                   # optional extra spoken names
run = ["~/bin/deploy", "--env", "{text}"]  # program, then its arguments

[[script]]
name = "Journal"                 # a macOS Shortcut: same naming and matching as a program
shortcut = "Journal Entry"       # the shortcut's name in Shortcuts
shortcut_id = "6E982466-2036-4362-BDEC-983051029F6A"  # optional: run by identifier, so a rename still works
input = "{text}"                 # optional text given as the shortcut's input
```

Settings lists both kinds under **Actions**. Each `[[script]]` sets **exactly one** of `run` (a program) or
`shortcut` (a shortcut from the Shortcuts app); `shortcut_id` and `input` apply only to a shortcut.

**Scripts** run a program when you say **run** followed by their name, and can be handed what you say after it:

- `run` is the program followed by its arguments. The program is a full path (`/…` or `~/…`); it is run
  directly, never through a shell, from the home folder, with standard input, output, and error not
  connected to anything you see, and the environment KeyScribe itself was started with. Opened from Finder or
  at login, that `PATH` holds only the system folders. Each argument is passed exactly as
  written, except that `{text}` is replaced by the spoken text inside that argument: the words never
  become extra arguments, and KeyScribe never evaluates them. `{text}` may not appear in the program.
- **Matching** requires **run** (`run deploy staging`), followed by one of the script's spoken names in
  whole words (case and punctuation ignored). A bare name or an app-switching phrase never runs a script;
  **run** never opens an app or place. The spoken name is independent of the executable's filename:
  `name = "Foo"` can point at `~/bin/bar.sh`. A script whose arguments use `{text}` needs words after its
  name; saying only `run {name}` fails with a message and runs nothing. A script without `{text}` runs
  only when `run {name}` is the whole utterance. The longest spoken name after **run** is chosen first,
  and only then are its words checked, so "run ticket new"
  asks for text for a `Ticket new` script rather than running `Ticket` with "new"; a longer name without
  `{text}` that has more words after it is skipped. Scripts tied for the longest name are offered as a
  numbered choice, and the words after the name are kept for whichever one is chosen.
  A script is never matched by a near-miss, and the dictionary never corrects its name or arguments.
  These matching rules apply after mode replacements, which can explicitly produce a **run** command.
  `go back` returns to the
  previous app; a script named `Go back` instead requires `run go back`. Command words can be script names
  because the **run** prefix separates script execution from app switching.
- **The text** is what follows the spoken name, in the cleaned transcript's own case and punctuation, with
  leading and trailing spaces and the `, ; : . ! ? …` that speech recognition adds at the edges removed.
  The voice-commands dictionary never corrects it.
- **Shortcuts** run through `/usr/bin/shortcuts run`, by `shortcut_id` when it is set and by name
  otherwise. `input`, with `{text}` replaced by the spoken text, is written to the shortcut's standard input,
  which the shortcut receives as text; without `input` it receives nothing. An `input` containing `{text}`
  needs words after the name, exactly like a program argument. A failure shows the shortcut's last error
  line, without an exit status. A shortcut can wait on a question (Ask for Input, Choose from Menu, an
  alert, or a first-run permission prompt), so the late reporting below matters most for shortcuts.
- **Running:** the command waits up to about a second and a half. An action that exits with status 0 then
  is done. One still running is shown as started (*Started, still running* in the HUD, *Command started*
  in History) and is left to finish, with no time limit, so a shortcut waiting on your answer is never
  stopped. When it does finish, its History entry is updated to the final result, and a failure is shown in
  the HUD unless a dictation is in progress. A result arriving after KeyScribe quits is not seen, so that
  entry stays *Command started*. A nonzero exit fails the command, showing the exit status and the last
  line the script wrote to standard error. A program that is missing or not executable fails without
  starting. The script's arguments and output are never logged. Standard output is never kept; with history on,
  History saves the command line, arguments included, and a failure's message, which can carry the last line
  the script wrote to standard error (see *History records* above). A newly written or edited file
  can take longer to start the first time, while macOS checks it.
- **Interpreters cannot take `{text}`.** A script whose program has a known interpreter file name, such
  as `sh` or `env`, including a version suffix like `python3.12`, is refused when any of its arguments
  contains `{text}`, because `/bin/sh -c {text}` would run spoken words as shell commands. The name is
  checked as written and after following symbolic links, so a link to `/bin/zsh` under another name is
  refused too. For a known wrapper program (such as `nice`, `nohup`, `xcrun`, or `timeout`), the rule
  checks the program the wrapper launches, skipping the wrapper's own options, so `nice /bin/sh -c {text}`
  and `xcrun swift -e {text}` are refused while `nice ~/bin/record --category python {text}` is not. The rule also refuses an interpreter given a script file
  (`/bin/sh ~/bin/note.sh {text}`); instead, start that file with a `#!` line naming its interpreter and
  any options it needs, make it executable, and choose the file itself as the program. An interpreter
  without `{text}`, such as `osascript -e` with fixed code, is allowed. The editor will not save a refused
  script. One that is already in the file still loads with everything else, but saying it runs nothing
  and shows why. The rule prevents a common mistake; it does not make other programs safe. A copied
  interpreter, a wrapper the rule does not know, or a script that runs its input as code (`eval "$1"`)
  can still run spoken words as code, so write scripts that treat the text as data, as in `"$1"` below.
- **An invalid entry rejects the whole file**, like any other validation error in it: when KeyScribe
  starts with such a file, no saved places or actions are available until it is fixed (apps still open
  by name), and while KeyScribe is running it keeps the last version that loaded. The Voice Commands
  editor names the offending entry and why it is invalid. Fix or remove that entry in
  `voice_commands.toml` and save; the file is read again automatically.
- **A complete example.** A file `~/bin/note` containing

  ```sh
  #!/bin/sh
  printf '%s\n' "$1" >> "$HOME/notes.txt"
  ```

  made executable with `chmod +x ~/bin/note`, and the entry

  ```toml
  [[script]]
  name = "Note"
  run = ["~/bin/note", "{text}"]
  ```

  turns "run note buy milk" into `~/bin/note "buy milk"`, which appends `buy milk` to `~/notes.txt`.

- **What is matched is the cleaned transcript.** Before anything is matched, the Voice Commands mode's own
  replacements run over the whole utterance, so one can repair other misheard verbs
  (`stitch to Mail` → `switch to Mail`).
  Then its dictionary fixes near-misses in the **target only** — never in the command words, so a term like
  `Lunch` cannot turn "launch Safari" into something that no longer parses — which lets a target keep its
  real spelling (such as `Spotify`). Dictionary correction is best-effort and excludes terms shorter
  than four normalized characters. A replacement that owns the whole utterance becomes the command,
  which makes custom spoken shortcuts (`code` → `switch to Visual Studio Code`). A terminal `<CR>` on a
  regex replacement is dropped, since a command never presses Return; a literal replacement keeps `<CR>`
  as written, as everywhere else. On a speech model that can steer recognition, the dictionary steers it
  too. When the file has no `[dictionary]` or `[replacements]` table, or one without `include_global`,
  global vocabulary is left out.
- **A repeatable mishearing** can be repaired in **Settings ▸ Vocabulary ▸ Voice Commands** with a
  literal replacement: **Word or heard phrase** `switch to male`, **Use instead** `switch to Mail`,
  with **Match heard phrase as a regular expression** off under **Pattern matching**.
  A full-command rule avoids changing the common word `male` elsewhere, including in words passed to
  scripts and shortcuts. Alternatively, the Mail place above accepts `male` and `email` as spoken names, so both
  `switch to male` and `open email` reach Mail without rewriting the transcript. Keep these fixes in the
  mode's vocabulary unless you deliberately want other modes to use them. See the
  [worked examples in the FAQ](../../FAQ.md#a-voice-command-keeps-being-misheard).
- A place sets **exactly one** of `app` or `url`; `url` must be `http`/`https`. A script sets `run` or `shortcut`. A file that breaks a rule
  fails to load as a whole and the last good copy stays in effect (surfaced like any malformed config file).
- **Matching order**, first hit wins: a place's spoken name exactly; a running app's name exactly; a
  contiguous run of words in a running app's name ("chrome" → Google Chrome); the same partial rule on
  place names; an installed app's name exactly; then an **open window's title**, exactly and then as a
  contiguous run of words; then an **open browser tab's title** the same two ways; then installed apps
  partially. Only if nothing matches is the target matched fuzzily against every one of those: a
  near-miss is snapped, using the dictionary's fuzzy rule, against places, running and installed apps,
  window titles, and tab titles, and a name or title also matches when it contains every spoken word in
  any order ("strava run" → `Afternoon Run | Run | Strava`). The fuzzy step runs the tiers above in the
  same order, so a fuzzy hit on a place still beats an equally close one on an app, window, or tab.
  Different targets tied at the winning step are offered as a numbered choice and nothing runs until one
  is chosen; above `VoiceCommandChoice.displayLimit` targets the command fails and asks for more of the
  name. Places and actions keep their configured order in the choice, apps are sorted by name. A
  near-miss picks the closest target; targets tied for closest go through the same order, so a place
  still beats an app equally close, and two tied at the same step are offered whatever order they are
  listed in. Places or actions may share a spoken name on purpose — that is how to get the choice — so a
  shared name is an advisory in Settings, never a load error; primary names must still be unique. The
  advisory compares names the way each family is matched: places ignoring spaces, actions word by word.
- **Window titles** are read over Accessibility on this Mac, and only when no place or app name matched
  first, so an exact app name (`open Slack`) never looks at windows. A title matches exactly when the
  spoken target equals the whole title or one of its parts: apps put the document, project, and app name
  in one title between separators such as a spaced dash or a pipe (`WindowTitle.segments` holds the
  rule). Only standard windows with a title are matched, minimized ones and those of hidden apps included; sheets,
  panels, and dialogs are not, nor are this app's own windows. macOS lists only the windows on the
  current desktop, so a window on another desktop or in another full-screen app cannot be found from
  here, though its app's name still works. A browser window is matched by its current tab's title, since
  that is the window's title, and wins over that same tab. A choice between windows names each one's app,
  and the document or site when two titles are the same.
- **Tab titles** are read from every running browser whose tabs can be listed (see *Tab matching* below),
  only when no place, app, or window matched first, and are split into parts like window titles. Reading them
  uses the same Automation permission as a web place, so the first such command can be what asks macOS for it;
  a browser that refused or did not answer contributes no tabs. If the tabs cannot be read in time, the command
  fails rather than choosing from the rest. A choice between tabs names each one's browser and site. A tab is
  focused by its address, re-checked just before it moves; if it has closed, the command says so and opens
  nothing.
- **If any app does not answer when its windows are read**, the command fails without opening anything
  (`Could not check all open windows. Nothing was opened. Try again.`) rather than choosing from the
  windows that did answer. When Accessibility is off, the command says so and offers its settings.
- **A window is brought forward by identity, never by title.** The choice made when the command was
  heard is re-found in the same process just before it moves; if it has closed, the command says so and
  brings nothing else forward, and if the app does not answer it fails without trying anything else. A
  step already taken (a window unminimized, say) is not undone when a later one fails.
- **Tab matching** ignores the scheme, a leading `www.`, the host's case, and trailing slashes, and respects
  path boundaries (`mail.example.com` never matches `mail.example.community`). The path, query, and fragment
  keep their case: `example.com/Project` does not match a tab on `example.com/project`. Only browsers whose
  scripting dictionary describes tabs are asked; any other browser has its page opened directly, since its
  tabs cannot be read. Which browsers can be asked is rechecked while KeyScribe runs, so a browser installed or
  updated later is used without relaunching. Asking goes through Apple Events, so macOS asks once per browser for Automation
  permission. The command waits for that answer, then reads the tabs; a prompt left unanswered for a
  minute counts as a browser that could not list its tabs. If the browser that would open the page has refused, the command fails with a pointer to
  that setting instead of opening a second copy. A place with no `browser` looks through the tabs of every
  running browser that can list them, and if none has the page open, opens it in whichever browser macOS
  opens that address with. If the tabs cannot be read in time, or the browser that would open the page could not list them, the command also fails
  rather than open a second copy of a page that may already be open. Once the command gives up, no further
  browser is asked, and a script already waiting stops on its own a few seconds later, so a browser that
  hangs holds up a later command for a few seconds at most. A place with a `browser` reads only that browser's tabs, and if that
  browser is not installed the command fails rather than opening another browser.
- **Focusing a tab re-checks it first**: the tab must still show the address it had when it was found
  (looked up again if it moved), compared case-sensitively like the match itself. If the tab is gone, the
  page is opened instead. If the browser does not answer in time, the command fails and nothing else is
  opened. An Apple Event already sent cannot be recalled, so a browser that answers late may still select
  the tab inside its own windows, but it is never brought forward: only an answer in time does that.
- **A take whose microphone stopped never runs a command**, including a loss that arrives while the command
  is being looked up or while a tab is being focused. Nothing further is opened or brought forward.
- `go back` returns to the window that was in front before the last switch by voice, even within the same
  app, or to its app when that window has closed or is no longer on this desktop. It never opens another
  copy of an app that has quit since, and an app that does not answer leaves the destination in place for
  another try. A command whose target was already in front keeps the earlier destination. Running a
  script or shortcut does not change it. It is kept in memory only, so it is lost when the app quits.
  Repeating `go back` switches back again.
- **Preview a command** in Settings never runs a command, script, or shortcut, but previewing a web place reads the open tabs,
  so it can be what first asks macOS for permission to control a browser, and previewing a phrase no app or
  place matches reads the open windows' and tabs' titles. Reading windows never asks for a permission; reading
  tabs can.

### Replacement matching & output

How a rule behaves once it matches:

- **Rules match the heard text once.** Replacement output is inserted as-is and is never scanned by
  another replacement. When matches overlap at the same position, the longest actual match wins. Equal
  matches prefer a mode rule over a Global rule, then the topmost rule in the same scope. Regex and
  literal rules use the same actual-match-length comparison; zero-length regex matches do nothing.
- **Literal rules match case-insensitively, on whole words** (`pipe` never fires inside `pipeline`);
  the replacement text is inserted verbatim (`$` / `\` are not template refs).
- **Regex rules also match case-insensitively by default.** The input is STT output, whose casing
  the engine chooses (it commonly capitalizes the first word), so a case-sensitive pattern would
  silently miss. Opt back into case sensitivity with an inline `(?-i)`. Capture substitution (`$1`,
  `\$` for a literal `$`) works as usual. Note the capture preserves the *matched* text's case — the
  replacement template has no case-folding, so `slash (\w+)` → `/$1` on a spoken "Dog" yields `/Dog`,
  not `/dog`.
- **A nested-quantifier ("evil") pattern is refused at authoring.** The pipeline screens patterns like
  `(a+)+` before running them (they can catastrophically backtrack; see `design.md` §4.2 table), so the
  editors reject such a pattern instead of saving a rule that would be silently dropped at dictation
  time. A hand-authored rule that fails the screen still loads but never runs; re-saving it requires
  simplifying the pattern.
- **Regex rules interpret `\n` / `\t` / `\r` in the replacement as real newline / tab / carriage
  return** — the same convention as an editor's regex-mode replace field (VS Code, Sublime). A
  literal rule does *not* interpret them; write `\\` for a literal backslash. **Spell the escape with a
  TOML literal (single-quoted) string** so the backslash reaches the rule intact — this is also how the
  Settings editor writes it:

  ```toml
  [[rules]]
  heard = 'insert code fence'
  replace = '```\n'      # regex mode: inserts a fenced line + a newline
  regex = true
  ```

  Dictate it alone and it comes out **bare** (see below), so the trailing newline is not trimmed. A
  *basic* (double-quoted) string is a TOML footgun here: TOML itself decodes `"...\n"` to a newline
  before any rule runs, so `"```\n"` would insert a newline even on a *literal* rule — use `'...\n'`
  (or `"...\\n"`) to keep the `regex` flag in control. Note a control char is inserted as-is only on
  the whole-utterance (bare) path; used mid-sentence it flows through the AI rewrite like any text.

- **A replacement that owns the WHOLE utterance is inserted exactly — bare.** When the entire
  dictation (ignoring surrounding whitespace and a trailing `.` / `!` / `?`) reduces to a single
  replacement, its generated value is inserted verbatim: **no AI rewrite, no `trailing` suffix, no
  `trim_trailing_punctuation`**. Said as *part of* a longer utterance, the same rule is ordinary text
  and the mode's normal rewrite/trailing apply. This makes spoken commands deterministic without a
  per-rule flag:

  | You say | with rule `slash (\w+)` → `/$1` | Output |
  |---|---|---|
  | "slash resume" | owns the whole utterance → **bare** | `/resume` |
  | "send slash resume" | part of a larger utterance → normal | `send /resume. ` |
  | "slash resume now" | part of a larger utterance → normal | `/resume now. ` |

  The trailing `. ` in the last two rows is the mode's normal decoration (rewrite punctuation +
  `trailing`); only the first row, where the command *is* the whole utterance, comes out bare. The
  rule is "one replacement owned the whole thing," so it never fires for a fuzzy-dictionary
  correction — only an explicit replacement that consumed the entire utterance.

- **A regex replacement can press Return with a terminal `<CR>`.** Appending `<CR>` to the *end* of a
  **regex** replacement template requests a physical **Return** key press after the whole-utterance
  insert — for a command like `slash resume` → `/resume` that then runs, sends, or activates a default
  control:

  ```toml
  [[rules]]
  heard = 'slash resume'
  replace = '/resume<CR>'   # inserts /resume, then presses Return
  regex = true
  ```

  - `<CR>` is stripped from the inserted text (with any whitespace right before it) — it never appears
    as literal text, and never reaches the AI rewrite. Capture expansion still works: `'/$1<CR>'`.
  - It is honored **only** when the rule owns the whole utterance (the bare path above). In the middle
    of a longer sentence the rule does its ordinary text replacement and presses nothing.
  - It is recognized **only** in a regex rule and **only** at the very end. `<CR>` in a *literal* rule
    is inserted verbatim (Settings flags such a rule); a `<CR>` anywhere but the end of a regex template is invalid and the rule is
    ignored. Write `\<CR>` to emit the literal text `<CR>` in a regex replacement.
  - The Return is a real key press, **not** a guaranteed "send" — its effect depends on the focused
    target. It fires only after the text verifiably lands (never on a clipboard fallback, a password
    field, or if focus moved), and `replace = '<CR>'` alone presses nothing (empty output → no-speech).
  - **A trailing newline immediately before `<CR>` cannot be preserved.** All whitespace right before the
    marker — spaces, tabs, *and* line breaks — is stripped with it, so `last line\n<CR>` inserts `last
    line` and then presses Return. That is the intended shape for a submit-style macro; if you need a
    kept trailing newline, do not follow it with `<CR>`.

### Multiline replacement text & the authoring limit

A replacement may contain real line breaks, so a short spoken phrase can expand into a block of text
without regex syntax. The Settings **Use instead** field grows to a few lines and offers **Open in a
larger editor…** for a full multiline body. Quick-correction surfaces keep the compact field, while a
saved rule's edit popover shows the multiline editor inline.

- **The replacement is preserved exactly.** Only the heard phrase / regex pattern is trimmed; the
  replacement keeps its leading, trailing, embedded, and repeated whitespace and line breaks verbatim.
  An empty replacement adds a dictionary word in the composer; any nonempty value — including one made
  only of spaces or line breaks — is a replacement. (A saved rule may still replace with the empty
  string through the rule editor, the delete-text capability.)
- **Newline representation is not converted between forms.** A *literal* rule inserts exactly what you
  authored, so a real line break inserts a line break and the two characters `\n` stay the visible
  characters `\` and `n`. A *regex* rule interprets `\n`/`\t`/`\r` as controls (above), so a real line
  break and `\n` produce the same newline. The one normalization: pasted CRLF and lone CR are converted
  to LF at the editor boundary (macOS treats LF as the native break).
- **Authoring limit: 65,536 characters.** The editor shows `current / 65,536` and refuses to save an
  over-limit draft (the complete draft is retained so you can trim or copy it — never silently
  truncated). A hand-authored rule already over the limit still **loads** (the limit gates authoring,
  not loading); Settings surfaces it and requires shortening before that rule can be saved again. The
  compact list preview is always one bounded line regardless of the stored size.
- **A large macro's output is not scanned again.** Its content is inserted exactly as authored by the
  replacement stage, regardless of text that resembles another rule's heard phrase. An AI rewrite may
  still transform it unless the macro owns the whole utterance.
- **Replacement config is plaintext on disk.** Do not store credentials or other secrets in a
  replacement.

### `settings.toml` — general
```toml
schema_version = 1

load_on_login = false

[stt]
engine = "parakeet-ultra"       # the single active engine (default: Parakeet Ultra)
eviction = "fastest"            # "fastest" | "balanced" | "frugal" (default: fastest)
# Governs both STT-model residency AND idle microphone warm-up (the input unit is kept prewarmed for
# instant starts). Fastest = model loaded + mic held warm (periodic binding refresh); Balanced = both
# released after eviction_idle_seconds idle; Frugal = mic opened only while dictating, model freed each
# dictation.
# eviction_idle_seconds = 1800  # used when eviction = "balanced" (default: 1800 = 30 min)
# The one dictionary-mechanism control: recognition bias is default-ON for the engines that support it
# (the bias-capable ones) and can be disabled per engine. Post-STT dictionary recovery has no toggle
# — it runs whenever the mode's dictionary is non-empty. Only deviations are recorded (fresh install
# writes the list empty):
# recognition_bias_disabled_engines = []  # bias-capable engines with recognition bias turned OFF
# (The former dictionary_recovery_enabled_engines / dictionary_recovery_disabled_engines /
#  dictionary_recovery_engines keys are obsolete: ignored on read and dropped on the next write.)

[during_dictation]
other_audio = "quiet"           # what happens to other audio while you dictate: "quiet" (default, turned
                                #   down but still audible), "mute" (silenced), "unchanged" (left alone).
                                #   Ducks (FaceTime-style, cannot strand); lands after the start sound,
                                #   instant when sounds = false
# (The former mute_system_audio key is obsolete: still read when other_audio is absent, and dropped on
#  the next write. true maps to "quiet" — deliberately NOT "mute": mute was the shipped default, so
#  upgrading users adopt the new default rather than keeping full silence. Pick "mute" to keep it.
#  false maps to "unchanged".)
keep_display_awake = true
sounds = true                   # start/end sounds
sound_volume = 100             # relative dictation-sound level; 100 = full cue level, 0 = silent (0 also
                                #   skips the start cue, so capture admits with no cue hold)

[history]
enabled = true
retention_days = 7              # default; delete day-files older than this

[hud]
appearance = "system"           # "system" | "opposite" | "light" | "dark"; the HUD only — every
                                #   window follows the Mac

[shortcuts]                                 # global shortcuts for menu-bar actions
add_vocabulary = "control+option+shift+v"        # canonical chord; "" = off
paste_last_dictation = ""                        # canonical chord; "" = off (default)

[insertion]                                 # how a paste hands the clipboard back; TOML-only, no Settings UI
# clipboard_restore_ms = 250                     # ms the dictation stays on the clipboard after the paste
                                                 #   keystroke, before your clipboard is put back (must be >= 1)

[audio]                                     # written by the Settings mic picker; no UI for the debug keys
# input_device_uid = "BuiltInMicrophoneDevice"   # preferred capture device; absent = follow the system default
# input_device_name = "MacBook Pro Microphone"   # possibly-stale label, so a disconnected device still reads as itself
# keep_captures = false                          # debug: retain a copy of each committed capture WAV
# keep_captures_max_mb = 500                     # soft budget for the archive; oldest pruned first
```

> **`[audio]`** — `input_device_uid` is a CoreAudio UID (stable across reconnect, unlike the ephemeral
> device id), resolved live at each bring-up: the preferred device if present, else the system default.
> Capture never changes the macOS system default input.
>
> `keep_captures` is a **debug affordance, default off, with no Settings UI** — a capture WAV normally
> lives only record→transcribe→delete. Turned on, each committed capture is cloned into
> `~/Library/Application Support/<KeyScribe|KeyScribeDev>-captures/` (a sibling of the config dir, so a
> WAV can never fire the config watcher) and the archive is pruned oldest-first to `keep_captures_max_mb`.
> The clone is COW, so retention writes no extra bytes — it only stops the WAV's blocks from being
> reclaimed. At the 16 kHz mono-float capture format, **100 MB ≈ 27 minutes** of speech.
>
> `keep_captures_max_mb` is a **soft budget, not a hard cap**: the newest capture is always retained even
> if it alone exceeds it, since deleting it would leave nothing to inspect — the one thing the archive
> exists for. So the archive can transiently hold one over-budget file.
>
> `KEYSCRIBE_KEEP_CAPTURE=<dir>` (or `--keep-capture <dir>`) overrides the directory, wins when both are
> set, and is **never pruned** — retention only ever deletes inside the app-owned archive. Both keys are
> omitted from the file while `keep_captures` is off, and **Erase All Data** removes the archive.

> `clipboard_restore_ms` is **global, not per-mode**: the delay depends on how the target app reads the
> pasteboard and how fast the machine is, neither of which varies by mode, so one value serves every mode
> (Plain Dictation included) and Paste Last. The window exists because a target may read the pasteboard
> **asynchronously, and possibly more than once** after ⌘V (reported of Chromium and Electron apps), so
> restoring instantly can hand that read your old clipboard instead of the dictation. It is also the
> window in which pressing ⌘V yourself pastes the dictation a **second** time instead of your clipboard,
> so it is kept as short as an asynchronous reader tolerates; raise it only for a target where the paste
> comes out empty or stale. A value below 1 is refused (the file fails to load). Elided from the file at
> the default. Ignored under a mode's `clipboard_sync = true` (which never restores) and
> `insertion = "type"` (which never touches the clipboard).

> **`[shortcuts]`** drive the standalone **Add to Vocabulary…** panel and
> the **Paste Last Dictation** action (both also always available in the menu bar). Add to Vocabulary
> **defaults on** to `⌃⌥⇧V` — the
> triple-modifier zone the system never reserves, so the global grab is least likely to collide with
> an app; **Paste Last Dictation defaults off** (`""`). An **absent** key falls back to that field's
> default; an explicit `""` means the user turned it
> off. Only **chord** descriptors are honored (a
> bare modifier key already drives dictation). The event tap is **active** (`.defaultTap`), so a
> registered chord — for these shortcuts and for mode triggers — is **swallowed** before the focused
> app sees it (otherwise e.g. ⌃⌥E reaches the app as the Option-E dead key and replaces the selection).
> The tap falls back to listen-only when an active tap can't be created (Accessibility not yet granted),
> in which case the chord passes through until Accessibility is granted. Set in Settings ▸ General.

---

## Conventions
- **Older schema versions** are normalized on read. KeyScribe does not rewrite a file just because a
  read migration ran, and it does not create pre-migration backups today; a later save writes the
  current schema.
- **Rewrites normalize to this schema** and drop comments. A file whose `schema_version` exceeds the
  app's is left untouched and surfaced (`design.md` §5.1). **No rewrite drops an unknown key:** a save
  from the app to a file holding one is refused with a notice naming the file and key, leaving the file
  and the unsaved edit as they were, and an automatic rewrite (a starter-mode update or rename) skips
  that file. For `settings.toml`, app-wide changes still apply but are not saved until the key is fixed
  or removed.
- **Unknown keys are reported, not fatal.** A key this schema does not read — usually a typo such as
  `trigger_key` for `trigger_keys` — loads as if absent and is listed in Settings → Maintenance (and in the
  mode's editor for a mode file), with the nearest real key when one is close. Retired keys noted in this
  document are exempt.
- **Secrets never in TOML** — saved LLM keys live in Keychain; command-generated tokens live only in
  memory. TOML stores `key_ref`, `auth_method`, and the command to run, never key or token material.
- **kebab-case ids**, snake_case fields, consistently.

## Notes & conventions
- **Verbatim is a live edit** — gated by `commands.live_edits` (no separate toggle); triggered
  by "begin verbatim" / "end verbatim".
- **"Insert clipboard contents" is a live edit** — same `commands.live_edits` gate; triggered by
  "insert clipboard contents"; pastes the
  clipboard at that point, tokenized like a verbatim span so it is inserted as-is and never sent to
  the LLM. Dictation only (not edit-in-place). Empty/absent clipboard leaves the phrase as text.
- **`include_global` is per-set** — dictionary and replacements each carry their own flag.
- **Key descriptor format** — lowercase tokens joined by `+`, and the token list decides the shape:
  **every token a modifier and no base key → a modifier-only trigger** (the set is held with no key
  at all); **a base key present → a chord**; a lone `mouseN` → a mouse button.
  - **Modifiers** are `control` `option` `shift` `command` `fn` (aliases `ctrl`/`alt`/`cmd`/`globe`),
    each optionally prefixed `left_` or `right_` to name the physical key: `left_command`,
    `right_option`, `left_ctrl`. `fn` is never sided — there is only one of it.
  - **A modifier-only trigger** is 1–4 modifiers, at most one of each, and never both sides of the
    same one (`left_command+right_command` is rejected). `hyper` is a **parse alias** for
    `control+option+shift+command` — it keeps loading and stays spelled `hyper` on disk, since the
    stored string is round-tripped verbatim. It is rewritten to the long form only when that mode's
    shortcut is set again, by recording it or by picking ⌃⌥⇧⌘ from the well's menu. Sideless means
    either key (`command` matches both ⌘s); sided means that one, and requires the other to be up.
    Examples: `"fn"`, `"right_option"`, `"left_command"`, `"left_command+left_control"`,
    `"command+control"`, `"fn+left_command"`.
  - **A chord** is the four chord modifiers plus one base key. Sides and `fn` are **rejected inside a
    chord** — `RegisterEventHotKey` cannot distinguish left from right and carries no Fn, so
    `left_command+k` and `fn+k` are errors rather than a silently widened binding.
    Examples: `"control+option+a"`, `` "control+`" ``, `"option+space"`, `"command+up"`, `"f5"`.
  - **A mouse button** is `mouseN` where `N` is the macOS button number ≥ 2 (`mouse2` = middle,
    `mouse3`/`mouse4` = the back/forward thumb buttons; left = 0 and right = 1 are rejected so a
    trigger can never hijack a normal click). A bound mouse button is **consumed globally** while
    KeyScribe runs — it no longer performs its normal action (e.g. browser back) — which is the same
    trade other dictation apps (Wispr, Superwhisper) make. Mouse buttons are observed under
    Accessibility alone (no Input Monitoring), like the modifier triggers.
  - **Two modifier-only triggers overlap when one press engages both** — same modifiers, and no
    shared modifier where the two name opposite keys. `command` and `right_command` are the same
    press (the later one is suppressed, as with any duplicate shortcut); `left_command` and
    `right_command` are two usable triggers, because a sided trigger requires the opposite key to be
    up.
  - **A strict subset is warned about, not suppressed.** `left_command` under
    `left_command+left_control` is pressed on the way into it, and the Settings well says so. At
    runtime the 150 ms chord grace holds the smaller trigger's arm back, so pressing the pair as one
    motion starts only the pair.
  - **The recorder writes the keys that were actually pressed**, sides and all: recording Left-⌘ + Left-⌃
    stores `left_command+left_control` and binds those keys. A trigger recorded on one side therefore does
    not fire on the other — recording ⌃⌥⇧⌘ on the left stores the all-left set, and reaching for the right
    ⇧ will not fire it. Write the sideless form here for a trigger that should accept either key.
  - **Recommended default for new modes: `fn`/Globe with `hold-or-tap`** (most familiar — Wispr and
    Apple both center on it), with **`right_option`** offered as the conflict-free alternative
    (Apple Dictation also double-taps Fn).
- **A base key is a character, not a position** — and that is what makes the descriptor portable.
  A **printing** key is written as the character the key means **as a shortcut**: `a`, `7`,
  `` ` ``, `[`, `/`, and any non-ASCII key a layout actually has (`é` on AZERTY). It is resolved
  through the **active keyboard layout** each time triggers are registered, using the same rule
  macOS itself uses — the layout's **Command-modifier table**, falling back to the plain key when a
  layout has none. That matters in both directions: on a non-Latin layout (Russian, Greek, Hebrew,
  Thai) no Latin letter is reachable by typing at all, and the Command table is what puts `⌘V` on
  the physical V key; under **Dvorak** a chord follows the Dvorak positions, while under
  **Dvorak — QWERTY ⌘** it follows the QWERTY ones, which is that layout's entire purpose for a ⌘
  shortcut — note that a chord *without* ⌘ (`control+option+e`) lands on the QWERTY position there
  too, where that layout would otherwise keep you on Dvorak. Two
  consequences: a chord the current layout cannot mean anywhere is **not registered at all** (the
  Settings shortcut well says *Not on your current keyboard layout*), and switching input source
  **re-registers** every chord without a relaunch. Because the base key is a key's *plain*
  production, a character that needs Shift is not a base key — write `` control+shift+` ``, never
  `control+~`. The same rule makes a character that a *given layout* only reaches with Shift
  off-layout there: `+` and `*` on US, and every digit on AZERTY, where the row types `&é"'(§è!çà`
  unshifted. Name the key's unshifted character instead (`control+(` is the AZERTY spelling of the
  key labelled 5) or record the shortcut and let the recorder store the right one. The numeric
  keypad is never a substitute: it has its own names, so `control+5` and `control+keypad_5` always
  mean different keys.
  The one exception is `+` itself, which is written `plus` (`control+plus`) because the grammar
  splits on `+`. It stays a word in the file too, since the character cannot survive a round trip.
- **A non-printing key is written by name**, since its position is fixed by the hardware and never
  moves with the layout: `f1`…`f20`, `space`, `tab`, `return`, `delete`, `forward_delete`, `escape`,
  `home`, `end`, `page_up`, `page_down`, `up`, `down`, `left`, `right`, and the keypad
  (`keypad_0`…`keypad_9`, `keypad_decimal`, `keypad_plus`, `keypad_minus`, `keypad_multiply`,
  `keypad_divide`, `keypad_equals`, `keypad_enter`, `keypad_clear`). **The function row is the only
  key that may be bound bare** — every other key needs at least one modifier, so a trigger can never
  swallow ordinary typing or navigation. `escape` chords are **TOML-only**: Escape cancels the
  Settings shortcut recorder, so it cannot be captured there.
- **Per-mode language** — out of scope; no `language` field, and no global language setting either.
  Transcription language follows the active engine (`design.md` §4.1), and the **rewrite** writes in
  whatever language `<content>` is already in (`prompt_design.md`). A mode that must pin a language
  or translate says so in its own `ai_rewrite.prompt`, which the language rule explicitly defers to —
  that instruction *is* the per-mode override, so a structured field would only duplicate it.
