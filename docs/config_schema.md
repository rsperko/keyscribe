# KeyScribe — Mode & Config TOML Schema

> Companion to `design.md` (§4.3 modes, §4.6 settings, §5 storage, §5.1 versioning).
> Defines the on-disk config: one TOML file per mode plus the shared config files modes
> reference. Every file carries `schema_version` and migrates forward (`design.md` §5.1).

---

## Directory layout

```
~/Library/Application Support/KeyScribe/
  settings.toml            # general settings + active STT engine + default mode
  connections.toml         # named LLM connections (BYOK)
  dictionary.toml          # global dictionary
  replacements.toml        # global replacements
  fragments/               # shared prompt fragments (one file per fragment)
    my-voice.md            #   markdown body + YAML frontmatter
  modes/                   # one file per mode; filename stem = mode id
    plain-dictation.toml
    email.toml
    pig-latin.toml
  history/                 # append-only local history, one JSONL file per day
    2026-06-20.jsonl
  backups/                 # pre-migration backups (design.md §5.1)
  models/                  # downloaded STT weights, one dir per model (design.md §4.1)
    parakeet-tdt-0.6b-v3/
```

- **Mode id = filename stem** (kebab-case). The id is stable; `name` is the display label and
  can change freely.
- Config files are human-editable text. **Model weights** are downloaded at runtime (never
  committed) into `models/`, consolidated under the KeyScribe support dir.

### Model storage

All KeyScribe data — including STT weights — lives under the one support dir. KeyScribe **points each
engine SDK at `models/<model-id>/`** where the SDK exposes a configurable download directory; where
it does not, KeyScribe manages the SDK's own location through that SDK's API and the result is the
same single disk-usage / delete story for Speech Models settings. **Apple SpeechAnalyzer is
system-managed** and has no entry here.

- **Application Support, not Caches** — weights must not be purged mid-session; they are
  re-downloadable, so deletion is always safe and the dir is marked excluded-from-backup so
  Time Machine does not store re-downloadable data.
- The `models/` dir is **not** versioned config and carries no `schema_version`.

---

## Mode file — annotated example

`modes/email.toml`

> **TOML ordering (load-bearing).** Every root-level scalar key (`name`, `enabled`,
> `trigger_phrases`, `source`, `output`, `insertion`, `exclude_from_history`) must appear
> **before** the first table or array-of-tables header (`[[trigger_keys]]`, `[constraints]`,
> `[commands]`, …). A root key written after a `[[table]]` header silently parses as a member of
> that table, not the mode. So: all the mode's scalars first, then the table sections.

```toml
schema_version = 1
name = "Email"
enabled = true

# source: "dictation" (default) or "selection" (edit-in-place: capture the current selection as
# content, dictation becomes the instruction). output: "cursor" | "replace_selection".
source = "dictation"
output = "cursor"

# Trigger phrases (Phase B). One or more regexes matched against the transcript suffix
# (raw-suffix routing). Optional.
trigger_phrases = ['(?i)\bas an email$']

insertion = "paste"          # "paste" (default) | "insert" | "type"
trailing = "none"            # "none" (default) | "space" | "newline" — appended INSIDE the atomic insert
submit = "none"              # "none" (default) | "return" | "shift_return" | "cmd_return" — keystroke AFTER a verified insert
exclude_from_history = false

# ── When it runs ─────────────────────────────────────────────────────────────
# Trigger keys (Phase A). Each has a press style: "hold-or-tap" | "hold-only" | "tap-to-toggle".
# "hold-or-tap" = push-to-talk while held, OR fires on a quick tap.
[[trigger_keys]]
key = "right_option"        # canonical key descriptor; also e.g. "fn", "hyper", "control+option+e"
press_style = "hold-or-tap"
tap_threshold_ms = 250      # release under this = a tap (latches on); over = push-to-talk hold

# Context eligibility (Phase A). Empty = eligible everywhere. A constraint ANDs its fields; any of
# bundle_id (exact), bundle_prefix (case-insensitive bundle-id prefix), url_pattern (regex, when
# detectable), window_title (regex). Also constrains which phrases can route here. Specificity ranks
# url_pattern > window_title > bundle_id > bundle_prefix (design.md §4.3).
[[constraints]]
bundle_id = "com.apple.mail"
# bundle_prefix = "com.jetbrains."        # optional; matches all bundle ids under the prefix
# url_pattern = 'mail\.google\.com/.*'    # optional; best-effort
# window_title = '(?i)pull request'       # optional; regex against the focused window title

# ── Pipeline commands (spoken-command / pipeline features, opt-in per mode) ──
[commands]
live_edits = true           # spoken commands: new line / paragraph / scratch that / tab /
                            #   "begin verbatim".."end verbatim" (verbatim is a live edit)
privacy    = false          # best-effort redaction (the mode's privacy toggle).
                            #   When true, context is forced off (see [ai_rewrite].context).
numbers    = false          # inverse text normalization: "twenty five" -> "25"
                            #   (leaves year idioms like "twenty twenty six" as words)
fuzzy_correction = false    # snap mangled words to dictionary terms ("charge bee" -> "ChargeBee");
                            #   conservative — the dictionary is a hint, not authoritative

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
context = { app = true, visible_text = false, preceding_text = false }
                                                     # selection is sent when source = "selection".
                                                     #   preceding_text = bounded text before the caret
                                                     #   (native-only, best-effort via AX).
                                                     #   Forced to all-false when commands.privacy = true.
```

### Mode field reference

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | Required. Migrated forward on load. |
| `name` | string | Display label. |
| `enabled` | bool | Disabled modes are ignored by the resolver. |
| `trigger_keys[]` | table[] | `key` (canonical descriptor) + `press_style` + `tap_threshold_ms` (default 250). Zero or more. There is no separate global hotkey — the default mode owns its trigger key. |
| `trigger_phrases` | string[] | Regexes, suffix-matched post-STT. Zero or more. |
| `constraints[]` | table[] | Any of `bundle_id`, `bundle_prefix`, `url_pattern`, `window_title` (ANDed). Empty ⇒ eligible everywhere. |
| `source` | enum | `dictation` \| `selection`. |
| `output` | enum | `cursor` \| `replace_selection`. |
| `commands.live_edits` | bool | Opt-in to the spoken-command list (new line, paragraph, scratch that, **tab**, **begin/end verbatim**). |
| `commands.privacy` | bool | Opt-in to best-effort redaction. When true, **context is forced off** — `ai_rewrite.context` is locked to all-false so only the redacted transcript leaves. |
| `commands.numbers` | bool | Opt-in to inverse text normalization ("twenty five" → "25"); bails on ambiguous/year-like runs. |
| `commands.fuzzy_correction` | bool | Opt-in to snapping mangled words to dictionary terms; conservative (the dictionary stays a hint). |
| `dictionary` | table | `include_global` + `words[]`. |
| `replacements` | table | `include_global` + `rules[]` of `{heard, replace, regex}`. |
| `[ai_rewrite]` | table | Absent ⇒ no rewrite. `connection`, `prompt`, `fragments[]`, `context`. |
| `ai_rewrite.context` | inline table | `{ app, visible_text, preceding_text }` booleans. `preceding_text` sends bounded text before the caret (native-only, best-effort via AX). (URL is a routing key only — `constraints[].url_pattern` — never sent to the LLM.) |
| `insertion` | enum | `paste` \| `insert` \| `type`. |
| `trailing` | enum | `none` (default) \| `space` \| `newline`. Literal text appended to the transcript, inside the atomic insert (one ⌘Z still undoes it all). |
| `submit` | enum | `none` (default) \| `return` \| `shift_return` \| `cmd_return`. A keystroke synthesized after a **verified** insert (outside the undo atom). Never fires on a clipboard fallback — the text never reached the target. |
| `exclude_from_history` | bool | Skip writing this mode's dictations to history. |

The **default mode** is recorded once in `settings.toml` (`default_mode_id`), not as a flag on
each mode — single source of truth, so two modes can't both claim default.

The mode editor surfaces `source = "selection"` + `output = "replace_selection"` together as a
single **"Work on selection"** checkbox; the two-field model stays in TOML for flexibility.

---

## Seeded starter modes

A fresh install ships eight example modes — six enabled, two disabled. They are ordinary mode
files — nothing about them is special-cased in source — and the user can edit or delete any of
them. This set is the canonical one the menu and onboarding refer to (`ui_design.md` §6 menu bar).

| id | name | Shape | Rewrite |
|---|---|---|---|
| `plain-dictation` | Plain Dictation | `source = dictation`, `output = cursor` | none — fully on-device. The seeded `default_mode_id`; the only mode that owns a trigger key (Fn/Globe). |
| `polished-dictation` | Polished Dictation | `source = dictation`, `output = cursor` | light cleanup (fillers, grammar, punctuation) that keeps wording and tone. Inert until a connection exists. |
| `message` | Message | `source = dictation`, `output = cursor` | casual chat-style message; no greeting/sign-off. Inert until a connection exists. |
| `email` | Email | `source = dictation`, `output = cursor` | polished professional email with greeting + closing; never invents names/facts. Inert until a connection exists. |
| `prompt` | AI Prompt | `source = dictation`, `output = cursor` | cleans dictation into a clear instruction for an AI assistant, preserving technical terms; never answers it. Inert until a connection exists. Benefits from a stronger connection (e.g. Sonnet) but is tuned to hold on the Flash floor. |
| `work-on-selection` | Work on Selection | `source = selection`, `output = replace_selection` | transforms the selection from a spoken instruction; recommends a connection but is not blocked without one (`ui_components.md` control dependencies). |
| `markdown` | Markdown | `source = dictation`, `output = cursor` | **disabled by default.** Reformats dictation into raw Markdown (headings, bullet/numbered lists, bold, blockquotes, inline/fenced code) without wrapping the output in a code fence. Inert until a connection exists. |
| `shell` | Shell | `source = dictation`, `output = cursor` | **disabled by default.** Turns a spoken command or description into a single terminal-ready shell command, mapping spoken symbols ("dash dash", "pipe", "tilde slash") to shell syntax; emits only the command, never runs or explains it. Inert until a connection exists. |

The `markdown` and `shell` modes ship **disabled** (`enabled = false`) as discoverable examples
of more technical presets — the resolver ignores disabled modes (they own no trigger key and never
auto-start), so the user enables one only after editing it to taste and attaching a connection.

Only `plain-dictation` works with zero configuration. The rewrite modes are seeded so the
rewrite and edit-in-place capabilities are discoverable, and each states in place what it needs
before it can run. The same spoken words producing a casual message vs. a formal email vs. a
cleaned AI prompt is the most legible demo of modes-as-presets. The default English engine plus
`plain-dictation` is the minimum first-run target (`ui_design.md` §2 first run). Mode prompts are
tuned for the **Gemini 2.5 Flash** floor (`prompt_design.md`) — they instruct, never answer,
keep redaction tokens intact, and avoid bracketed signature placeholders.

---

## Referenced config files

### `connections.toml` — named LLM connections (BYOK)
```toml
schema_version = 1

[[connection]]
id = "gemini-flash"             # referenced by modes
name = "Gemini 2.5 Flash"
provider = "gemini"             # "openai" | "anthropic" | "gemini" | "openai_compatible"
model = "gemini-2.5-flash"
key_ref = "keyscribe.llm.gemini-flash"   # Keychain item id — the key itself never lives in TOML
# base_url = "https://..."      # for openai_compatible endpoints
[connection.params]
temperature = 0.2
max_tokens = 2048   # floor; raised per request for long edit-in-place selections (prompt_design.md budget policy)
```

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

### `settings.toml` — general
```toml
schema_version = 1

load_on_login = true
default_mode_id = "plain-dictation"

[stt]
engine = "parakeet-tdt-ctc-110m"  # the single active engine (default: the compact 110M tier)
eviction = "frugal"             # "fastest" | "balanced" | "frugal" (default: frugal)
# eviction_idle_seconds = 1800  # used when eviction = "balanced" (default: 1800 = 30 min)

[during_dictation]
mute_system_audio = true        # mute lands after the start sound (else it is swallowed); instant when sounds = false
keep_display_awake = true
sounds = true                   # start/end sounds

[history]
enabled = true
retention_days = 7              # default; delete day-files older than this (or retention_entries)

[shortcuts]                                 # global shortcuts for menu-bar actions
add_dictionary_entry = "control+option+shift+d"  # canonical chord; "" = off
add_replacement = "control+option+shift+r"       # canonical chord; "" = off
paste_last_dictation = ""                        # canonical chord; "" = off (default)
```

> **`[shortcuts]`** drive the standalone **Add Dictionary Entry…** / **Add Replacement…** panel and
> the **Paste Last Dictation** action (all also always available in the menu bar). Add Dictionary /
> Add Replacement **default on** to `⌃⌥⇧D` / `⌃⌥⇧R` — the
> triple-modifier zone the system never reserves, so the global grab is least likely to collide with
> an app; **Paste Last Dictation defaults off** (`""`). An **absent** key falls back to that field's
> default; an explicit `""` means the user turned it
> off. Only **chord** descriptors are honored (a
> bare modifier key already drives dictation). The event tap is **active** (`.defaultTap`), so a
> registered chord — for these shortcuts and for mode triggers — is **swallowed** before the focused
> app sees it (otherwise e.g. ⌃⌥E reaches the app as the Option-E dead key and replaces the selection).
> The tap falls back to listen-only when an active tap can't be created (Accessibility not yet granted),
> in which case the chord passes through until Accessibility is granted. Set in Settings ▸ General.

> **Note:** `load_on_login` defaults to **false** in code (KeyScribe does not install a login item
> unless the user opts in via General settings / first-run), even though the example above shows `true`.

---

## Conventions
- **Unknown keys** in a user-edited file are preserved on rewrite where possible, but a file
  whose `schema_version` exceeds the app's is left untouched and surfaced (`design.md` §5.1).
- **Secrets never in TOML** — LLM keys live in Keychain; TOML stores only `key_ref`.
- **kebab-case ids**, snake_case fields, consistently.

## Notes & conventions
- **Verbatim is a live edit** — gated by `commands.live_edits` (no separate toggle); triggered
  by "begin verbatim" / "end verbatim".
- **`include_global` is per-set** — dictionary and replacements each carry their own flag.
- **Key descriptor format** — lowercase tokens joined by `+`: modifiers (`control` `option`
  `command` `shift`) plus a key, or a named single key (`fn`/`globe`, `right_option`,
  `right_command`, `hyper`, `f5`). Examples: `"fn"`, `"right_option"`, `"control+option+a"`.
  **Recommended default for new modes: `fn`/Globe with `hold-or-tap`** (most familiar — Wispr
  and Apple both center on it), with **`right_option`** offered as the conflict-free
  alternative (Apple Dictation also double-taps Fn).
- **Per-mode language** — out of scope (language follows the active engine, `design.md` §4.1);
  no `language` field.
