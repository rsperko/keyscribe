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

## Target a guest VM clipboard

If a target uses `Control-C` and `Control-V` instead of Mac command shortcuts, set:

```toml
clipboard_modifier = "control"
```

This is best-effort because host clipboard sync timing is outside KeyScribe's control.

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
