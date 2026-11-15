<!-- Managed by {{app_name}} {{version}}. Rewritten on every launch; edits here are lost. Put your own instructions in AGENTS.override.md. -->

# {{app_name}} configuration: guide for agents

This folder holds the configuration of {{app_name}}, an on-device voice dictation app for macOS. You are
probably here to create, edit, or improve a **mode**: a named set of settings that decides how a dictation
is triggered, cleaned up, optionally rewritten by an AI service, and inserted.

If `AGENTS.override.md` exists in this folder, read it now. The user wrote it, and its instructions take
precedence over this file.

## Where things live

| Path | What it is |
|---|---|
| `modes/<id>.toml` | One mode per file. The file name without `.toml` is the mode's id. |
| `connections.toml` | AI services the user has set up. A mode refers to one by its `id`. |
| `fragments/<id>.md` | Shared prompt text a mode's AI rewrite can include. |
| `dictionary.toml`, `replacements.toml` | Words and replacements used by every mode. |
| `vocabularies/<id>.toml` | Word and replacement sets that several modes share. |
| `voice_commands.toml` | Saved places and scripts for the experimental Voice Commands mode. |
| `settings.toml` | App settings. Leave it alone unless the user asks. |
| `reference/config_schema.md` | The full format reference for every file above. |

## Private data: do not open

Work only with the files in the table above. The rest of this folder holds the user's private data and app
state: `history/` (everything the user has dictated, and kept audio), `usage/`, `agents/` (including an access
token), `lkg/`, `models/`, `spoken-voice/`, and backup files and folders (names containing `.bak`). **Do not
read, list, search, or summarize them**, and keep them out of any search you run here: whatever you read is sent
to your AI provider. If a task seems to need them, ask the user first.

The reference is long. For mode work, read its sections **Mode file — annotated example**, **Mode field
reference**, and **Settings UI vs advanced TOML**, then look up anything else you need. Sections that talk
about `starterModes()`, `seed_version` discipline, or source files are for the app's developers, not for you.

## How to work

1. **Read before writing.** Look at the existing modes in `modes/` to learn the user's setup: which keys and
   trigger phrases are taken, which connection ids exist in `connections.toml`, and the style of their prompts.
2. **A new mode is a new file** with a new kebab-case id, such as `modes/commit-message.toml`. Ids starting
   with `_` are reserved for the app's built-in modes.
3. **To build on a starter mode, copy it** to a new file and delete the `seed_id` and `seed_version` lines
   from the copy. Editing a starter in place works, but that mode then stops receiving improvements in app
   updates. Say so to the user before you do it.
4. **Check your work** after every change:

   ```sh
   "{{executable}}" --check-config --config-dir "{{support_dir}}"
   ```

   It reads this folder the same way the app does and lists every file it cannot load, every key nothing
   reads (usually a typo), every trigger phrase or pattern that can never match, every enabled mode wired to
   a missing connection, and every shortcut another mode already uses. It exits non-zero when
   anything is wrong. Fix what it reports and run it again until it prints `OK`.
5. **No restart needed.** The running app notices saved changes and reloads them.

## Rules that are easy to break

- **Put every top-level key before the first `[table]` or `[[table]]` header.** A key written after a header
  silently becomes part of that table.
- **Never put an API key, token, or password in any file here.** Saved keys live in the macOS Keychain. If
  the mode needs an AI service that `connections.toml` does not have, ask the user to add it in
  {{app_name}}'s Settings, then use its id.
- **A mode with `commands.privacy = true` must send no context:** keep every `ai_rewrite.context` value
  `false`. Privacy redaction is best effort; do not describe it to the user as making anything secure.
- **Trigger phrases are matched at the end of what was said**, already case-insensitive and on word
  boundaries. Do not add `(?i)`, `\b`, or a trailing `$`.
- **Do not give two modes the same trigger key** where they can both be active. Check the other modes'
  `[[trigger_keys]]` first, and confirm any new shortcut with the user.
- **`submit` presses a key after inserting**, which can send a half-finished message. Set it only when the
  user asks for it.
- **Scope a mode to an app or site with `[[constraints]]`**, never by naming the app in the prompt.
- A mode's AI rewrite prompt describes the transformation, for example "Format this as a git commit message".
  The app adds its own instructions for dictation and protected text around it, so do not repeat them.

## When you are done

Tell the user which files you created or changed, how to trigger the new behavior, and anything they must do
in Settings, such as adding an AI service or granting a permission.
