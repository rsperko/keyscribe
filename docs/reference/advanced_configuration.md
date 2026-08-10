# Advanced Configuration

Most people should start in Settings. This page is for file-level options that are useful once you
already know the workflow you want.

KeyScribe stores editable files under `~/Library/Application Support/KeyScribe/`. For every
supported field, see the [configuration schema](config_schema.md).

## Spoken suffix routing

A spoken suffix is a phrase you say at the end of a dictation to choose a mode.

```toml
trigger_phrases = ['as an email']
```

Each phrase can also be a regex:

```toml
trigger_phrases = ['as (a |an )?(draft|note)']
```

Matching is case-insensitive, end-anchored, and tolerant of trailing punctuation from speech
recognition.

## Auto-submit after insertion

Use this only for deliberate automation modes. The submit key fires after a verified insert and does
not fire when KeyScribe copies to the clipboard instead.

```toml
submit = "cmd_return"
```

Other values: `return`, `shift_return`, `none`.

## Remove trailing punctuation for commands

For command-like modes, strip a final period before adding any trailing space or line break.

```toml
trim_trailing_punctuation = true
```

## Target a guest VM or remote desktop

Two kinds of foreign target take dictation, and they need different treatment.

### A hypervisor window wants typing, not paste

A VM running locally (VMware Fusion, Parallels) translates each host key event into a guest
keystroke, and its clipboard sharing syncs on its own schedule — typically on a window-focus
change, which never happens mid-dictation. KeyScribe cannot wait for a sync it can't observe, so
no `paste_settle_ms` makes paste reliable there: it fires before the guest has the new text and
lands empty or one dictation behind. Use typing:

```toml
insertion = "type"
```

Dictation then goes out as real keystrokes mapped through your keyboard layout. The limits are
inherent to keystrokes: characters your layout cannot produce (emoji, composed accents) do not
reach the guest, and a dictated newline presses a real Return.

### A remote session can paste

A remote-desktop client (RDP, Citrix, VNC, Screen Sharing) syncs its clipboard channel eagerly, so
paste works and is much faster than typing. If the client translates `Command-V` for the remote
side, keep the native chord and ask only for the clipboard treatment:

```toml
clipboard_sync = true
paste_settle_ms = 300
```

If the client forwards raw keystrokes instead, name the chord the remote target wants — the
grammar is the same one trigger keys use:

```toml
paste_key = "control+v"          # a remote GUI app
copy_key = "control+c"
```

```toml
paste_key = "control+shift+v"    # a terminal in that session
copy_key = "control+shift+c"
```

A chord without `command` is assumed to be aimed at a foreign target, so KeyScribe also leaves the
dictated text on the clipboard for the session's clipboard channel to pick up, and does not restore
what was there before.

Clipboard sync timing belongs to the client, not to KeyScribe. If paste lands empty or stale, raise
`paste_settle_ms`; if no value makes it reliable, the target syncs on events rather than on time —
switch to `insertion = "type"`.

## Use an extra mouse button as a trigger

Mouse button descriptors are TOML key descriptors:

```toml
[[trigger_keys]]
key = "mouse4"
press_style = "hold-only"
```

Bound mouse buttons are consumed globally while KeyScribe runs, so they will not also perform their
normal Back or Forward action.

## Whole-utterance replacements as commands

A replacement that consumes the entire dictation inserts exactly, skipping AI rewrite and trailing
text. This makes spoken commands deterministic:

```toml
[[rules]]
heard = "slash (\\w+)"
replace = "/$1"
regex = true
```

Say `slash resume` and the output is `/resume`.

## Mode-local vocabulary

Mode-local dictionary and replacements apply only in that mode, on top of the global sets:

```toml
[dictionary]
include_global = true
words = ["KeyScribe", "Parakeet"]

[replacements]
include_global = true
[[replacements.rules]]
heard = "at example dot com"
replace = "@example.com"
regex = false
```
