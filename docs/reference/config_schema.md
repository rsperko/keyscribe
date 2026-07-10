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
  fragments/               # shared prompt fragments (one file per fragment)
    my-voice.md            #   markdown body + YAML frontmatter
  modes/                   # one file per mode; filename stem = mode id
    _direct.toml             # the Direct system floor (reserved `_` id)
    email.toml
    pig-latin.toml
  history/                 # append-only local history, one JSONL file per day
    2026-06-20.jsonl
  lkg/                     # last-known-good mode copies + seed-ledger.toml (design.md §5.1)
  models/                  # downloaded STT weights, one dir per model (design.md §4.1)
    parakeet-tdt-0.6b-v3/
```

- **Mode id = filename stem** (kebab-case). The id is stable; `name` is the display label and
  can change freely.
- **System modes use a reserved `_`-prefixed id** (`_direct.toml` = the Direct floor, shown to users
  as "Plain Dictation", `design.md` §4.3). The kebab-case slugger never emits a leading underscore, so user modes can't collide. The
  file is auto-seeded and re-normalized on load: only its editable fields (trigger keys, insertion,
  trailing, submit, clipboard modifier, live-edits, **and exclude-from-history**) are honored; the
  locked guarantees (no AI rewrite, dictation/cursor only, global vocabulary) are enforced regardless
  of edits. Direct owns Fn by default and records to history per the global setting unless turned off.
- Config files are human-editable text. **Model weights** are downloaded at runtime (never
  committed) into `models/`, consolidated under the KeyScribe support dir.

### Model storage

All KeyScribe data — including STT weights — lives under the one support dir. KeyScribe **points each
engine SDK at `models/<model-id>/`** where the SDK exposes a configurable download directory; where
it does not, KeyScribe manages the SDK's own location through that SDK's API and the result is the
same single disk-usage / delete story for Speech Models settings. **Apple SpeechAnalyzer is
system-managed** when available and has no entry here.

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

# Trigger phrases (Phase B). One or more spoken phrases matched at the END of the transcript
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
clipboard_modifier = "command"  # "command" (default) | "control" — modifier for the synthesized ⌘C capture + ⌘V paste; "control" targets a guest VM
trim_trailing_punctuation = false  # strip a final . ! ? (and trailing whitespace) from the result, BEFORE `trailing` is appended
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
| `schema_version` | int | Required. Older versions are normalized on read. |
| `name` | string | Display label. |
| `enabled` | bool | Disabled modes are ignored by the resolver. |
| `trigger_keys[]` | table[] | `key` (canonical descriptor) + `press_style` + `tap_threshold_ms` (default 250). Zero or more. There is no separate global hotkey — whichever mode owns Fn (the Direct floor by default) is "the global hotkey". |
| `trigger_phrases` | string[] | Spoken phrases matched at the transcript end post-STT — case-insensitive, word-boundary-honored, trailing punctuation/space tolerated. Each is a regex, so power users can write one (`(?-i)` opts back into case-sensitivity). Zero or more. |
| `constraints[]` | table[] | Any of `bundle_id`, `bundle_prefix`, `url_pattern`, `window_title` (ANDed). Empty ⇒ eligible everywhere. |
| `source` | enum | `dictation` \| `selection`. |
| `output` | enum | `cursor` \| `replace_selection`. |
| `commands.live_edits` | bool | Opt-in to the spoken-command list (insert new line, insert new paragraph, insert tab character, scratch that, **insert clipboard contents**, **begin/end verbatim**). |
| `commands.privacy` | bool | Opt-in to best-effort redaction. When true, **context is forced off** — `ai_rewrite.context` is locked to all-false so only the redacted transcript leaves. |
| `commands.numbers` | bool | Opt-in to inverse text normalization ("twenty five" → "25"); bails on ambiguous/year-like runs. |
| `dictionary` | table | `include_global` + `words[]`. |
| `replacements` | table | `include_global` + `rules[]` of `{heard, replace, regex}`. |
| `[ai_rewrite]` | table | Absent ⇒ no rewrite. `connection`, `prompt`, `fragments[]`, `context`. |
| `ai_rewrite.context` | inline table | `{ app, preceding_text }` booleans. `preceding_text` sends bounded text before the caret (native-only, best-effort via AX). (URL is a routing key only — `constraints[].url_pattern` — never sent to the LLM.) |
| `insertion` | enum | `paste` \| `insert` \| `type`. |
| `trailing` | enum | `none` \| `space` \| `newline`. Literal text appended to the transcript, inside the atomic insert (one ⌘Z still undoes it all). New modes created in Settings default to `space`; omitted TOML decodes as `none` for compatibility with existing config files. |
| `submit` | enum | `none` (default) \| `return` \| `shift_return` \| `cmd_return`. A keystroke synthesized after a **verified** insert (outside the undo atom). Never fires on a clipboard fallback — the text never reached the target. |
| `trim_trailing_punctuation` | bool | `false` (default). Strip a final `.` `!` `?` (and trailing whitespace) from the result, applied to the restored final string **before** `trailing` appends its suffix. Deterministic enforcement for command/identifier/subject-line modes (e.g. seeded **Shell** ships `true`) that should not end in sentence punctuation — the rewrite prompt can request this but cannot guarantee it. Closing quotes/parens/backticks/fences are left untouched. |
| `clipboard_modifier` | enum | `command` (default) \| `control`. The modifier used for the synthesized clipboard keystrokes — ⌘C to capture a selection and ⌘V to paste an insert. `control` targets a guest where ⌃C/⌃V are the paste mechanism (e.g. a Linux/Windows VM with host-clipboard sharing on). Governs both keystrokes, never `submit`. TOML-only; no Settings UI. Selection capture in a guest is **best-effort** — the host-pasteboard bump it waits on is driven by the guest's clipboard-sync, not the OS, so its timing is not guaranteed. |
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
| `trigger_keys[].press_style` / `tap_threshold_ms` | The mode shortcut itself is editable in Settings. Press style and tap threshold stay with advanced routing details. | Most users need only “which key starts this mode”; hold/tap behavior is a routing detail. |

---

## Seeded starter modes

A fresh install ships eight starter modes — all disabled, AI-backed examples. They are ordinary mode
files — nothing about them is special-cased in source — and the user can edit or delete any of them.
Plain local dictation on Fn is provided by the **Direct** system mode (`_direct`, see "System modes"),
not a starter. This set is the canonical one the menu and onboarding refer to (`ui_design.md` §6 menu
bar).

| id | name | Shape | Rewrite |
|---|---|---|---|
| `polish` | Polish | `source = dictation`, `output = cursor`, trigger `right_option` | light cleanup (fillers, grammar, punctuation) that keeps wording and tone. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌥**. |
| `message` | Message | `source = dictation`, `output = cursor` | **disabled by default.** casual chat-style message; no greeting/sign-off. A discoverable example enabled in Settings. |
| `email` | Email | `source = dictation`, `output = cursor`, phrase `as an email` | **disabled by default.** polished professional email with greeting + closing; never invents names/facts. A discoverable example enabled in Settings; once enabled, route to it by ending a dictation with **"as an email"**. |
| `edit-selection` | Edit Selection | `source = selection`, `output = replace_selection`, trigger `right_command` | transforms the selection from a spoken instruction. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌘**. |
| `ai-prompt` | AI Prompt | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation into a clear instruction for an AI assistant, preserving technical terms; never answers it. Intended as a smart-model example. |
| `code` | Code | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation for IDEs, code review, issues, commits, and coding assistants while preserving technical identifiers. |
| `markdown` | Markdown | `source = dictation`, `output = cursor` | **disabled by default.** Reformats dictation into raw Markdown (headings, bullet/numbered lists, bold, blockquotes, inline/fenced code) without wrapping the output in a code fence. |
| `shell` | Shell | `source = dictation`, `output = cursor` | **disabled by default.** Turns a spoken command or description into a single terminal-ready shell command, mapping spoken symbols ("dash dash", "pipe", "tilde slash") to shell syntax; emits only the command, never runs or explains it. |

`message`, `email`, `ai-prompt`, `code`, `markdown`, and `shell` ship **disabled** (`enabled = false`)
as discoverable examples — the resolver ignores disabled modes, so the user enables one only after
editing it to taste and attaching a connection. `polish` and `edit-selection` ship disabled too but
already carry a default reach (Right-⌥ and Right-⌘ respectively), so the first AI connection makes
them usable without any further setup. `email` keeps a default reach as well (the "as an email"
phrase) but is not auto-connected — enable it in Settings when you want it.

The **Direct** system mode (`_direct`, shown to users as **"Plain Dictation"**) works with zero
configuration (it's the Fn default; all starters ship disabled). When the first AI service is added, onboarding connects and enables `polish`
and `edit-selection`; the remaining modes stay as disabled examples for deliberate setup. The
default English engine plus **Direct** is the minimum first-run target (`ui_design.md` §2 first run).
Mode prompts instruct, never answer, keep redaction tokens intact, and avoid bracketed signature
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
id = "gemini-flash"             # referenced by modes
name = "Gemini 2.5 Flash"
provider = "gemini"             # "openai" | "anthropic" | "gemini" | "openai_compatible"
model = "gemini-2.5-flash"
key_ref = "keyscribe.llm.gemini-flash"   # Keychain item id — the key itself never lives in TOML
# auth_method = "api_key"       # "api_key" | "token_command" | "none"; defaults to "api_key"
# base_url = "https://..."      # required for openai_compatible endpoints
# token_command = "..."         # required when auth_method = "token_command"
[connection.params]
temperature = 0.2
max_tokens = 2048   # floor; raised per request for long edit-in-place selections (prompt_design.md budget policy)
```

`auth_method` controls how requests are authenticated:

| `auth_method` | Meaning |
| --- | --- |
| `api_key` | Read the secret from Keychain using `key_ref`. Hosted providers require this. OpenAI-compatible endpoints may use it when a proxy expects a bearer token. |
| `token_command` | Run `token_command` before requests and send its output as `Authorization: Bearer …`. The generated token is kept in memory only and never written to disk. |
| `none` | Send no Authorization header. Valid for local/no-auth OpenAI-compatible endpoints. |

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

### Replacement matching & output

How a rule behaves once it matches:

- **Literal rules match case-insensitively, on whole words** (`pipe` never fires inside `pipeline`);
  the replacement text is inserted verbatim (`$` / `\` are not template refs).
- **Regex rules also match case-insensitively by default.** The input is STT output, whose casing
  the engine chooses (it commonly capitalizes the first word), so a case-sensitive pattern would
  silently miss. Opt back into case sensitivity with an inline `(?-i)`. Capture substitution (`$1`,
  `\$` for a literal `$`) works as usual. Note the capture preserves the *matched* text's case — the
  replacement template has no case-folding, so `slash (\w+)` → `/$1` on a spoken "Dog" yields `/Dog`,
  not `/dog`.
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
  correction or a chain of rules whose outputs combine — only an explicit replacement that consumed
  the entire utterance.

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
    is inserted verbatim; a `<CR>` anywhere but the end of a regex template is invalid and the rule is
    ignored. Write `\<CR>` to emit the literal text `<CR>` in a regex replacement.
  - The Return is a real key press, **not** a guaranteed "send" — its effect depends on the focused
    target. It fires only after the text verifiably lands (never on a clipboard fallback, a password
    field, or if focus moved), and `replace = '<CR>'` alone presses nothing (empty output → no-speech).

### `settings.toml` — general
```toml
schema_version = 1

load_on_login = false

[stt]
engine = "parakeet"             # the single active engine (default: Parakeet TDT v3)
eviction = "fastest"            # "fastest" | "balanced" | "frugal" (default: fastest)
# Governs both STT-model residency AND idle microphone warm-up (the input unit is kept prewarmed for
# instant starts). Fastest = model loaded + mic held warm (periodic binding refresh); Balanced = both
# released after eviction_idle_seconds idle; Frugal = mic opened only while dictating, model freed each
# dictation.
# eviction_idle_seconds = 1800  # used when eviction = "balanced" (default: 1800 = 30 min)
# The one dictionary-mechanism control: recognition bias is default-ON for the engines that support it
# (both Qwen3, both Whisper) and can be disabled per engine. Post-STT dictionary recovery has no toggle
# — it runs whenever the mode's dictionary is non-empty. Only deviations are recorded (fresh install
# writes the list empty):
# recognition_bias_disabled_engines = []  # bias-capable engines with recognition bias turned OFF
# (The former dictionary_recovery_enabled_engines / dictionary_recovery_disabled_engines /
#  dictionary_recovery_engines keys are obsolete: ignored on read and dropped on the next write.)

[during_dictation]
mute_system_audio = true        # ducks other audio (FaceTime-style, cannot strand); lands after the start sound, instant when sounds = false
keep_display_awake = true
sounds = true                   # start/end sounds

[history]
enabled = true
retention_days = 7              # default; delete day-files older than this

[shortcuts]                                 # global shortcuts for menu-bar actions
add_vocabulary = "control+option+shift+v"        # canonical chord; "" = off
paste_last_dictation = ""                        # canonical chord; "" = off (default)
```

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
- **Rewrites normalize to this schema** and drop unknown keys and comments. A file whose
  `schema_version` exceeds the app's is left untouched and surfaced (`design.md` §5.1).
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
- **Key descriptor format** — lowercase tokens joined by `+`: modifiers (`control` `option`
  `command` `shift`) plus a key, or a named single key (`fn`/`globe`, `right_option`,
  `right_command`, `hyper`, `f5`), or a non-primary mouse button `mouseN` where `N` is the
  macOS button number ≥ 2 (`mouse2` = middle, `mouse3`/`mouse4` = the back/forward thumb
  buttons; left = 0 and right = 1 are rejected so a trigger can never hijack a normal click).
  Examples: `"fn"`, `"right_option"`, `"control+option+a"`, `"mouse4"`. A bound mouse button is
  **consumed globally** while KeyScribe runs — it no longer performs its normal action (e.g.
  browser back) — which is the same trade other dictation apps (Wispr, Superwhisper) make.
  Mouse buttons are observed under Accessibility alone (no Input Monitoring), like the modifier
  triggers. **Recommended default for new modes: `fn`/Globe with `hold-or-tap`** (most familiar —
  Wispr and Apple both center on it), with **`right_option`** offered as the conflict-free
  alternative (Apple Dictation also double-taps Fn).
- **Per-mode language** — out of scope (language follows the active engine, `design.md` §4.1);
  no `language` field.
