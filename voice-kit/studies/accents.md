# Help me test dictation with your accent

Hi! I am trying to make {{APP}} work better for people whose English does not sound like mine. The speech models are trained mostly on a narrow set of voices, and I only have my own to test with. If you have ten minutes, I would love a recording of you reading 35 short sentences.

Nothing gets installed. The script uses the {{APP}} you already have, keeps a copy of each recording on your Mac, and makes one zip for you to send me. It does not send anything by itself.

## What to do

1. Unzip `voice-kit.zip` (it lands in Downloads as a folder called `voice-kit`).
2. Open Terminal (Command-Space, type `Terminal`, Return).
3. Paste this line and press Return:

   ```
   zsh ~/Downloads/voice-kit/record.sh
   ```

4. Answer a few quick questions (first language, how you would describe your accent, which mic). Press Return to skip any of them.
5. The script restarts {{APP}} once so it keeps the recordings. Press Return when it asks.
6. For each sentence: keep the Terminal window in front, hold your normal dictation key, read the sentence, let go, then press Return.
   - `l` plays your take back
   - dictate again to redo it
   - `p` goes back, `n` skips, `q` stops (run the script again later to pick up where you left off)
7. When you finish, a Finder window opens with `keyscribe-accents-<your name>.zip` selected. Send me that file.

## A few things to know

- Use your normal voice and pace. Do not try to speak "clearly" for the computer. The whole point is how you actually talk.
- Mistakes are fine. If you stumble, dictate the sentence again and the new take replaces the old one.
- If you have a {{APP}} mode without an AI rewrite, use that one. It does not matter much, the script keeps the raw transcript either way.
- The zip has your voice and the answers you gave. I will use it only to test and improve recognition for your accent, and I will not share it. Once you have sent it you can delete the `keyscribe-accents-recordings` folder on your Desktop.
- {{APP}} restarts again at the end to put things back the way they were.

If anything looks wrong, stop and ping me. Thank you!
