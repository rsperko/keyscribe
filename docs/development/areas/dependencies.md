# Pinned and forked dependencies

Read before bumping, re-pinning, or replacing any SwiftPM dependency, or when a fresh checkout fails to resolve while a warm build succeeds.

The STT deps, and which of them is forked; the fork works live and costs nothing day-to-day.

## WhisperKit

**WhisperKit** → `argmaxinc/argmax-oss-swift` (upstream, **no fork**), pinned `exact:` in `Package.swift`.
**1.1.0 is a hard floor, not a preference** — through 1.0.0, a prediction sampled while prompt
tokens were still being force-fed could complete the segment, so *every* stock release emptied the
transcript whenever `promptTokens` were set (#372), which is exactly how Whisper bias is
implemented (`WhisperEngine.promptTokens`). KeyScribe carried a one-commit fork (`!isPrefill` on
the `isSegmentCompleted` break) until upstream fixed it in 1.1.0 — `TextDecoder.swift` now guards
`(sampleResult.completed && !isPrefill)` and derives `isFirstToken` from
`max(0, initialPromptIndex - 1)`. The fork is retired (2026-08-09); **never bump this dependency
below 1.1.0**, and re-run the bias benchmark on any bump, since the failure is silent (empty
transcripts, not an error). The pin is `exact:` deliberately: this dep carries decoder behavior and
a silent minor bump can change transcription. Depending on just the `WhisperKit` product keeps
Vapor/openapi out of resolution (gated behind `BUILD_ALL`).

## FluidAudio and the pinned VAD artifact

**FluidAudio** → `FluidInference/FluidAudio` (upstream, **no fork**): provides Parakeet TDT
transcription. Historical: KeyScribe once paired it with FluidAudio's **CTC-WS** keyword spotter
(NeMo constrained-CTC) for Parakeet recognition bias, gated by `spotterRescueEnabled`. That spotter
was **removed** (2026-07-09) — it false-fired a dictionary term into a majority of ordinary
sentences; Parakeet now transcribes **TDT-only** and ignores
`biasTerms` (`supportsRecognitionBias = false`), with the companion CTC download and disk footprint
gone. Re-measured 2026-10-19 on 0.17.7 (rescue off, short-term controls, and the non-mutating
candidate-evidence API included): unchanged — see the recognition-bias gate in `stt-engines.md`. It also supplies Parakeet Unified through a DIFFERENT manager (`UnifiedAsrManager`, not
`AsrModels`) — see `stt-engines.md`. FluidAudio is the only dep that supplies BOTH Parakeet
and the Silero VAD behind the no-speech gate, so **a bump moves the gate unless the VAD artifact is
pinned separately — which it now is.**
**The root cause is known and confirmed, so this is no longer a mystery to re-litigate.** 0.15.5's
blips regression (2026-08-13: `--vad-probe corpus/blips` PASS 23/23 → FAIL 2/23, `blip_breath_03`
and `dbl_gap15` flipping noSpeech→speech) was **not** an SDK logic change: it was
[PR #734](https://github.com/FluidInference/FluidAudio/pull/734), a **one-line swap of the Silero
CoreML artifact** v6.0.0 → v6.2.1, with no threshold or config change anywhere. Upstream tuned
v6.2.1 recall-first at their ~0.85 threshold (+2pp accuracy, recall pinned at 100%); KeyScribe reads
raw probabilities at **0.30**, deep in a tail upstream never optimizes, where "more eager to call
marginal audio speech" is precisely wrong for a suppression gate.
**Resolution (2026-09-09): the SDK is bumped to `4dbf4f9` (v0.15.6) and the ARTIFACT is pinned
instead** — `VADModel.pinnedArtifact` in `SpeechPresenceDetector.swift` names
`silero-vad-unified-256ms-v6.0.0.mlmodelc` explicitly. `ModelHub.loadModels` unions caller-supplied
names beyond the repo's required set, so naming the older artifact works even though the SDK now
defaults to v6.2.1; both files coexist in `models/silero-vad/` at ~1 MB each. Verified: blips and
commands both PASS unchanged (identical 13/11 split, identical 0.675 margin), STT byte-identical,
full suite green. Verified the pin is LOAD-BEARING, not coincidental: flipping only that string to
v6.2.1 on the same SDK reproduces **FAIL 2/23 on exactly `blip_breath_03` and `dbl_gap15`**.
Consequence: KeyScribe now depends on a file upstream no longer advertises. If it were deleted the
VAD model would fail to download and the gate **fails open** — silently. `make check-deps` now
watches for that (a hard failure); nothing else would notice.
0.15.5 also renamed the download API (`DownloadUtils` → `ModelHub`, `refactor(download)!` #779);
that migration is done (`ProgressHandler` is now top-level; `ModelHub.loadModels`).
**Still true and still unbounded:** raising `minSpeechChunks` remains the one move no evidence here
supports — per `corpus/blips/README.md` the fast-release twins must be recorded FIRST. The artifact
pin exists precisely so that a future SDK bump does not force that question.

### The spoken result voice (Kokoro) — re-check on every FluidAudio bump

FluidAudio also supplies the Kokoro voice behind the Coding agent spoken result (`KokoroVoice`). It
cannot tell us these at runtime, so a bump re-checks them by hand:

- **Which speakers to offer.** `SpokenVoices.all` is a hand-kept list: only English speakers that
  Kokoro's author grades **C+ or better** in
  [VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md). The download carries no
  names or grades, so nothing derives the list. On a bump, compare FluidAudio's
  `KokoroAneConstants.englishVoices` and its Kokoro model version against the last bump; if either moved,
  re-read the grades, update `SpokenVoices.all`, and re-measure the installed size behind
  `SpokenVoiceModel.approxDownloadBytes`. A dropped speaker needs no migration: `SpokenVoices.resolved`
  sends it to the recommended one.
- **That dependency logs stay content-free.** FluidAudio's phonemizer logs the words it fails on at
  warning level, so `DependencyLogging.configure()` drops every FluidAudio message below error, from the
  console and the system log alike, for every FluidAudio engine, not only the voice. `KokoroVoiceTests` sets
  that process-wide state too, to the same values the app uses. On a bump, grep its error- and fault-level log calls for
  interpolated text (the input, a word, a transcript); one that appears breaks the no-content-logging
  rule and needs a stricter floor.
- **That repeat takes still match, on each route.** `KeyScribe --voice-sweep <lines.txt>` makes every line
  several times and reports each take's similarity to the first, with `--route gpu|cpu` choosing where
  FluidAudio's noise and tail stages run (its default depends on the OS: `KokoroVoice.route` names the one in
  use, and the spoken-audio report records it), `--overlap` and `--stop-first` for the concurrency windows.
  Each take after the first also reports whether its samples are identical to the first take's. As measured
  2026-11-10 on macOS 27 (Apple silicon), over two short sentences, repeat takes were sample-for-sample identical on
  both routes, including takes made at the same time (`--overlap`); takes after a stop matched to a similarity
  rounded to 1.000, measured before identity was reported. That says nothing about
  macOS 26.x, where the default route differs and the CoreML compiler is different: a garbled reply reported there
  needs the sweep run on that OS, with `--route gpu`, before anything is concluded. Keep private reply text out of
  committed files. A route change ships only after a sweep and a soak on the OS it targets.
- **That loading an installed voice still downloads nothing.** `KokoroVoice.isIntact` keeps a missing file
  from being fetched, but loading also runs FluidAudio's cache migration, which re-downloads any model bundle
  its compatibility check rejects. A bump that changes that check turns into a silent download at launch,
  breaking PRIVACY's "only when you choose Download". On a bump, install the voice on the old pin, move to
  the new one, and confirm `KokoroAneModelCompatibility.existingBundlesRequiringMigration` returns nothing
  for it; if it does not, mark the voice Needs attention before loading.

## speech-swift (Qwen3-ASR) fork

**speech-swift (Qwen3-ASR)** → `rsperko/speech-swift` (upstream `soniqo/speech-swift`, package
`Qwen3Speech`): the fork is **one commit** — it gates the `AsrBenchmark`/`AudioServer` targets behind
`BUILD_ALL` so stock speech-swift's unconditional `argmaxinc/WhisperKit` dependency stays out of our
graph. Qwen3-ASR bias is **native** (`Qwen3DecodingOptions.context`), so no source patch is needed.
**Still required — re-verified 2026-08-13.** The commit message blames a collision with "our
WhisperKit fork", which is stale (that fork was retired 2026-08-09) and reads like the fork is now
droppable. It is not: `argmaxinc/WhisperKit` and `argmaxinc/argmax-oss-swift` are different package
*identities* that still share target *names*, so stock speech-swift + argmax-oss-swift RESOLVES fine
(37 packages, no conflict) and then fails graph loading with `multiple similar targets 'ArgmaxCLI',
'ArgmaxCore', 'ArgmaxOSS' and 3 others appear in package 'whisperkit' and 'argmax-oss-swift'`. Prove
it in ~2 min with a throwaway package depending on both, then `swift package show-dependencies` —
`swift package resolve` alone will NOT show the failure. Upstream has not adopted the gating.
**Do not chase upstream speech-swift casually either:** current upstream adds
`mlx-swift-lm` as `branch: "main"`, a floating dependency inside a notarized app. Retiring the fork
means upstreaming the patch (it no longer cherry-picks — upstream restructured the manifest).

## Upstream dependency mutation

**Upstream dependency mutation — a green local build proves nothing about a fresh checkout.** On
2026-08-13 moonshine-ai (whose engine KeyScribe has since dropped) **re-uploaded the `v0.1.2` release asset in place** (`Moonshine.xcframework.zip`,
`ae9074b2…` → `42311465…`) and then **moved the `v0.1.2` tag** (`26e0335a` → `2ff906a3`) so their
`binaryTarget` checksum matched the new bytes. Our `Package.resolved` still pinned the pre-move commit,
whose manifest declares the old checksum — so **every fresh checkout died at `swift package resolve`**
while every warm `.build` on a dev machine kept building happily. That asymmetry is the whole hazard:
this class of breakage is invisible locally and only ever reported by downstream.

- **Detect:** `make check-deps` (`scripts/check-binary-artifacts.py`) — for every pinned dep it compares
  the GitHub release API's per-asset `digest` against the checksum declared in that dep's **pinned**
  manifest, and separately flags a version tag that has moved off the pinned revision. **Download-free**
  (no ~1 GB xcframework fetch), so it is cheap enough to gate on: it runs as preflight's `a-deps`, in the
  fail-fast `--pre` set and in `REQ_CORE`. A mutated asset is a hard fail; a moved tag is a warning
  (the pin still builds — re-pin deliberately).
- **Prevent:** pin engine deps by **`revision:`**, never by version, when upstream has shown it will move
  a tag. A version pin resolves *through* a mutable tag; a revision names the commit outright.
- **Recover — and this is the step that surprises everyone:** pulling the corrected pin is **not enough**
  on any machine that already built. SwiftPM refuses to re-download while it holds a record of the old
  checksum, and its **global download cache is keyed by URL — which did not change — so it still serves
  the OLD bytes**:
  `error: artifact of binary target 'Moonshine' has changed checksum; this is a potential security risk
  so the new artifact won't be downloaded`. Three places must be cleared —
  `.build/artifacts/<identity>`, that identity's entry in `.build/workspace-state.json`, and
  `~/Library/Caches/org.swift.swiftpm/artifacts/<url-with-non-alphanumerics-underscored>`. Run
  **`make fix-deps`** (`scripts/clear-binary-artifact-cache.sh`; dry run by default, `--apply` to delete),
  then `swift package resolve`. **CI runners that cache `~/Library/Caches/org.swift.swiftpm` stay broken
  until that key is evicted** — clearing the repo checkout alone does nothing.
- **Footgun:** `swift package update <dep>` does **not** fix a stale pin whose version constraint is still
  satisfied — it left `26e0335a` in place. Edit the revision directly and re-resolve, and review
  `git diff Package.resolved` before committing: that file is also copied into the generated Xcode
  project on every build, so it is the only lockfile.

## MLX shader library

**MLX's Metal shader library is a hard runtime requirement, and Xcode builds it.** Qwen3-ASR (MLX)
crashes ("Failed to load the default metallib") without a compiled shader library. SwiftPM's **native**
build system does not compile `.metal` sources, which is why the app is built through the shared Xcode
app definition (`App/project.yml`, see `build-and-release.md`): Xcode compiles mlx-swift's ahead-of-time kernel set into
`Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, which MLX finds through its
SwiftPM-bundle lookup. **The Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) is required
for every build, and every shader failure is fatal.** `scripts/prepare-xcode-project.sh` compiles a
one-line kernel before generating the project — never `xcrun -f metal`, which finds Xcode 26's "missing
Metal Toolchain" stub whether or not the toolchain is installed — and `make-app.sh`/`release.sh` run
`KeyScribe --mlx-smoke` (a tiny MLX computation; it names a missing Metal device) on the built product
before it replaces the `.app`; preflight's `a-metallib` runs the same smoke on the notarized app. The
failure is uncatchable in-process (mlx-c `exit(-1)` / mlx-swift `fatalError`), so the smoke only ever
runs as a subprocess whose death is the signal. **Two settings must reach the PACKAGE targets and can only
get there from the command line or an `-xcconfig`** — `App/Config/Packages.xcconfig`, which every
xcodebuild invocation passes: `MTL_FAST_MATH=NO` (Xcode defaults Metal to fast math; MLX's own builds use
`-fno-fast-math`, and the shared definition matches them — transcripts were identical either way over the
spike's sample, so this is principle, not a measured difference) and `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
(FluidAudio does not build for x86_64, and a project-level `ARCHS` in `project.yml` does not apply to
packages). A bare `swift build` still produces `.build/release/KeyScribe` for fast iteration and the
DevCLI flags, but it has NO shader library, so Qwen3 crashes from it; use the `.app`'s binary for anything
MLX. `make test` and preflight's `a-swift-test` still pin `--build-system native` through
`scripts/swiftpm-build-system.sh`; moving tests to `swiftbuild` is a separate follow-up.
