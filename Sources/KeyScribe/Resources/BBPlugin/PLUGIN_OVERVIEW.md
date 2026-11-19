# Spoken replies and the thread in front

This plugin tells the dictation app on this Mac when each thread starts and finishes a turn, so the reply to
something you dictated to a thread can be read aloud, and which thread the bb window you used last shows, so
dictation can go to the thread you are looking at. It reports the reply, a short fingerprint of the prompt
that started the turn and of each message the turn took in, never the messages themselves, and whether you or bb queued that prompt, and what bb shows about an approval or question a thread stops
for, only over a connection on this Mac. While the app isn't
running it waits and sends nothing.

## What you get

- The reply to what you dictate to a bb thread, read aloud by the app.
- Dictation that goes to the bb thread in front, the focused pane of a split included.
- Dictation on the new-thread page that starts a new thread, sent from that page's message box the way Enter
  sends it, with the project and settings chosen there.
- Dictation to the thread in front whose message box already has text is added after that text and sent with it,
  the way Enter sends it.
- A spoken line saying what a thread waits on when it stops for your approval or an answer.
- Read this thread's reply aloud, or don't, from the message box's + menu or the command palette.
- A tool every thread's agent can call when you ask it to have the app read its reply aloud. bb adds it when it
  next starts a thread's agent.
- The name to say for a thread, under its title in the sidebar, when its title says something else, while the app
  is running. The app turns
  on bb's thread row details (Organize ▸ Rows ▸ Metadata) when it installs this plugin, unless they were already
  on, and offers to turn them back off when you uninstall it.

## How it works

Each bb window reports to the plugin whether it has focus and which thread its focused pane shows, or that it
shows the new-thread page. The plugin tells the app which thread the most recently focused window shows, or that
it shows the new-thread page, and forgets a window that stops reporting.
The app trusts that only while bb is the app in front.

The app installs and updates this plugin. To remove it, choose Uninstall Plugin under bb in the app's
Agent settings.
