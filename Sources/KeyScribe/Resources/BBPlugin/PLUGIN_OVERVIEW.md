# Spoken replies and the thread in front

This plugin tells the dictation app on this Mac when each thread starts and finishes a turn, so the reply to
something you dictated to a thread can be read aloud, and which thread the bb window you used last shows, so
dictation can go to the thread you are looking at. It reports the reply and a short fingerprint of the prompt
that started the turn, never the prompt itself, and only over a connection on this Mac. While the app isn't
running it waits and sends nothing.

## What you get

- The reply to what you dictate to a bb thread, read aloud by the app.
- Dictation that goes to the bb thread in front, the focused pane of a split included.

## How it works

Each bb window reports to the plugin whether it has focus and which thread its focused pane shows. The plugin
tells the app which thread the most recently focused window shows, and forgets a window that stops reporting.
The app trusts that only while bb is the app in front.

The app installs and updates this plugin. To remove it, choose Uninstall Plugin under bb in the app's
Coding agent settings.
