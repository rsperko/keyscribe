# KeyScribe — Competitive Landscape

> Survey of the voice-dictation / speech-to-text space we are entering with KeyScribe.
> Split into two layers: **(A) end-user dictation apps** (our direct competitors) and
> **(B) the underlying STT model families** they are built on (our pluggable engines).
> Researched June 2026. Sources linked at the bottom.

---

## A. End-user dictation / transcription apps

These are the products a user would choose *instead of* KeyScribe. Grouped by posture.

### Premium "AI dictation" apps (custom modes + LLM rewrite)

#### Superwhisper — the closest analog to what we are building
- **Posture:** macOS / Windows / iOS. On-device STT (Parakeet + Whisper) with optional cloud LLM rewrite. No account required for core use.
- **Defining feature: Custom Modes.** Per-task configs (email mode, code-comment mode, casual mode) that bundle a speech model, an AI rewrite prompt, and vocabulary.
- **AI rewrite:** "rewrite my speech as a professional email / bullet points / clean grammar while keeping tone." BYOM — pick GPT, Claude, or Llama.
- **Context awareness:** reads text around the cursor and adapts output to fit.
- **Other:** 100+ languages, 30+ stackable "personas" (default assistant "Iris"), a "Slate" collaborative human-AI writing surface (beta), rewrite-by-voice commands.
- **Privacy:** dictation STT + text correction run on-device; no audio leaves the machine for dictation.
- **Why it matters to us:** our scratch-pad architecture (pluggable STT + command pipeline + modes + BYOK) is essentially a more principled take on Superwhisper. This is the product to beat on feature depth.

#### Wispr Flow — the cross-platform incumbent / market leader
- **Posture:** the only major one on **Mac + Windows + iOS + Android** (+ Chrome/Edge) simultaneously (as of Apr 2026). Cloud-first.
- **AI editing stack:** multiple layers — transcription, filler-word removal ("um"/"uh"), auto-punctuation, backtracking/self-correction cleanup, app-aware style adaptation.
- **Command Mode (Pro):** voice-edit highlighted text — "make this more concise," "translate to Polish," "turn this outline into a paragraph."
- **"Hey Flow" wake word:** hands-free commands without dictating first.
- **Compliance:** SOC2 Type II, HIPAA controls at any tier — a differentiator none of the indie apps match.
- **Pricing:** Free Basic (2,000 words/week ≈ 8 min/day); Pro $15/mo ($12 annual); Enterprise.
- **Why it matters:** the polish + platform-breadth + compliance benchmark. We will not match platform breadth early; privacy/local-first is our wedge against them.

#### Aqua Voice — the "raw speed + technical vocab" specialist
- **Posture:** Mac + Windows, cloud (proprietary "Avalon" model).
- **Speed:** initiates <50ms, transcribes in as little as ~450ms; streaming text as you speak.
- **Accuracy:** markets 97.4% on technical dictation; handles coding terms / jargon better than most.
- **Features:** voice editing commands (select + modify text), custom dictionary, natural-language formatting instructions, inline AI commands, context awareness, 49-language auto-detect.
- **Pricing:** ~$10/mo for faster inference.
- **Knock:** praised for browser integration, criticized for periodic lag.

#### Willow Voice — style-adaptive cloud dictation
- **Posture:** cross-platform, cloud.
- **Claims:** ~200ms latency, "3x more accurate than Apple dictation."
- **Features:** style-aware formatting that adapts tone over time, filler-word removal, 50–100+ language auto-detect with mid-sentence switching.
- **Privacy:** default privacy mode — no transcript/voice collection unless opted in.

### Transcription-first / file-based

#### MacWhisper (App Store: "Whisper Transcription")
- **Posture:** native macOS, **fully on-device** (Whisper + NVIDIA Parakeet). Zero data leaves the machine.
- **Strength:** batch file transcription — drop MP3/WAV/MOV/MP4, get transcript at ~30x realtime with **speaker diarization** (Parakeet v3, since v12 / Mar 2025), timestamps, 50+ export formats (SRT, VTT, Word, PDF, JSON, CSV…).
- **Pricing:** Gumroad ~$69 lifetime Pro; App Store $29.99/yr or $99.99 lifetime.
- **Note:** more a transcription workbench than a live-dictation tool — adjacent, not head-to-head, but overlaps on the local-model story. Diarization + export breadth is a feature gap to note.

### Open-source / indie (our "free alternative" pressure)

#### VoiceInk — the open-source benchmark
- **Posture:** native macOS, GPL v3, ~4,300+ GitHub stars. Built by indie dev Prakash Joshi Pax.
- **Engine:** local Whisper via whisper.cpp; optional cloud "AI Enhancement."
- **Power Mode:** auto-adjusts dictation settings based on active app / URL (direct analog to our **Modes → bundle constraints / triggers**).
- **Pricing:** $39.99 one-time, or build from source free.
- **Why it matters:** sets the floor. If our differentiation is "local + modes + pipeline," VoiceInk already does the first two for cheap/free. We need the **command pipeline** depth to stand apart.

#### Parleq — the closest current rival to our exact posture
- **Posture:** privacy-first macOS dictation on **Parakeet TDT v3**, with vocabulary boosting,
  provider-pluggable LLM cleanup, and reference-window context. This is "local + Parakeet +
  BYOK cleanup + context" — i.e. most of our *baseline* in a shipping app today.
- **Why it matters:** it confirms the wedge can't be "local Parakeet + app-aware cleanup"
  anymore — that combo is now table stakes. KeyScribe's separation has to come from the
  **explicit staged pipeline + redaction/restoration + dynamic state-driven prompt**, not from
  the engine or context-cleanup alone.

#### The FluidAudio / Parakeet showcase crowd
FluidAudio's own showcase now lists many Parakeet-based local dictation/transcription apps —
**VoiceInk, Spokenly, FluidVoice, Dictato, Parleq, Dettivo, Muesli, Thoth**, and others. The
takeaway for sequencing: the on-device-Parakeet space is crowding fast, so our differentiating
pipeline stages cannot stay purely theoretical until late in the build (cf. `roadmap.md`).

#### Others in the FOSS / cheap tier
- **OpenSuperWhisper** — FOSS macOS dictation.
- **OpenWhispr** — free, cross-platform (Mac/Windows).
- **Vocamac** — open-source, offline, WhisperKit-powered, hold-hotkey-and-speak.
- **FluidVoice** — native-feel macOS dictation (Parakeet, FluidAudio showcase).
- **Whisper Notes** — $6.99 one-time, "no input monitoring" privacy angle.
- **Voibe, Spokenly, Dictato, DictaFlow, Voicy, SpeakMac, Ottex AI, Mumble** — a crowded long tail of on-device/cloud dictation apps, most positioning on price or a single axis (privacy, latency, vibe-coding).

### Native baseline

#### Apple Dictation / Voice Control (macOS Tahoe + SpeechAnalyzer)
- **Posture:** built-in, free, on-device on Apple Silicon (when "Send to Apple" disabled).
- **macOS Tahoe transcription APIs:** ~55% faster than Whisper per Apple.
- **Limitations everyone routes around:** ~30s continuous-speech / silence cutoff; flaky in third-party text fields; accent/locale brittleness; no AI rewrite, no modes, no custom pipeline.
- **Why it matters:** the free default we must clearly beat. Every competitor's pitch is "better than Apple Dictation" — ours has to be obvious too.

---

## B. Underlying STT model families (our pluggable engines)

Our scratch pad specifies pluggable STT: **Whisper / Parakeet / Apple**. Here is the state of each as of 2026. (A 13,000-recording shootout by Dictato also adds **Qwen3** as a rising 4th option.)

| Engine | Speed (Apple Silicon) | Accuracy (English WER) | Languages | Notes |
|---|---|---|---|---|
| **NVIDIA Parakeet** (TDT 0.6B v3) | ~3,333x realtime; ~10x faster than Whisper Large v3 Turbo; latency can hit ~80ms | ~12.0% WER — slightly **better** than Whisper; wins on disfluent speech (tuned to drop fillers, reconstruct sentences) | **25** | Fastest by a wide margin. Built-in diarization (v3). Best default for English live dictation. |
| **OpenAI Whisper** (Large v3 / Turbo) | ~146x realtime | ~12.6% WER | **99** | The multilingual workhorse. Best when language coverage matters. whisper.cpp / WhisperKit make on-device easy. |
| **Apple SpeechAnalyzer** (Tahoe) | ~150–400ms latency; ~55% faster than Whisper | Most accurate on clean read-aloud FR/ES/DE/IT; weaker than Parakeet in English; ~Whisper for supported langs | **20** | Zero-install, OS-native, free, on-device. Great latency/accuracy for European languages; session/robustness limits. |
| **Qwen3 (ASR)** | — | competitive in the Dictato shootout | — | Emerging 4th engine worth tracking; not yet mainstream in shipping apps. |

**Implications for KeyScribe's pluggable-STT design:**
- **Parakeet = sensible English default** (speed + accuracy + diarization), **Whisper = multilingual fallback** (99 langs), **Apple = zero-footprint option** (no download, good EU-language accuracy).
- Model **download/compile-with-progress + select + delete** (already in the scratch pad) is the right UX — every serious local app does this.
- Diarization is a Parakeet-v3 capability we get largely "for free" and could expose.
- Worth a 4th-engine seam (Qwen3) so we are not locked to three.

---

## C. Feature patterns worth stealing / matching

Cross-cutting capabilities that show up repeatedly and map onto our scratch-pad architecture:

1. **Per-context Modes / Power Mode** (Superwhisper, VoiceInk, Wispr) — auto-switch config by active app/URL. → our **Modes + bundle constraints + trigger keys/phrases**.
2. **LLM rewrite with BYOK / model choice** (Superwhisper, Aqua, Wispr) → our **AI Service BYOK + per-mode AI rewrite + prompt + context**.
3. **Context injection from the active window** (Superwhisper, Aqua) → our **Context: visible window text / app & field details**.
4. **Voice editing commands on selected text** ("make concise," "translate") — Wispr Command Mode, Aqua → *not yet in our scratch pad; a gap to consider.*
5. **Filler-word removal + self-correction / "scratch that"** (Wispr, Parakeet-native) → our **Live edits: scratch that / new line / paragraph**.
6. **Custom dictionary + regex replacements** (Aqua, Willow, all) → our **Dictionary & Replacements (heard/replace/regex)**.
7. **Wake word / hands-free** ("Hey Flow") → *not in scope yet; future.*
8. **Privacy posture as marketing** (local-only, no input monitoring, opt-in collection) → our **on-device STT + local history + redaction/privacy commands** is a strong wedge.
9. **Compliance (SOC2/HIPAA)** (Wispr) → enterprise-only concern; note for later.
10. **Speaker diarization + rich export** (MacWhisper) → adjacent; relevant if we add file transcription.

### Where KeyScribe's scratch pad is already differentiated
- **First-class command pipeline** with explicit pre/post-STT and pre/post-LLM stages — most competitors bolt rewrite on as one opaque step. Our **Verbatim** and **Privacy/redaction** token stages (operating across STT→LLM boundaries) are a genuinely novel, privacy-forward angle.
- **Insertion method control** (paste / accessibility insert / type) — a power-user reliability lever Apple Dictation's flakiness makes valuable.

### Gaps to consider adding
- Voice-driven editing of **already-selected** text (Wispr/Aqua have it; we don't).
- Speaker diarization + file/batch transcription (MacWhisper's turf).
- Cross-platform reach (everyone but us; Wispr leads). Likely out of scope for v1.

---

## Sources

- [Superwhisper](https://superwhisper.com/) · [App Store](https://apps.apple.com/us/app/superwhisper/id6471464415)
- [Top AI Dictation Tools for Mac 2026 (Medium / Mira Calder)](https://medium.com/@miracalder_93891/top-ai-dictation-tools-for-mac-in-2026-super-voice-mode-wispr-flow-and-superwhisper-compared-2b86295ffecc)
- [Best Mac Dictation Apps 2026 (Medium / Ryan Shrott)](https://medium.com/@ryanshrott/best-mac-dictation-apps-in-2026-dictaflow-wispr-flow-superwhisper-and-apple-dictation-compared-11911c671817)
- [MacWhisper vs Superwhisper (Voibe)](https://www.getvoibe.com/resources/macwhisper-vs-superwhisper/) · [MacWhisper Review (Dave Swift)](https://daveswift.com/macwhisper/) · [MacWhisper Pricing (Voibe)](https://www.getvoibe.com/resources/macwhisper-pricing/)
- [Wispr Flow Review (Spokenly)](https://spokenly.app/blog/wispr-flow-review) · [Wispr Flow Pricing (Voibe)](https://www.getvoibe.com/resources/wispr-flow-pricing/) · [Best Dictation Apps (Wispr)](https://wisprflow.ai/best-dictation-apps)
- [Aqua Voice vs Wispr Flow](https://aquavoice.com/vs/wispr-flow) · [Aqua Voice vs Willow vs Ottex](https://ottex.ai/compare/aqua-voice-vs-willow-voice) · [Willow Voice Review (Voibe)](https://www.getvoibe.com/resources/willow-voice-review/)
- [VoiceInk](https://tryvoiceink.com/) · [VoiceInk Review (Voibe)](https://www.getvoibe.com/resources/voiceink-review/) · [OpenWhispr vs VoiceInk](https://openwhispr.com/compare/voiceink) · [awesome-voice-typing](https://github.com/primaprashant/awesome-voice-typing)
- [Parakeet vs Whisper (Spokenly)](https://spokenly.app/blog/parakeet-vs-whisper) · [Parakeet V3 default Mac model (Whisper Notes)](https://whispernotes.app/blog/parakeet-v3-default-mac-model) · [4-engine shootout: Apple/Whisper/Parakeet/Qwen3 (Dictato)](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/)
- [Apple vs third-party dictation macOS Tahoe (Weesper)](https://weesperneonflow.ai/en/blog/2025-10-27-voice-dictation-macos-tahoe-native-features-third-party-apps-2025/) · [Dictation on Mac guide (Voibe)](https://www.getvoibe.com/resources/dictation-mac/)
