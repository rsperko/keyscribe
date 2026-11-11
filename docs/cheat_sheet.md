# What you can say

**KeyScribe desk reference.** Words in [brackets] are yours to fill in, not words to say.
Forgot a phrase? Say **“what can I say?”** on its own in any mode to see the phrases that work there.

## Dictate & fix

Use your **dictation shortcut**. These phrases work inside a dictation when the mode has
**Turn spoken editing phrases into edits** on (Settings > Modes > choose a mode).
Plain Dictation has it on by default. These edits affect the current take, before insertion.

| Say | Works in | What happens |
| --- | --- | --- |
| `insert new line` | Spoken edits on | Starts a new line. Keep **insert**; bare "new line" stays text. |
| `insert new paragraph` | Spoken edits on | Starts a paragraph with a blank line before it. |
| `insert tab character` | Spoken edits on | Inserts a tab in the text; does not move to another field. |
| `scratch that` | Spoken edits on; **pause after it** or end the take | Removes the recent segment or last inserted edit. Say the correction next. |
| `never mind`<br>Also: `start over` | Spoken edits on; **alone at the end** | Discards the whole take; nothing is inserted or saved to History. |
| `insert clipboard contents` | Spoken edits on; copy text first | Inserts copied text here, without rewriting it or sending it to the rewrite service. |
| `insert clipboard as code` | Spoken edits on; copy text first | Inserts copied text inside a Markdown code block. |
| `begin verbatim [words] end verbatim` | Spoken edits on | Keeps the words literal, protected from edits, replacements, and rewriting. |
| `what can I say?` | Any mode, said alone | Shows the phrases that work in this mode. Nothing is typed. |

### Try these

**Fix a sentence:** "Meet me at the gym at noon, scratch that, at the park."
Becomes "Meet me at the park." Repeat at least two words from the part being corrected ("at the")
to replace from there; otherwise, say the whole segment again. It cannot undo an earlier take.

**Say a command as text:** "begin verbatim scratch that end verbatim" keeps the words "scratch that."

**Remember:** After insertion, **Cmd-Z** undoes the whole dictation. "Scratch that" needs a recognized
pause or the end of the take; running it into the next words can leave it as text.

---

## Format & choose a mode

Use your **dictation shortcut**. End a dictation with another mode's spoken phrase to use that mode once.

| Say | Works in | What happens |
| --- | --- | --- |
| `[message] as an email` | Email enabled | Removes the phrase and uses Email for this take. |
| `[instruction] as a prompt`<br>Also: `as prompt` | AI Prompt enabled | Removes the phrase and uses AI Prompt for this take. |
| `[words] [your saved phrase]` | Enabled mode with that phrase | Uses that mode once. Set **Spoken phrase** in the mode's settings. |

**Mode phrases:** Starter modes such as Markdown, Code, Email, and Message bring their own phrases
(a sign-off, a checkbox, a code block). They live in each mode's vocabulary, where you can change them.
Say **“what can I say?”** with that mode's shortcut to see them.

**Edit selected text:** Highlight text, use your **Edit Selection** shortcut, then say "make this
more concise" or "turn this into bullet points." Requires a rewrite service.

**Write numbers as digits** (per-mode setting): "twenty five" gives `25`; "three point one four" gives
`3.14`; "fifty percent" gives `50%`.

**Make your own:** Add replacements in Settings > Vocabulary or a mode's vocabulary, such as
“slash resume” for `/resume`. See [Tips & Tricks](tips.md) and [Getting Started](getting_started.md).

---

## Move around & run commands

Use the **Voice Commands shortcut** (Settings > Maintenance > Experimental features turns it on).
Say one command per recording. A saved command's name works only after its verb.

| Say | Works in | What happens |
| --- | --- | --- |
| `open [app]`<br>Example: `open Mail` | Any installed app | Brings it forward, starting it if needed. |
| `switch to [app or window]`<br>Example: `switch to Notes` | Already open | Brings a running app, window, or tab forward. Never starts anything. |
| `open [saved place]`<br>Example: `open reading list` | Saved app or link | Opens that destination, reusing a matching web tab when possible. |
| `run [saved action] [input]`<br>Example: `run new note buy milk` | Saved script or Shortcut | Runs that action, passing the words after its name if it takes them. |
| `open [tab search] [title or site]`<br>Example: `open browser inbox` | Saved **Find a Browser Tab** | Finds the open tab that best matches. |
| `go back` | After a switch | Returns to the window or app you were in before. |
| `repeat that` | Spoken replies on | Replays the last spoken reply. |
| `cancel`<br>Also: `never mind` | Said alone | Runs nothing. |
| `what can I say?` | Said alone | Shows your apps and saved commands with their verbs. |

### When a numbered choice is showing

Record your answer with the **Voice Commands shortcut** while the choice is still on screen.

| Say | Works in | What happens |
| --- | --- | --- |
| `two`<br>Also: `the second one`, `the last one` | Numbered choice | Picks that option. |
| `cancel` | Numbered choice | Dismisses the choice; runs nothing. |
| `[a new command]` | Numbered choice | Replaces the pending command. |

**Practice first:** Type a phrase into **Preview a command** (Settings > Modes > Voice Commands) to see
what it would do. Nothing opens or runs. A saved name said alone does nothing and tells you its verb.

---

## Talk to coding agents

Use the **Coding agent shortcut** (Settings > Maintenance > Experimental features turns it on; connect
the agent in Settings > Modes > Coding agent). [Name] is a conversation name shown there or while recording.

| Say | Works in | What happens |
| --- | --- | --- |
| `tell [name] [instruction]`<br>Example: `tell backend run the tests` | Connected conversation | Sends it there and makes it the recipient. A conversation in front of you can still take over; the recording panel shows where a take goes. |
| `ask [name] [question]` | Connected conversation | Sends the question to the agent. |
| `select [name]`<br>Also: `choose [name]` | Known conversation | Makes it the recipient. Sends nothing; windows stay put. |
| `open [name]` | Known conversation | Brings its terminal forward and makes it the recipient. Sends nothing. |
| `tell conversation two [instruction]` | While recording | Uses number 2 from the list on screen. Saying "session two" works too. |
| `check on [name]` | Known conversation | Reports its status. Sends nothing; the recipient stays the same. |
| `check on all conversations` | Coding agent mode | Names the conversations waiting for you. Sends nothing. |
| `rename this conversation to [name]` | The current conversation | Renames it. Say only the rename. |
| `repeat that` | Spoken replies on | Replays the last spoken reply and names its conversation. |
| `cancel`<br>Also: `never mind` | Said alone | Sends nothing. To send the word, say `tell [name] cancel`. |
| `what can I say?` | Said alone | Shows these phrases with your conversation names. |

### Practice without sending anything

These send nothing: “select backend” shows **Recipient: backend**; “open backend” also brings its terminal
forward; “check on backend” answers locally; “backend” alone tells you to say “select backend”;
“cancel” shows **Cancelled. Nothing sent.** Any question you ask, such as “what are you waiting for?”, is a
message. “Tell” and “ask” always send, so check the **To …** line on
the recording panel before you stop recording.

**If it didn't go through:** when the panel says **Nothing sent.**, your words are kept: **Paste Last
Dictation** pastes them. When it says **May not have reached** a conversation, check its terminal before
sending again. Starting a recording or pressing Esc stops spoken playback, never the agent's work.

---

## Other ways to say it

These work too. The phrases on the earlier pages are the ones worth remembering.

### Dictate & fix

| Say | Works in | What happens |
| --- | --- | --- |
| `insert a new line`<br>Also: `insert newline`, `insert a new paragraph`, `insert a tab character` | Spoken edits on | Same as the phrases on page 1. |
| `insert the clipboard contents`<br>Also: `insert clipboard as a code block` | Spoken edits on | Same as the shorter clipboard phrases. |
| `show commands` | Any mode, said alone | Same as `what can I say?` |

### Move around & run commands

| Say | Works in | What happens |
| --- | --- | --- |
| `launch [app]` | Any installed app | Same as `open`. |
| `go to [app or window]`<br>Also: `focus [app or window]`, `focus on [app or window]` | Already open | Same as `switch to`. |
| `say that again` | Spoken replies on | Same as `repeat that`. |
| `number two`<br>Also: `second` | Numbered choice | Same as `two`. |
| `please open Mail`<br>Also: `open Mail, please` | Any command | A "please" before or after a command changes nothing. |

### Talk to coding agents

| Say | Works in | What happens |
| --- | --- | --- |
| `[name], [instruction]` | Connected conversation | Same as `tell [name] [instruction]`. |
| `select conversation two`<br>Also: `open session two`, `check on conversation two` | While recording | Picks, opens, or checks by number. |
| `check on this conversation` | The current conversation | Checks the recipient. |
| `who needs me?` | Coding agent mode | Same as `check on all conversations`. |
| `rename this session to [name]`<br>Also: `name this conversation [name]`, `call this conversation [name]` | The current conversation | Same as `rename this conversation to`. |
| `switch to [name]`<br>Also: `go to [name]` | Known conversation | Same as `open [name]`. |
