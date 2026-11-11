# Privacy in KeyScribe

KeyScribe is built local-first. This document describes precisely what stays on your Mac, what can
optionally leave it, and the limits of those guarantees. It describes how the software behaves; it is
not a legal privacy policy.

## Summary

| Data | Where it goes |
| --- | --- |
| Audio from the microphone | Transcribed on your Mac. Never uploaded by KeyScribe. |
| Plain Dictation text | Processed and inserted on your Mac. No provider request. |
| Optional rewrite text | Sent only to the provider or endpoint configured for that mode. |
| Clipboard text inserted by voice | Tokenized before rewrite and restored locally; not sent as clipboard text. |
| History | Local JSONL files under `~/Library/Application Support/KeyScribe/`. |
| Saved API keys | macOS Keychain. The config stores only a key reference. |
| Command-generated bearer tokens | Memory only, with expiry honored when present. |
| Speech model weights | Downloaded on demand, cached locally, and reused offline. |
| Spoken replies voice | Downloaded only when you choose Download, then runs on your Mac. Nothing it reads is sent anywhere. |

## What never leaves your Mac

- **Speech recognition is always on-device.** There is no cloud speech-to-text in KeyScribe, and
  there is no setting that enables one. Your audio is transcribed locally by an engine running on
  your machine.
- **No telemetry, no analytics, no crash reporting.** KeyScribe does not collect or transmit speech,
  transcripts, usage data, or diagnostics. There is no account and no sign-in.
- **History stays local.** Past dictations are stored as plain JSONL files under
  `~/Library/Application Support/KeyScribe/` and are never uploaded. History is on by default and
  keeps a limited number of days, which you can change or turn off in Settings. The history folder is
  excluded from Time Machine backups.
- **Your saved API keys stay in the Keychain.** BYOK provider keys are stored in the macOS
  Keychain. The on-disk config holds only a reference to a key, never the key material itself.
- **Command-generated tokens are not persisted.** OpenAI-compatible endpoints can use a command that
  prints a bearer token. KeyScribe keeps generated tokens in memory only, honoring reported expiry
  when present.

## The only things KeyScribe itself sends

KeyScribe itself sends content off your Mac on two paths only, both **optional, bring-your-own-key (BYOK)
LLM calls** to a service you configured, and both off unless you turn them on:

- **LLM cleanup**, which rewrites a transcript (removing filler, fixing grammar, reformatting). It runs only
  for a mode you enabled it for. When a rewrite falls back, **Rewrite Again** in History sends that
  dictation's transcript to the mode's service once more, with no context. It is redacted if the original
  dictation was or the mode is now, so turning redaction off later never sends that dictation unredacted.
- **Spoken replies**, in the experimental Coding agent feature. Notices that a conversation is waiting for you or
  lost its connector are fixed sentences and send nothing, with one exception: when a Pi conversation you
  dictated to opens a prompt, or you ask what a Pi conversation is waiting for and its prompt has no short
  question to read as it is (whoever started that turn, you typing included), the prompt's kind and title, the tool call it seems to be about (its name and up
  to a thousand characters of arguments, such as the command it asks you to approve), and the agent's last
  words before it asked are sent to the service you chose, after best-effort redaction, to say in a sentence
  what it asks. Which tool call a prompt belongs to is a best guess, so another tool's arguments can be sent. When an agent finishes an instruction you
  dictated, or work you asked it to have KeyScribe read aloud, a longer final reply is sent to the service you chose
  under Spoken replies, only to be summarized into a sentence or two to read aloud; a short reply is read without it,
  a longer one is only announced when no service is chosen, and nothing is sent for a dictated reply's
  conversation KeyScribe can confirm is in front of you when it finishes. When it can't confirm that, such as
  in a terminal it can't read, the reply is sent as usual. Agent replies often contain code and command output, and the
  redaction described below is tuned to dictated speech, so it catches less there. Choose a local service
  such as oMLX if replies must stay on your Mac.

A script or
shortcut you set up to run by voice can send what you said wherever it is built to; see
[Programs and shortcuts you run by voice](#programs-and-shortcuts-you-run-by-voice).

When it runs:

- The request goes to **the provider and endpoint you configured**, authenticated using the
  credential method you selected: a Keychain-backed API key, no auth for local/no-auth endpoints, or
  a command-generated bearer token. KeyScribe has no LLM service of its own.
- Before the request is sent, recognizable sensitive spans may be **tokenized out** of the
  transcript or reply (the redaction wedge, below). A rewrite restores them locally in the response; a
  spoken summary never reads them aloud and says "a hidden value" instead.
- Turn both off and KeyScribe itself makes no network calls after the initial one-time model
  downloads, apart from the update check below.

## Network use, in full

KeyScribe only reaches the network for these things, and never to send your audio:

1. **Downloading speech models** — on-device engine weights are fetched on demand from their
   publishers (e.g. Hugging Face) the first time you select an engine, then cached locally and reused
   offline. A tiny (~1 MB) voice-activity-detection model is fetched the same way, alongside your first
   speech model; it runs entirely on-device to detect whether a recording contains any speech (so a
   silent trigger inserts nothing) and never sends audio anywhere. The spoken replies voice is fetched
   the same way, from Hugging Face, only when you choose **Download** for it.
2. **Your own AI service**, if you set one up — the optional LLM cleanup and the summaries
   read aloud under Spoken replies, described above, plus the connection test and model list when you add or edit a connection. All of it goes to the provider
   you configured and nowhere else. While you are recording a mode that uses it, KeyScribe may also
   open the connection ahead of time so the cleanup comes back faster, and run the connection's token
   command if it has one; neither carries content, and both are skipped entirely when you are typing in
   a password field.
3. **Checking for app updates** — KeyScribe periodically fetches a small update feed to see whether a
   newer version is available, and downloads it only if you choose to install one. It asks before the
   first automatic check and you can turn it off. It carries no speech, transcript, or usage data —
   only the metadata any HTTP request unavoidably reveals (your IP address and the app/OS version); the
   updater's optional anonymous system profiling is left disabled. Updates are cryptographically
   verified before they run.

There is no background phone-home or license check.

## Programs and shortcuts you run by voice

With the experimental voice commands you can name a script or a macOS shortcut that KeyScribe runs
when you say **run** and its name, and pass it the words you say after the name. It runs whenever what
you say starts with "run" and one of its names, including a mishearing of something else. A name said
without "run" never runs one, and neither does "switch to" or "open". KeyScribe starts a script on your Mac and hands it those words
as an argument, or runs a shortcut and hands them over as its input; it does not send them anywhere
itself. What the script or shortcut does with them is up to what you chose: a shortcut can send
messages, change files, or send its input to online services, depending on its steps. Both run as you, with
everything your account can do, and a misheard command can run them, so choose what you connect this
way with care.

macOS may count a script's requests for protected access as coming from KeyScribe. A script can then use
permission you already gave KeyScribe, such as Automation, Accessibility, or Microphone, without being asked
again, and a new request can name KeyScribe even when a script caused it. This depends on what the script
does and how macOS attributes it, so not every program gets every permission this way; permission you gave
Terminal may not apply here, and a shortcut can have its own permissions and approval dialogs. Allowing
KeyScribe to control your browser, which its tab features need, lets KeyScribe control that browser, not only
read its tabs: a script you run by voice can use the same permission for something else. What the built-in
features read is described below.

Every Run a Script and Run a Shortcut sheet explains these consequences before saving, each in its own
words, and every Open an App, Open a Link, and Find a Browser Tab sheet explains that it can bring an app's
windows forward. Separately,
a notice before first enabling Voice Commands explains that recognition mistakes can bring an unintended
window into view or start an unintended saved action. It also explains that scripts and Shortcuts run by
voice may act without asking for confirmation and can change files, send messages, or share information.

To find a window you name, Voice Commands reads the titles of your open windows on this Mac, only when
no app or place matched what you said. The titles are not sent anywhere or written to diagnostic logs.

With finding items in apps turned on (an experimental feature, off unless you turn it on), saying an app's
name followed by more words, such as "open Slack general", reads that app only: a browser's open tab titles
and addresses, or the names listed in another app's sidebar, such as channels, people, or mailboxes. Nothing
is read in the background. After "open", an app that is not open is opened first; "switch to" never opens one. These
names are not sent anywhere or written to diagnostic logs; History records the command and what it opened,
as described below. For some apps, such as Slack, reading the sidebar first turns on the app's own
accessibility support, which stays on until that app quits.

When history is on, each voice command is saved there like a dictation: what you said, the command it
ran with those words (for a window, its title and app, and the titles in a list it offered you), and, if it failed, the error message, which can include the last line the script
or shortcut wrote to its error output. An action still running when it is saved is updated with its
final result when it finishes. Turning history off stops this along with everything else; to keep only voice
commands out, turn on **Do not save this mode in history** in the Voice Commands settings.

## The redaction wedge — and its limits

When LLM cleanup is enabled, KeyScribe attempts to keep recognizable sensitive spans out of the
request: matching spans are replaced with nonce tokens *before* the transcript is sent, and the
original text is substituted back in locally *after* the response returns. The mapping from token to
original lives in memory only — it is **never logged and never written to history**. A validation gate
checks that every token sent to the model comes back exactly once, rejects stray token-looking text,
and rejects empty responses before the result is used; on failure KeyScribe retries once more
strictly, then falls back to the local transcript with a HUD notice.

**This is best-effort redaction, not a security guarantee.** It reduces what a third-party model
sees when a span is recognized, but it cannot promise that every sensitive span is caught. It works
on the text produced by speech recognition, so it can miss content the recognizer verbalizes or
normalizes, such as an email address transcribed as words. Treat it as a safety margin, not a
boundary you can rely on for regulated or high-stakes data. If something must never reach a
third-party provider, use Plain Dictation or another mode with LLM cleanup off that places text into an
app you trust with it. The experimental Coding agent mode is not one: turning cleanup off does not
prevent agent instructions from reaching a provider. KeyScribe sends your words unredacted to the coding
agent, which uses its own provider settings.

## Privacy mode and context are mutually exclusive

Some modes can attach context to the LLM request to improve the rewrite. When a mode's **privacy
toggle** is on, those context options are forced off and locked: the transcript, after best-effort
recognizable-span redaction, is the only user content that can leave the machine for that mode.

## Where your data lives

Everything KeyScribe persists is a plain file under `~/Library/Application Support/KeyScribe/`, or beside it
in the same `Application Support` folder:

- **Config** (modes, connections, dictionary, replacements) as TOML.
- **History** as JSONL, one file per day. Each entry holds what you said and what was inserted, what a
  coding agent's spoken reply read aloud (see Spoken replies above), and,
  for a mode that uses an AI service, the request sent to it. That request can include text from other
  apps: the text you selected for a rewrite mode, and whatever context the mode attaches, such as text
  before the cursor. It is plain text, readable by anything running as you. Each entry also records
  the app the text was meant for, the microphone used, the delivery method that was attempted, how long each
  step took, how long you spoke, the error when one occurred, which modes your shortcut could have started,
  and the app and macOS versions. History's **Copy Report** copies one entry, every one of those fields
  and the text included, plus a summary of your setup, to your clipboard for a bug report; it is sent only
  if you paste it somewhere yourself.
- **What your AI service accepted**, in two small files beside that folder (named after it, ending in
  `-request-adaptations.json` and `-wire-overrides.json`): which request format and fields each connection's
  model took, so KeyScribe does not have to find out again after a restart. An update starts them over. Each entry names the connection,
  its model and its address as written in your connections. They hold no prompt or reply and no saved key or
  generated token.
- **Replacement use counts** under `usage/`: for each of your replacements, how many dictations it
  changed and the day it was last used. No dictation text is stored there, and it is kept whether or
  not History is on.
- **Downloaded speech model weights** under `models/`, including the spoken replies voice. Part of that
  voice, its pronunciation files, is stored in `~/.cache/fluidaudio/Models/kokoro`, a folder other apps
  built on the same speech library can share. **Delete Voice** removes the voice and leaves that folder
  alone, because another app may be using it; delete it yourself if nothing else needs it.
- **Coding agent connection** under `agents/`, only if you turn on the experimental Coding agent
  feature: an access token the agent connectors use to reach KeyScribe on your Mac, the Claude Code
  connector's files, `connectors.json`, the agent folders you connected and which connector installation
  may connect from each, and `names.json`, the names you chose for conversations along with their agent
  session ids and the conversations you disconnected. The Pi connector's files live in the extensions
  folder of each Pi folder you connected, because that is where Pi loads them from; they hold the same
  connection settings and nothing else. To find the conversations on your Mac and the folders their agents
  use, KeyScribe looks at your own running Pi and Claude Code processes: their working folder, start time,
  terminal, and a short list of environment variables (the agent's folder variable and the terminal and
  multiplexer variables its terminal routes use). It never reads or keeps any other variable or a full
  command line, and keeps what it found in memory only. A conversation you disconnect sends KeyScribe only
  who it is (its agent, session id, process and folder), never its title, prompts or replies. These are kept whether or not History
  is on, until you delete them. No message text is stored there. To show each conversation's title,
  KeyScribe reads the end of that conversation's own Claude Code transcript on your Mac; it keeps only
  the title, in memory, and never logs or stores the transcript. Pi's titles come from the connector,
  which reads nothing on disk but its own settings. To decide when to hand over what you said, the Pi
  connector notes the time of the last key pressed in that session, never which key. When you start a
  Coding agent dictation, KeyScribe asks the terminal in front which tab or pane is selected and reads the same
  process details, so what you say goes to the conversation you are looking at; it never asks for permission to
  do so, and the answer stays on your Mac and is not stored. To bring a
  conversation's terminal forward, KeyScribe reads a few terminal and multiplexer variables (such as a
  pane id) from the environment of the processes that hold it; the rest of their environment is ignored.
  If you turn on **Read replies aloud** and choose an AI service for it, a longer final reply to an
  instruction you dictated, or to work you asked the agent to have KeyScribe read aloud, is sent to that service, after best-effort redaction, only to be summarized
  into a sentence or two; a reply of a few words is read as it is without any service. KeyScribe keeps
  the full reply in memory only and never writes it to History or logs; what the service you chose keeps
  is up to that service. What KeyScribe actually reads aloud as a reply or a summary is saved in
  History exactly as you heard it, with the service that summarized it, when History is on and the Coding
  agent mode is not left out of History. A reply to an instruction you dictated is saved with that
  dictation, and only when the dictation itself was saved. While KeyScribe is running it also holds, in memory
  only, the audio the natural voice generated for each reply History saved, so you can play it again or save it to
  report a reply that sounded wrong. Audio for anything History did not save (a repeat, a notice, a preview) is
  dropped when it stops playing. Saved replies' audio is dropped at once when you delete that History entry or quit,
  and otherwise an hour after the reply, including when History's own retention removes the entry; it is written to
  disk only where you choose with **Save Generated Audio…** in History. A spoken reply can include text from the
  agent's output, such as a path or a command's result, as plain text. It is never written to logs.

You can inspect, back up, or delete any of it with the Finder or a text editor. Deleting the history
files removes that history; removing the application support folder resets KeyScribe.

When you say “insert clipboard contents” in a Coding agent message and the clipboard holds an image or a PDF,
KeyScribe saves it to a file in your Mac's temporary folder so the agent can open it. Once the file is a day
old, KeyScribe deletes it within the hour while it is running, or the next time it starts. The message names
that file; Pi also receives the image with the message. Like anything you send an agent, the agent may pass
it to its own AI service. History and Paste last dictation keep the message as sent, so they keep the
file's path, not the image.

While you dictate, the recording is written to a temporary file and deleted once it is transcribed. If
KeyScribe quits in the middle of a dictation, it deletes the leftover recording the next time it starts,
or within a few minutes of starting for a recording left by an older version.
**Erase All KeyScribe Data** in Settings removes everything described here except downloaded speech
models and the spoken replies voice, including retained and leftover recordings, and also deletes saved API keys from the Keychain.
One exception: a leftover recording made in the last few minutes by an older version of KeyScribe could
still be in use by that version, so it is kept, and the next start deletes it. The voice's pronunciation
files in `~/.cache/fluidaudio/Models/kokoro` are never touched, since other apps may share that folder.

## What KeyScribe trusts

KeyScribe treats its own settings folder as yours. Anything that can change the files in it can change
what KeyScribe runs on your behalf:

- **A connection's token command** runs through your login shell, as you, each time a token is needed.
- **Voice commands** run the script or shortcut a command names, with the words you said.

So protect that folder as you would your shell profile.

A voice command acts on whatever the microphone hears while you are recording, not only your own voice.
Anyone audible during a dictation, especially one you have left running, can supply the words a script
receives. Keep that in mind before connecting a script that sends messages, changes files, or calls
online services.

## Open source

KeyScribe is GPLv3 and the full source is public, so these claims are auditable end to end rather
than taken on trust.
