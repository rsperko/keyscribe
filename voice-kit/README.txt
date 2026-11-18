Voice kit
=========

Thank you for helping. You read a short list of prompts using the dictation app
you already have ({{APP}}); the script keeps each recording and what
the app heard, then packs everything into one zip on your Desktop for you to
send back. Nothing is installed and nothing is sent anywhere by the script.

How to run
----------
1. Open Terminal (press Command-Space, type "Terminal", press Return).
2. Type the line below and press Return (adjust the path if you unzipped
   the kit somewhere other than Downloads):

       zsh ~/Downloads/voice-kit/record.sh

3. Follow the prompts. The script restarts {{APP}} once at the
   start (so it keeps the recordings) and once at the end (back to normal).

While recording
---------------
* Keep the Terminal window in front. Hold your usual dictation key, read the
  prompt shown, release the key, then press Return.
* Press  l  to listen to your take, dictate again to redo it, Return to move
  on,  p  to go back,  q  to stop (you can resume later by running the
  script again).
* Use a mode WITHOUT an AI rewrite if you have one; the script records what
  the app heard either way.

When you finish, a Finder window opens with the zip selected. Send that zip
to the person who gave you this kit, then you can delete the recordings
folder on your Desktop.
