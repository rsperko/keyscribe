Connects Ultimate to the dictation app on this Mac, so you can talk to @ultimate, your standing agents and your
branches by voice and hear their replies.

## What you get

- Dictation that goes to the conversation you are looking at, or to one you name, including while it works: a
  message for a running turn joins it the way typing there does.
- Dictation for the conversation in front whose message box already has text is added after that text and sent
  with it.
- The reply to what you dictate, read aloud by the app when the turn ends.
- A spoken line saying what a conversation asks you when it stops with a question for you.
- Read this reply aloud, or don't, from the command palette.
- A tool every agent can call when you ask it to have the app read its reply aloud.

## How it works

The server half runs in each Ultimate process this folder loads into. It watches the conversations Ultimate lists in
its sidebar, reports when each starts and finishes a turn, and submits what you dictate as your own message. It
talks only to the dictation app, over a connection on this Mac, and only while the app is running; otherwise it
waits and sends nothing. It reports the reply, a short fingerprint of the prompt that started the turn (never the
prompt itself), and the question a conversation asks you.

Each open Ultimate page tells the server half whether it has focus, which conversation it shows and whether its
message box holds text. Only a focused page keeps reporting.

The app installs and updates this folder. To remove it, choose Uninstall under Ultimate in the app's Agent
settings; turning it off in Ultimate's Extensions panel also works.
