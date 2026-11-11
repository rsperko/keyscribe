# Audio capture

Read before changing microphone capture: the AUHAL unit, the realtime IO callback, the ring and writer thread, bring-up and readiness, the tail drain, or idle warm-up. A capture defect is inaudible because audio goes straight to speech recognition, so these rules are the only warning.

## Device pinning — never the system default input

**Capture pins the chosen device on a raw AUHAL unit — it NEVER changes the macOS system default
input.** Device-pinned capture goes through `HALInputUnit` (`kAudioUnitSubType_HALOutput`): set the
unit's `CurrentDevice`, read the device's **native** `StreamFormat`, then set the client format to
match it (Float32 non-interleaved at the device's own rate/channels) — matching the client format to
the device is exactly how the **-10868 (`kAudioUnitErr_FormatNotSupported`)** that plagued the old
`AVAudioEngine.inputNode` path is avoided, so there is no reason to touch the global default. The prior
implementation temporarily flipped `kAudioHardwarePropertyDefaultInputDevice` to dodge -10868; that is
a confirmed antipattern (every reputable recorder pins the device instance-locally; AudioKit shipped
and then removed a default-flip as a bug) and it caused a user-visible side effect (every dictation
briefly hijacked the system mic) plus intermittent `preferredInputFailed`. **Do not reintroduce any
`setSystemDefaultInput` call on the capture path** — that function survives ONLY for the legacy
crash-reconcile that undoes a default a pre-AUHAL build may have stranded. A **present** preferred
device that fails to bring up surfaces `preferredInputFailed` (don't silently record from a different
mic); a default-follow failure retries once after 250 ms, then `formatUnavailable`.

## Tail drain on commit

**Commit-on-release drains the tail before stopping — do not revert to an immediate stop.** The AUHAL
IO proc delivers a buffer once per hardware period, so at release the in-progress period holding the
final word is undelivered; tearing the unit down right then clips it. `handleCommit` flips the HUD to
*transcribing* and then `await`s `AudioCapture.finishDraining()`, which keeps the unit running until a
delivered buffer's host time (`inTimeStamp.mHostTime`) covers the release instant (`TailDrainGate`,
with a buffer-count fallback for invalid timestamps and a 300 ms backstop), and only then tears it down
(`teardownAndFinalize`, which `stop()`s a non-Bluetooth unit but **disposes** a Bluetooth one to free
HFP, then joins the writer thread and closes the WAV — in that order — so no in-flight write races the
finalize). **`stop()` is the immediate, audio-discarding teardown** (disposes the unit) — keep it for
`cancel()` only; the commit path must use `finishDraining()` — and that includes reaching the recording
limit, which commits the take like a release and never discards it (`docs/development/design.md` §4.8). `stop()` also force-resumes
any pending drain so a direct stop never strands the awaiter. The `wav … drain=Xms` `DictationController` debug log reports
the actual flush time (≈300 ms means the backstop fired). Don't reorder the HUD flip after the await —
the drain latency must stay invisible.

## Realtime IO callback, ring, and writer thread

**The realtime IO callback is lock-free / allocation-free / syscall-free — never add file I/O, a lock, a
`Task`, or a continuation resume to it.** The AUHAL render callback runs on CoreAudio's realtime IO thread;
anything that can block there (a disk stall, a lock the main actor also holds, a `Task` allocation) overruns
the device IO cycle → dropped input (audibly missing words) and can glitch the device for other clients. The
RT handler (`AudioCapture.handle`) does ONLY three bounded things: gate on the `capturing` atomic, copy the
delivered frames into a preallocated lock-free SPSC ring (`AudioSampleRing`, KeyScribeKit), and publish the
perceptual level into an atomic (`vDSP_rmsqv`, a Float bit pattern). Everything heavy — resampling
(`AVAudioConverter`), the `AVAudioFile` write, and feeding the `TailDrainGate` — runs on a dedicated writer
thread (`CaptureWriter`) that polls the ring off-RT (5 ms tick, no wakeup is EVER signalled from the RT
thread). The HUD meter is **pulled** at ~30 Hz (`DictationController` polls `AudioCapture.currentLevel`), not
pushed per buffer — there is no per-buffer main-actor hop.

**Multichannel input is collapsed to ONE channel on the writer thread, before resampling** (`ChannelSelector`,
KeyScribeKit). A default `AVAudioConverter` keeps channel 0 only, which silenced a mic on any other input;
averaging attenuates a lone mic and summing clips duplicates. A challenger must beat the recorded channel's held
peak by `defaultSwitchMarginDB` for `defaultSwitchSustainSeconds`, but a channel earns that held peak (pause
protection, decaying over `peakHoldDecaySeconds`) only from a level that lasted the longer `holdQualifySeconds` —
so a click or a brief bump on an unused input can win a moment of the take, never keep it. The selector restarts whenever the delivering device changes: each ring slot
carries `sourceID` (the unit's bound device, published in `configure` before start), which is race-free where a
control-side reset would let the old unit's queued frames feed the new choice. The RT meter follows the writer's
published channel through one atomic, and multichannel teardown lines gain `channels=… selected=… switches=…
peak=[…] switch=[…]`.

The ring is **bound to the unit that writes it**
(`HALInputUnit.ringSlot`, captured immutably by that unit's RT handler) and a FRESH one is ALLOCATED per
capture in the quiescent arm window — never reset in place and never reachable through a mutable
`AudioCapture` property. Both halves are load-bearing and neither suffices alone: the RT callback passes its
gate and can then resume arbitrarily late, so reading a shared mutable `ring` let a stale generation's buffer
land in the successor's recording (KS-05); and since a matching geometry used to be reset in place, the
abandoned generation's ring WAS the successor's object, so per-unit binding without per-arm allocation would
have changed nothing. Allocating per arm costs one bounded control-queue malloc (~2 MiB baseline) and makes a
stray write land in a ring nothing will ever read. `armSync`
sizes `slotCount` to target ~30 ms of headroom for the device's actual period (`AudioSampleRing.geometry`,
clamped to ≤64 slots but always above one writer poll tick), so a small pro-interface buffer can't starve the
ring below a poll tick. **The arm order is load-bearing for this: `armSync` CONFIGURES the unit first
(`configureCaptureDevice` — bind + initialize, including the default-follow retry, but the IOProc is NOT
started), so the device that will actually deliver is known BEFORE the ring is sized; then it sizes the ring
for that bound device, starts the writer (BEFORE publishing the session/`lastWriter`, so no teardown path can
observe a published-but-not-yet-started writer and skip joining its thread), sets `capturing=true`, and calls
`startConfiguredUnit` LAST — so the first delivered buffer already lands in a correctly-sized ring with no head
clip, and a retry that rebinds a different device cannot leave the ring mis-sized.** The ring is published into
the unit's slot inside the SAME generation-checked critical section that publishes the session, and the RT
thread sees it via the `capturing.store(true, .releasing)` its acquire load pairs with; the unit is not started
yet, so its handler cannot be reading the slot. A slot is written only at that arm and at the
mid-recording restart, which SEEDS the replacement unit's slot with the SAME `session.ring` (before
`fresh.start()`), because a fresh ring there would strand the frames the outgoing unit queued. Never write a
slot a started unit can read. The previous capture's writer is JOINED
(`CaptureWriter.finish`, multi-waiter via a `DispatchGroup`) before the next arm, so
a cancel's async teardown can never race a still-draining consumer. On
commit, `finishDraining` awaits the writer join before returning the URL, and the writer drops its `AVAudioFile`
reference on exit so the session's is the last one — the WAV is finalized/closed before transcription reads it.
Teardown ordering is load-bearing: `capturing` → false (RT stops pushing, which SEVERS RT→ring→writer→file),
`writer.finish` (drains remaining + flushes the resampler tail + joins), release the file (WAV closed —
before the unit stop, so a wedged unit stop can't return an open file to transcription), then stop/dispose
the unit. Because a capture defect here is INAUDIBLE (audio goes straight to STT), validate with
**`KeyScribe --capture-probe`** (drives the real capture path over a known tone and scores glitches/SINAD),
the teardown `Log.audio` line `ringDropped=N overloads=M writerDropped=K oversizeDropped=J` (all must be 0 —
the writer-keep-up, CoreAudio-RT-deadline, downstream WAV-write/converter, and RT IO-period-growth canaries;
`writerDropped` counts frames the writer accepted off the ring but failed to persist, e.g. a disk-full or
odd-format-converter failure that is invisible to the ring counters; `oversizeDropped` counts frames the RT
callback dropped because the device grew its IO period past scratch mid-capture — upstream of the ring, so
invisible to `ringDropped`, and now watched for recovery via a `BufferFrameSize` restart), and
`KEYSCRIBE_KEEP_CAPTURE=<dir>` to retain WAVs for offline inspection — or `[audio] keep_captures` in
`settings.toml` for a persistent per-variant archive under `<support-dir>-captures/`, bounded by
`keep_captures_max_mb` (a SOFT budget — oldest pruned first, newest always kept even if it alone
exceeds it; the env var's directory is never pruned and wins when both are set). The archive is a
`COPYFILE_CLONE_FORCE`, not a copy: it sits inline on the commit path the pipeline awaits before
transcribing, so it must stay metadata-only — never reintroduce a plain `FileManager.copyItem` as the
primary path, and keep the prune on its own queue. The clone-impossible fallback still copies (loudly)
rather than skipping, because `--capture-probe` deletes its working file trusting the archive. The
archive lives OUTSIDE `supportDir` so a WAV can't fire `ConfigWatcher` — which means every wipe path
misses it by default, so `ResetTool.eraseAll` deletes it explicitly (it is raw speech).

## Bring-up, readiness, and teardown

**HAL unit bring-up/teardown run off the main thread on a serial queue, watchdogged — never move them
back onto `@MainActor`.** `AudioUnitInitialize`/`AudioOutputUnitStart`/`Stop`/`AudioComponentInstanceDispose`
can block for a long time (or indefinitely) on a transitioning device — classically a Bluetooth headset
forced from A2DP into HFP the moment capture opens an input stream — and doing that on the main thread
froze the whole app *and* (via the event tap) global input. `AudioCapture` confines every `HALInputUnit`
control call to a private serial `controlQueue`; `start()` is `async` and bounded by a watchdog
(`runWithBudget`). **`start()` resolves on READINESS — the input's first valid buffer — not on the
AudioUnit start call returning**: bind/initialize/start can all succeed on a route that never delivers audio,
so a start return proves nothing. Readiness is observed on the **writer thread**
(`CaptureWriter.onFirstBuffer` → `SignalLatch`), and **never signalled from the RT callback**. `AudioCapture.awaitReadiness` releases its wait on cancellation (the deadline ABANDONS the
operation, so an unsignalled latch would strand the continuation) and therefore MUST keep its
`Task.checkCancellation()`: without it a released wait can return success and beat the timer to
`runWithBudget`'s one-shot gate, reporting a ready mic that never delivered a buffer. **Capture records from
its first buffer, and the start cue stays in the recording.** The cue is the go-signal, so it may not sound
until the route is proven live; it then plays into the open mic. Do not cut it back out: when speech overlaps
the cue, cutting its window also cuts the speech under it, which costs more words than the cue does, and when
speech follows the cue the cue costs about nothing (`corpus/stt` with the cue mixed in, 2026-11-11: first word
right, parakeet-ultra, of 107 — original 101, cue over the word 99, cue window silenced 88, cue before the
speech 101; the no-speech gate still suppressed every `corpus/blips` empty press with a bare cue). That holds
for the bundled tone; a cue with speech-like sound in it would be transcribed. For a modifier-only trigger the mic
starts at the key-down, during the chord grace (`DictationController.handleEngage`), except on a Bluetooth input
(`AudioCapturing.inputIsBluetooth`): opening it forces A2DP→HFP, and AirPods audibly dropped and returned on every
Option-chord when it did (2026-11-11); a press that turns into
a chord stops it with no cue and no HUD (`handleEngageDropped`), and one never confirmed is stopped by
`pressConfirmationBackstop`. The macOS mic indicator therefore lights briefly on such a press; that is the
accepted cost.
**One extensible `ReadinessBudget` bounds the WHOLE operation** — configure, start, and the wait for a
buffer — since any of them can be the slow step on a transitioning route: `bringUpTimeout` (2 s) **plus**
`bringUpGrace` (2 s) for local devices, `bluetoothReadyTimeout` (9 s) for Bluetooth, whose A2DP→HFP
negotiation can outrun the 4 s window and surface as a spurious "Could not start the microphone" (observed
once as two failures then a success on the third trigger; the exact route state during the failures was
never established). **The budget must not stay fixed at the initial target**:
the delivering device can change after it is sized — a failed default bind re-reads the system default, and
an arming-time restart can rebind (the session is published before readiness, so topology changes act on it).
`selectRoute` RAISES the budget as each route is CHOSEN — before the configure/start it pays for, since that
call is itself what blocks, and the latch is one-shot so a budget that already expired cannot be recovered.
It never lowers. Repeated churn cannot wait forever because the window is measured from ONE origin (the
timer arming inside `runWithBudget`), not restarted per raise — so the total wait is bounded by the slowest
transport's value however many times a route is reselected. There is deliberately no separate clamp: it
would be unreachable over the transports that exist. A transport slower than Bluetooth raises that ceiling
by construction — decide then whether an absolute cap is wanted, rather than carrying a dead one now.
Drop the raise and a local target that rebinds onto Bluetooth inherits the 4 s cliff: the
original bug, one route change removed. Policy label and diagnostics likewise key off ONE `captureTarget()`
resolution threaded into `armSync` (sampling transport separately from the bind also mislabels a
disconnected preference as `explicit`). The watchdog is **non-destructive**: it **adopts** a bring-up
landing anywhere in the window rather than discarding it — a resident unit whose cached binding went stale
over idle can need ~2 s to re-realize the input unit on the hot path, and a tight 2 s watchdog used to throw
that late success on the floor. Only after the budget is spent (a genuinely wedged or never-delivering
device) does it abandon the call on its (now-orphaned) queue and let the next dictation rebuild a fresh unit
+ queue — so the healthy path keeps reusing the prewarmed unit (no fresh build per dictation) and a true
wedge degrades to a graceful "Could not start the microphone" instead of a hang. Waiting cannot reintroduce
the freeze — bring-up is off-main, so the main actor only `await`s. (`prewarm` keeps the tight `bringUpTimeout` — it configures/initializes the unit but does
NOT start the IOProc, so the mic indicator never lights; it is skipped for Bluetooth so idle never forces
HFP.) A complementary idle/wake **binding refresh** attacks the same staleness proactively:
`refreshBinding()` rebuilds + re-prewarms the idle unit, driven by `DictationController` on a ~4 min idle
timer and by an `NSWorkspace.didWakeNotification` observer. **All of this idle mic warm-up is gated on the
`Eviction` performance tier (`settings.stt.eviction`) via `EvictionPolicy` — the same dial that governs STT
model residency**: only `.fastest` runs the ~4 min periodic refresh (`periodicallyRefreshesCapture`);
`.frugal` never prewarms at all (`shouldPrewarmCapture` false → mic opened only on the trigger's `start()`,
paying the cold realization the grace window absorbs); `.balanced` prewarms around use but drops the periodic
refresh and disposes the warm unit at the model's idle-eviction checkpoint (`releaseWarm()`, gated by
`releasesWarmCaptureOnIdle`). This exists because the periodic dispose→re-init cycle is observable to
mic-usage monitors as a repeated grab/release; Balanced/Frugal exist for coexistence with mic-sensitive apps.
To diagnose the next occurrence rather than
infer it, `start()` emits ONE structured record per capture start on the `audio` category
(`CaptureStartRecord`; `Log.audio`, `.info` when ready, `.debug` when cancelled, `.error` on a terminal
failure): `capture-start outcome=ready|never-ready|cancelled|failed policy=explicit|default
transport=bluetooth|other bound-transport=… target=… bound=… configure=…ms start-returned=…ms
first-buffer=…ms events=[…]`. A healthy
prewarmed start is a few ms to first buffer; the gap between `start-returned` and `first-buffer` is the
route actually opening. **Group by the transport that DELIVERED — `bound-transport` when present, else
`transport`**: they differ when a rebind moved the route, and grouping on `transport` alone files a capture
that delivered over Bluetooth under `other`. `bound`/`bound-transport` are frozen at the first buffer on a
`ready` outcome, so a restart landing just after readiness cannot re-file that timing under a device which
never delivered it. Timings are from `start()`, **not** from the trigger (the press pays the chord grace
first; `DictationController` starts capture in a detached task so the secure-field probe and mode
resolution run alongside it) — trigger-to-recording is `DictationRecord.stageMillis[.arm]`.
Subject to the `log show` unreliability footgun (`AGENTS.md`, *Toolchain*) — capture it live via `log stream --predicate
'category == "audio"'`. A disposed unit's render callback cannot fire (`AudioOutputUnitStop` is synchronous), and a
stray late buffer is a no-op because the RT handler guards on the `capturing` atomic (set false at teardown
before the unit is stopped). Because bring-up is async, `handleCommit` before `captureStarted` cancels the not-yet-live attempt rather
than queueing a commit against audio that was not recording yet. Idle HAL listeners on the default-input
device (`kAudioHardwarePropertyDefaultInputDevice`) and the device list re-prewarm on a device change while idle;
**while recording**, raw AUHAL posts no `AVAudioEngineConfigurationChange`, so a per-capture listener on
the BOUND device (`DeviceIsAlive` + `NominalSampleRate` + `BufferFrameSize`, for disconnect, a Bluetooth
A2DP↔HFP flip, and a mid-capture IO-period growth past scratch) restarts capture into the same file on the
control queue, bounded by `maxConfigRestarts`.
