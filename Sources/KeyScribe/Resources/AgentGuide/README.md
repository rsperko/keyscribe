<!-- Managed by {{app_name}} {{version}}. Rewritten on every launch; edits here are lost. -->

# {{app_name}} configuration

This folder holds your {{app_name}} modes, AI services, vocabulary, and settings. You can change them in
{{app_name}}'s Settings or by editing the files here; the app picks up saved edits without a restart.

## Using a coding agent

Open a coding agent (Claude Code, Codex, or similar) in this folder and describe the mode you want, for
example: "Add a mode that turns my dictation into a git commit message when I say 'commit message'." The
agent finds its instructions in `AGENTS.md`.

**Privacy:** this folder also holds your dictation history. `AGENTS.md` tells agents not to open it, but an
agent can still read any file here, and whatever it reads goes to that agent's AI provider. Only open an
agent here if you are comfortable with that.

## Files {{app_name}} keeps up to date

{{app_name}} rewrites these on every launch to match the installed version. Do not edit them; your changes
would be lost. If one of these names already held a file you wrote, it is kept next to the new one with
`.bak-` and the date added to its name.

- `README.md` (this file)
- `AGENTS.md`: instructions for coding agents
- `CLAUDE.md`: points Claude Code at `AGENTS.md`
- `reference/`: the full configuration format reference

## Adding your own agent instructions

Put your own instructions in these files. {{app_name}} never creates, reads, or changes them, and resetting
the configuration keeps them. Only **Erase All {{app_name}} Data**, or a full reset, deletes them along with everything else:

- `AGENTS.override.md`: read by agents that follow the `AGENTS.md` convention. `AGENTS.md` tells them to
  read it too.
- `CLAUDE.local.md`: read by Claude Code. To share one set of notes, make it contain the single line
  `@AGENTS.override.md`.

**Codex users:** when `AGENTS.override.md` exists, Codex reads it *instead of* `AGENTS.md`. Start your
override with this line so the agent still gets the app's guide:

```
Read AGENTS.md in this folder first. The instructions below add to it and take precedence.
```
