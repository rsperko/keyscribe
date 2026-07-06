# Getting Started with KeyScribe

This guide is a ramp. Start at the top, stop when KeyScribe already fits your workflow, and come
back later for the deeper pieces. The first useful milestone is simple: hold a key, speak, release,
and undo the inserted text with one `Cmd-Z`.

Plain Dictation stays on your Mac and does not need an AI service. The later steps add spoken edits,
vocabulary, optional BYOK rewrite, mode routing, context controls, history, and file-level setup.

## Fast path

If you just installed KeyScribe, do this first:

1. Launch KeyScribe and complete first run.
2. Download the recommended on-device speech model.
3. Grant Microphone and Accessibility.
4. Open a text field.
5. Hold `Fn (Globe)`, say one sentence, and release.

When that works, use KeyScribe normally for a day before changing much. Add vocabulary only after
you see real misses, and add rewrite modes only when plain dictation is not enough.

## The ramp

| Stage | Learn this | Stop here when |
|---|---|---|
| 1. First dictation | Hold a key, speak, release, undo once. | Plain Dictation works in your usual apps. |
| 2. Reliability | Pick a trigger, recover from focus changes, paste the last result. | Dictation feels safe enough to use all day. |
| 3. Vocabulary | Fix names, jargon, and repeated mishearings. | KeyScribe spells the words you care about. |
| 4. Live edits | Say line breaks, tabs, scratch-that, clipboard paste, and verbatim spans. | You can dictate structured text without stopping. |
| 5. Speech models | Choose the local model that fits your voice and Mac. | Accuracy and latency feel right. |
| 6. Rewrite | Add your own provider key for optional cleanup. | You want polished messages, email, Markdown, or selected-text edits. |
| 7. Modes | Route dictation by key, app, URL, window title, or spoken suffix. | One trigger does the right thing in different places. |
| 8. Privacy and history | See exactly what happened and control what is stored or sent. | You understand the local/cloud boundary. |
| 9. Advanced setup | Combine modes, routing, privacy controls, and reusable instructions. | KeyScribe fits the way you write in different apps. |

## 1. Make the first dictation boring

Start with the smallest successful loop.

1. Launch KeyScribe and look for the waveform glyph in the menu bar.
2. Complete first run: download a speech model, then grant Microphone and Accessibility.
3. Open a normal text field in Notes, TextEdit, a browser, or a chat app.
4. Hold `Fn (Globe)`, say one sentence, and release.
5. Press `Cmd-Z`.

Success looks like this: the whole sentence appears where the cursor was, and one undo removes the
whole dictation.

If the Globe key opens Emoji, Apple Dictation, or the input-source switcher, change the system Globe
action to "Do Nothing" in System Settings > Keyboard. The simpler alternative is to use KeyScribe >
Settings > Modes > Plain Dictation and change the trigger to `Right Option`.

Plain Dictation is the built-in floor. It runs on-device, uses no AI service, and catches dictations
that no other enabled mode claims.

## 2. Make it reliable before making it fancy

KeyScribe is designed around finished inserts, not streaming partial text. That gives you three
important safety properties:

- The final text inserts as one unit, so one `Cmd-Z` removes it.
- If focus changes during dictation, KeyScribe copies the result instead of pasting into the wrong
  app.
- The menu-bar command `Paste Last Dictation` can reinsert the most recent result.

Recommended setup:

1. Open KeyScribe > Settings > Modes > Plain Dictation.
2. Choose the trigger you can use without thinking: `Fn (Globe)`, `Right Option`, `Right Command`, a
   custom shortcut, or an extra mouse button.
3. Choose how the shortcut works: hold-or-tap, hold only, or tap to toggle.
4. Open KeyScribe > Settings > General and optionally assign a shortcut for `Paste Last Dictation`.

Checkpoint: dictate into three apps you use every day. If one app behaves strangely, keep using
paste-based insertion first. It is the default because it is the most predictable path across Mac
apps.

## 3. Teach vocabulary only after you see real misses

Do not build a huge dictionary on day one. Dictate for a bit, then fix repeated misses.

Use **Dictionary** for words KeyScribe should recognize as written:

- Names.
- Product terms.
- Acronyms.
- Domain jargon.

Use **Replacements** when KeyScribe consistently hears one phrase and you always want another:

- `K Scribe` -> `KeyScribe`.
- `at example dot com` -> `@example.com`.
- `slash resume` -> `/resume`.

Where to add them:

1. Settings > Vocabulary for deliberate cleanup.
2. Menu bar > Add to Vocabulary for an in-the-moment correction.
3. Settings > General to assign an `Add to Vocabulary` shortcut.
4. History > select the misheard words > Create Replacement or Add to Dictionary.

Dictionary strength varies by speech model. Most engines support recognition bias directly.
Moonshine does not, so KeyScribe can apply dictionary recovery after transcription to fix close
matches.

Checkpoint: after adding a term, dictate the same phrase in a new sentence. If the engine still gets
it wrong the same way, use a replacement instead of adding more dictionary entries.

## 4. Use spoken edits while dictating

Modes can turn spoken commands into local text edits before insertion.

Useful phrases:

- `insert new line`
- `insert new paragraph`
- `insert tab character`
- `insert clipboard contents`
- `scratch that`
- `begin verbatim ... end verbatim`

The insert commands use a deliberate carrier phrase so a stray "new line" spoken in prose stays as
text. Speaking is forgiving: `insert new line` and `insert a new line` both work, and a short pause
mid-command (which your Mac may hear as `insert, new line`) still triggers it.

Example:

Say:

```text
first item insert new line second item scratch that revised second item insert new paragraph final note
```

With live edits on, KeyScribe inserts line breaks and removes the scratched segment.

Use verbatim spans when the words sound like commands but should stay literal:

```text
begin verbatim insert new line scratch that end verbatim
```

That inserts the words `insert new line scratch that` instead of treating them as edits.

Say `insert clipboard contents` to drop whatever is on your clipboard into the dictation at that
point. Two guarantees:

- **It never goes to the AI.** Even in a mode with an AI rewrite on, the pasted text is not sent to
  the cloud and is not rewritten — the model only ever sees a placeholder token (the same protection
  a verbatim span gets). Your clipboard can hold passwords, tokens, or private URLs; those stay on
  your machine.
- **It is inserted exactly as you copied it** — character for character, no cleanup. Rich text pastes
  as plain text (dictation inserts plain text, so formatting is dropped, but the words are exact).

If the clipboard has no text — for example you copied an image or files — nothing is pasted and the
words "insert clipboard contents" are left in place so you can see it and fix it.

To control this per mode, open Settings > Modes, choose a mode, and toggle **Turn spoken commands into
edits**.

## 5. Pick the local speech model that fits your use

All speech recognition in KeyScribe is on-device. The model choice is about speed, accuracy, memory,
disk use, language support, and dictionary behavior.

Start with the default compact English model. Then open Settings > Speech Models if you need a
different tradeoff:

- Use a larger model when accuracy matters more than latency or memory.
- Use a smaller model when you want the fastest everyday loop.
- Use a multilingual model when you dictate in more than English.
- Use Apple Speech only on macOS 26 or later.
- Use the model self-test and the reference benchmark guide before assuming a model is better for
  your voice.

The reference numbers and the local benchmark workflow are in
[Speech Model Benchmarks](reference/stt_benchmarks.md).

Checkpoint: choose one model for a full day before switching again. Short A/B tests can overvalue a
single lucky or unlucky sentence.

## 6. Add optional rewrite only when you want finished text

Plain dictation does not need an AI service. Add one only when you want KeyScribe to rewrite the local
transcript before insertion.

What rewrite is good for:

- Removing filler words.
- Fixing grammar and punctuation.
- Turning a rough thought into a chat message, email, Markdown note, shell command, or prompt.
- Rewriting selected text in place.

What it is not:

- Cloud speech recognition. Audio still stays local.
- A KeyScribe-hosted service. Requests go to the provider or endpoint you configure.
- Required for everyday dictation.

Set it up:

1. Open Settings > AI Services.
2. Add a service.
3. Choose OpenAI, Anthropic, Gemini, or an OpenAI-compatible endpoint.
4. Save the key in Keychain, use no auth for a local endpoint, or use a token command for a
   short-lived bearer token.
5. Test the connection.

During first run, connecting an AI service enables the starter rewrite modes: Polish and Edit
Selection. Email, Message, Markdown, Shell, and AI Prompt stay available as examples you can enable
when you want them. If you add a service later, open Settings > Modes and enable the modes you
actually want.

Checkpoint: try **Polish** first. It is the smallest rewrite: same meaning, cleaner text.

## 7. Use starter modes as examples, not commandments

Modes are normal editable files. A mode decides:

- When it can run.
- Whether it dictates at the cursor or rewrites the current selection.
- Whether it runs live edits, numbers-as-digits, dictionary, or replacements.
- Whether it sends the transcript to an AI service.
- What context, if any, is sent with the AI request.
- How the final text is inserted.

Good first modes:

| Mode | Use it for | Needs AI service |
|---|---|---|
| Plain Dictation | Local transcript at the cursor. | No |
| Polish | Clean up rough speech without changing the meaning. | Yes |
| Message | Short chat-style messages. | Yes |
| Email | A polished email shape from rough speech. | Yes |
| Edit Selection | Select text, speak the change, replace the selection. | Yes |
| Markdown | Notes with headings, bullets, and code fences. | Yes |
| Shell | A terminal-ready command from spoken intent. | Yes |
| AI Prompt | A clean instruction for another AI tool. | Yes |

For technical modes like Shell, keep them disabled until you have read the prompt and result handling.
KeyScribe inserts text; it does not run shell commands for you.

Checkpoint: duplicate a starter mode instead of editing the original if you want to experiment.

## 8. Rewrite selected text in place

Edit Selection is the fastest way to feel the difference between dictation and voice editing.

1. Add and test an AI service.
2. Open Settings > Modes and enable Edit Selection.
3. Select a paragraph in any editable app.
4. Trigger Edit Selection.
5. Say an instruction such as:

```text
make this shorter and warmer
```

The selected text is captured, rewritten, and replaced in place. Selection capture uses the same
clipboard path as normal Mac copy/paste, so there must be selected text for this mode to act on.

Good instructions:

- `make this shorter`
- `turn this into bullets`
- `make this more direct`
- `translate this to Spanish`
- `keep the meaning but make it friendlier`

Checkpoint: use Edit Selection on text you can undo. It should feel like a local edit command, not a
new document workflow.

## 9. Route modes by where you are or what you say

This is where KeyScribe becomes more than a global dictation key.

### One-shot mode from the menu

Use the menu bar > Dictate with submenu when you want the next dictation to use a specific enabled
mode without changing your normal trigger setup.

### Same key, different app

Example: use `Fn` for Message in your chat app, but Plain Dictation everywhere else.

1. Open Settings > Modes > Message.
2. Enable it.
3. Set `Start this mode with` to the same key as Plain Dictation, such as `Fn (Globe)`.
4. Open Advanced routing.
5. Add an app rule for the chat app.

When both modes could apply, the more specific mode wins. In the chat app, Message runs. Elsewhere,
Plain Dictation remains the fallback.

### URL and window-title routing

URL and window-title rules are regular expressions. They are local routing keys. The browser URL is
not sent to a rewrite provider just because a mode uses URL routing.

Use URL routing for web apps where the bundle ID is too broad. Use window-title routing for desktop
apps where the document or task is visible in the title.

### Spoken suffix routing

Add a trailing phrase when the same spoken content should route differently depending on how you end
it.

Example:

1. Enable Email.
2. Add a spoken phrase such as `as an email`.
3. Dictate:

```text
quick reminder that the draft is ready for review and I can make changes today as an email
```

KeyScribe strips the suffix, routes the dictation through Email, and inserts the email-shaped result.

Checkpoint: keep routing rules obvious. If two modes are hard to reason about, make one of them a
menu-only mode until the workflow is clearer.

## 10. Decide what can be sent with AI

Every rewrite mode has a data boundary. Check Settings > Modes > the mode > Data sent with AI.

Possible inputs:

- The transformed transcript.
- Selected text, when the mode rewrites a selection.
- App details, if you enable them.
- A bounded excerpt before the cursor, if you enable it and the target app exposes it.
- Reusable prompt fragments attached to the mode.

Privacy controls:

- Speech recognition is always local.
- AI rewrite is optional and uses your configured service.
- Best-effort redaction tokenizes recognizable sensitive spans before a rewrite and restores them on
  your Mac afterward.
- Redaction is pattern matching. It can miss content.
- When privacy mode is on for a mode, context is forced off.
- A mode can be excluded from local history.

Use privacy mode for sensitive rewrite modes where the transcript itself can be redacted and context
should not leave the Mac. Leave AI rewrite off entirely for content that must never reach a provider.

Checkpoint: open History after a rewritten dictation and inspect Details. You should be able to tell
which mode ran, whether redaction applied, whether context was sent, and which provider/model handled
the rewrite.

## 11. Use history as an audit trail and correction surface

History is local JSONL under `~/Library/Application Support/KeyScribe/history/`. Audio is never saved.
Password-field dictations are never saved.

Open menu bar > History to:

- Search past dictations.
- Copy or paste the final result.
- Copy what KeyScribe heard.
- Compare Heard, Transformed, and Result.
- Inspect privacy and processing details.
- See the exact prompt sent for AI rewrite when one exists.
- Create a replacement or dictionary entry from selected text.
- Export filtered history as Markdown, text, or JSON.
- Delete individual entries.

History is enabled by default with local retention. Change retention in Settings > General, or turn on
**Do not save this mode in history** for sensitive modes.

Checkpoint: after your first week, search History for the words you corrected most often. Promote the
repeated ones to replacements; remove dictionary terms the model now gets right on its own.

## 12. Build reusable writing instructions

Reusable instructions are prompt fragments shared across modes. They are useful when several modes
should share the same voice or constraints.

Examples:

- `My Voice`: short sentences, plain language, no hype.
- `Support Tone`: direct, kind, no blame.
- `Markdown Rules`: use raw Markdown, never wrap the whole answer in a code fence.
- `No Invention`: never add names, dates, links, or facts that were not in the transcript.

Create one:

1. Open Settings > Modes.
2. Choose a rewrite mode.
3. In Improve with AI, use Add instruction > New instruction.
4. Write the reusable instruction.
5. Attach it to other modes that should share the same rule.

Fragments live as Markdown files under `~/Library/Application Support/KeyScribe/fragments/`.

Checkpoint: move repeated prompt text into a fragment only after you have copied it into two modes.
One-off instructions can stay inside the mode prompt.

## Capstone workflows

Use these as templates for your own setup.

### Fast local default

- Plain Dictation on `Right Option`.
- Live edits on.
- History on with short retention.
- No AI rewrite.
- Dictionary for names and jargon.
- Replacements for repeated mishearings.

### Chat and email from the same key

- Plain Dictation owns `Fn`.
- Message also owns `Fn`, but only in your chat app.
- Email has the spoken suffix `as an email`.
- Polish is menu-only for occasional cleanup.

### Editing mode for existing text

- Edit Selection enabled.
- One dedicated trigger, such as `Control+Option+E`.
- App details off unless they improve your output.
- Best-effort redaction on if you want context forced off.
- History excluded for sensitive editing.

### Prompt and command workstation

- AI Prompt enabled with a smart model connection.
- Markdown enabled for notes.
- Shell enabled but reviewed before use.
- Shell has `trim_trailing_punctuation = true`.
- Any submit key is TOML-only and used only after you trust the target.

## Where to go next

- [Tips & Tricks](tips.md) for small techniques that are easy to miss.
- [FAQ.md](../FAQ.md) for permissions, Globe-key conflicts, engine choice, and troubleshooting.
- [PRIVACY.md](../PRIVACY.md) for the exact local/cloud boundary.
- [Speech Model Benchmarks](reference/stt_benchmarks.md) for speech-model benchmarks and the local benchmark
  workflow.
- [Advanced Configuration](reference/advanced_configuration.md) for file-level mode examples.
