# Hotkeys, triggers, and permissions

Read before changing trigger matching, Carbon chords, the event taps, keyboard-layout resolution, shortcut conflicts and shadowing, context-aware claiming, or anything that reads or requests a TCC permission.

## Permissions

- **Permissions = Accessibility + Automation (+ Microphone). Input Monitoring is NOT used.**
  Accessibility covers post ⌘V/⌘C + AX reads **and** the modifier-only trigger event tap;
  Automation is browser URL and tabs via AppleScript (requested only when a mode opts into URL context, or
  Voice Commands reads or focuses a browser tab), and selecting a coding agent's tab in a scripted terminal
  (requested only on the first Open into that terminal — the scriptable terminals are the
  `TerminalRoute`s in `TerminalRoutes` whose Open runs a script). Open also reads other processes' environment through
  `KERN_PROCARGS2` (`SystemTerminalFacts`), which needs no permission; it keeps only the variables in
  `TerminalRoutes.environmentKeys`, never the rest of an environment;
  Microphone is capture.

## The hotkey mechanism

**The hotkey mechanism is split by trigger type, and no path needs Input Monitoring**
(`HotkeyMonitor` + `CarbonHotKeys`):

## Modifier-only triggers


### Matching

**Modifier-only triggers** (any 1–4 modifiers, each optionally sided: `fn`, `right_option`,
`left_command`, `left_command+left_control`, `control+option+shift+command`) → a `.listenOnly`
`CGEventTap` watching `.flagsChanged`, `.keyDown`, the three `*MouseDown`s and `.scrollWheel`.
**There is ONE matcher, not a case per named key** (`ModifierMatcher` + `resolveModifierSet`): `hyper`
and the legacy per-key spellings are parse aliases in the grammar, never code paths, and `NamedKey` is gone.
Three rules carry it, and each is load-bearing:
(a) **Engaged = an EXACT match of the NORMALIZED flags** — the four generic bits compared bit for bit,
Fn matched on presence, and every sided member's `NX_DEVICE{L,R}…KEYMASK` bit set **with the opposite
side's bit CLEAR**. Normalizing is not tidiness: `CGEventFlags` also carries Caps Lock
(`maskAlphaShift`), numeric-pad and non-coalesced bits, so comparing raw flags kills every trigger for
as long as the Caps Lock light is on. Exactness is what makes "chord wins" fall out for free — any
foreign modifier disengages the set. The opposite-side-clear half is what makes `left_command` and
`right_command` two usable triggers instead of two dictations whenever both ⌘ keys are held.
The recorder's counterpart rule: **it records the keys actually pressed, sides and all**
(`ShortcutCaptureModel.modifierEvent`) — a recorded trigger binds those keys. Two costs were weighed
and ACCEPTED (product call, 2026-09-09), so do not "fix" them by dropping sides: an all-left ⌃⌥⇧⌘
stops firing the moment the user reaches for the right ⇧, and it reads as "Custom" in the well
instead of matching the sideless Hyper the menu offers. The sideless spelling stays reachable by
hand-editing the mode's file.
**This must stay in lockstep with `ModifierKeySet.canEngageTogether`, which `collides` uses** — and
`collides` is not cosmetic: `AppDelegate.shadowedHotkeyIds` SUPPRESSES the loser at bind time, so a
pair the conflict check calls distinct while the matcher engages both is a live double-fire.
Masking (`isMasked(by:)`) shares the same side-compatibility rule.

### Shadowing, reachability, and context-aware claiming

**Shadowing is context-BLIND, and that is a real gap, not a nit.** It drops a whole binding, and
`ModeResolver.resolvePhaseA` then routes by the surviving binding's trigger STRING — so a mode whose
trigger merely *overlaps* the winner's is unreachable even where context would have chosen it.
Two mitigations covering different halves: `normalizeKey` compares `descriptor.canonical`, so two
SPELLINGS of one descriptor (`hyper` vs the expanded form) route identically and shadowing is
harmless; and `TriggerKeyConflicts` reports `.unreachable` for descriptors that collide with a
DIFFERENT canonical form (`command` vs `right_command`). It still **ignores `canContend`** — that
answers "can two REGISTERED modes contend for one press", which context routing can settle, and a
binding that was never registered is past saving. What it does honor is
`shadowsWhereverItRuns`: since **registration itself is now context-aware** (below), a claimant
absent outside its own apps cannot make a later mode unreachable *everywhere*, only inside those
apps. Note the asymmetry — an UNCONSTRAINED claimant is registered everywhere, so it does shadow a
scoped mode outright; do NOT substitute `canContend` here, which calls that pair separable and
would drop the warning. **`.unreachable` is ORDERED, like the shadowing it
predicts**: `shadowed` keeps the FIRST registrant, so only a mode with an EARLIER colliding trigger is
reported (`claimedEarlier`). Asking symmetrically put "Shortcut never fires" on the mode that fires.
**Collision is NOT transitive** — `right_command` ~ `command` ~ `left_command`, yet the two sided
ones can never both engage — so `shadowed` appends to `claimed` ONLY on a successful claim, and
`claimedEarlier` replays that same rule — but replays it **context-aware, in two halves that are
only correct together**. (a) A binding is dropped from `claimed` only by a winner that
`shadowsWhereverItRuns` it: since `shadowed` is computed per-app over the claimable set, a binding
that loses inside one scoped claimant's apps is still the first registrant everywhere that claimant
is absent, and it is THAT binding — not the scoped winner — that can leave a later mode dead (drop it
and a TextEdit-scoped `command` + unconstrained `command` + Notes-scoped `right_command` reports
nothing, though the third never fires). (b) A binding RETAINED that way carries its `contesters`, and
may only be blamed when NO contester's bundle scope intersects the victim's
(`bundleScopesIntersect`) — because it claims only where the winner that beat it is absent. Keep (a)
without (b) and the reverse error appears: `right_command`-in-app-A, global `command`,
`left_command`-in-app-A wrongly reports the third dead, when in app A the first takes `right_command`
out of its way and it fires. **The model tracks each claimant's DECLARED scope, never the union of
effective ones**, so a mode killed by different claimants in different apps is deliberately NOT
reported (pinned by `aModeKilledByDifferentClaimantsInDifferentAppsIsNotReported`). Under-reporting
is the safe direction — a false "Shortcut never fires" lights the menu-bar error badge on a mode that
works. Closing it needs effective claiming scopes (scope minus the earlier claimants that beat it),
which belongs with the single-event arbitration rework below, not a patch here. Treat a losing binding as a claimant and it suppresses a
later one that would have worked fine (measured: right/either/left ⌘ left only Right-⌘ registered).
**`.unreachable` answers "can this MODE fire", not "is every binding live"** — it holds only when
EVERY trigger the mode has was claimed earlier, because the Modes list says "Shortcut never fires" and
the badge lights. A mode keeping one live trigger beside a shadowed one still fires, so it is not
flagged; its dead trigger gets `.triggerUnreachable` instead — a red caption naming that key in the
editor, deliberately kept OUT of `hasUnreachableTrigger` so the badge still means "the whole mode is
dead". The Settings well edits the first entry and preserves the rest; further entries are TOML-only
and surfaced as a read-only "Also starts with" note in the editor. A later entry that is the same
press as an earlier entry of the SAME mode is dropped at runtime, and
`TriggerKeyConflicts.parsedTriggers` mirrors that so the note reports it and every summary omits
it. **Registrant ids are positional** (`HotkeyConflicts.registrantId`): keyed by key text, a
repeated entry shared its id with the one it repeats, and suppressing the copy dropped both.
**Constraints gate CLAIMING, not just running** (`ModeResolver.canClaimKey`, `AppDelegate.claimableModes`).
A trigger belonging only to modes whose bundle constraints rule out the frontmost app is left
unregistered there, rebuilt from an `NSWorkspace.didActivateApplicationNotification` observer through
the same `rebuildHotkeyMonitor` busy-deferral. This is not cosmetic: a Carbon chord is **suppressed
from the focused app**, and a bound mouse button is swallowed outright, so a scoped mode used to
break its key in every OTHER app. **One claimable set must feed BOTH `shadowedHotkeyIds` and the
bindings** — filter only the bindings and a mode that is no longer registered still claims the press
in `shadowed`, leaving the key with NO binding rather than the surviving one. Only bundle fields can
gate: `url_pattern`/`window_title` need a probe, so such a mode keeps its key claimed everywhere.
The observer diffs the claimable set before rebuilding, because a rebuild re-registers every Carbon
hot key and most app switches change nothing. `SettingsProblem.hotkeyConflict` deliberately passes
**every enabled mode**, not the claimable set — it describes the CONFIG, and would otherwise blink as
the user switches apps. This partially closes the context-blind gap above (bundle-scoped modes on
overlapping keys now coexist); it does NOT close it for URL/title-scoped modes, and single-event
arbitration is still the real fix and still unbuilt.
**`canClaimKey` also gates the PRESS-TIME probe decision**, not just registration
(`DictationController.probeCandidates`): the `requiresURLContext`/`requiresWindowTitleContext`
deferral gate asks over the modes the captured bundle cannot already rule out. Ask over every mode
and ONE url-scoped mode anywhere in the config forces EVERY press onto the deferred path — so a
mode scoped to a browser AND a site pays a mic + start cue + cancel in apps its bundle alone
settles. The mic opens before ANY mode is resolved (`handleStart` calls `beginCapture` first, and
the press probe and resolution run while it comes up), so an unclaimed press always costs a brief
mic open; it stays SILENT only while the start cue has not played (`effectsBegan`), which a
deferred probe can outlast. Both
gates must keep using the same predicate or they drift into a key that is claimed but never probed
(or the reverse). `bundleScope` mirrors it too: **`bundle_id` is read BEFORE `bundle_prefix`**,
because a constraint ANDs its fields — reading the prefix widens a claimant to every sibling bundle
it can never run in and puts "Shortcut never fires" on a mode that fires.
This makes mode ORDER load-bearing for the warning, so whatever list is handed to
`TriggerKeyConflicts` must be in registration order — `config.modes` in `AppDelegate`, and
`ModesSettingsModel.modes`, which is the store's order unsorted. Never sort a list on its way in.
That `.unreachable` verdict is a red FAILURE, not
an advisory, so it propagates the whole way — `TriggerKeyConflicts.hasUnreachableTrigger` feeds
`SettingsProblem.modeTriggerUnreachable` → the Modes pane dot and the menu-bar error badge, plus a
`ModeSummaryIssue` row in the Modes list; the trigger row alone hides it behind a selection.
The real fix is single-event arbitration keeping
every candidate trigger key for Phase A instead of deleting a binding — NOT built; do that before
adding any feature that makes overlapping sets easy to create from the UI.

### Arming and disengaging

(b) **Arming keys off the TRANSITION into engagement** (`Binding.engaged`), never off "currently
engaged". `abort` deliberately does NOT clear `engaged` (it mirrors the flags); `suppressedUntilRelease`
is what bars a re-arm, and it lifts only when NO member is down. **It is also set straight from the
flags** whenever a member is down, the set is not engaged, and a foreign modifier is present — a member
pressed BESIDE a foreign modifier is spent until fully released. Without that, the foreign modifier's
*release* leaves the set alone and reads as a fresh engage: ⇧⌘4 then lifting ⇧ starts a dictation on a
`left_command` trigger, and on hold-or-tap the ⌘ release latches a mic the user never saw open. Nothing
armed in that sequence, so no abort ran — the abort path alone cannot cover it. A pair is unaffected
because ⌘-then-⌃ has no foreign modifier at any point. **"Foreign" includes the OPPOSITE key of a
sided member** — right ⌘ held beside a `left_command` binding — or releasing it leaves the left ⌘
looking freshly pressed and arms a dictation nobody triggered.
(c) **Disengaging splits on whether the set is still WHOLLY held** (`allMembersDown`): every member
still down ⇒ something foreign joined ⇒ abort; a member lifted ⇒ the user let go ⇒ commit. Get this
backwards and a pair trigger aborts on its own staggered release instead of committing.

### Chord wins: the grace window and the aborts

**"Chord wins" then applies to every modifier-only trigger** in two layers, because the user's own
mappings (fn+delete, fn+←, a ⌃⌥⇧⌘ chord, ⌘-click) must reach the focused app rather than being swallowed
by the recording HUD's key focus. (1) **The chord grace** (`HotkeyMonitor.chordGraceSeconds`, 150 ms): a
modifier-only `.down` is
held back, and a keyDown (or a foreign modifier) arriving inside the window discards the pending arm
**silently** — `onStart` never fires, so there is no mic, no cue, and nothing to cancel. This is the
layer that matters: arming is *not* cheap (synchronous secure-field AX probe, mic open, and the start
cue as soon as a prewarmed unit is ready), so an eager arm made every chord audibly start-then-cancel a
dictation. The mic still starts at the key-down: `beginArm` reports `onEngage`, and every engage ends in
exactly one `onStart` (the press stood) or `onEngageDropped` (a chord, a reset in `cancelGestures`, or a binding
that vanished before the grace ended), so the controller can record speech that starts with the press and
discard it silently otherwise. A release inside the grace still flushes the held-back `.down` so a fast tap is not swallowed.
**The held-back `.down` must re-resolve its binding by DESCRIPTOR, never through the index captured
when it was scheduled** (`beginArm`): `update` rebuilds the array in the INCOMING order and carries
`pendingArm`/`armGeneration` across by descriptor, so a binding dropping out ahead of the pending one
shifts its slot — a captured index then addresses a different binding or runs off the end, and the
press is swallowed with no `onStart` at all. Context-aware claiming rebuilds on app switch, which
makes that a routine race rather than the config-reload rarity it used to be. It is also
what makes a subset trigger coexist with its superset (`left_command` alongside
`left_command+left_control`): the smaller set's arm is still pending when the second modifier lands.
(2) **The keyDown abort** (`handle`): the fallback for a chord slower than the grace, which really has
armed — it cancels via `onCancel`, cues and all. By then the recording HUD may be key, so the chord's key went
to the panel instead of the app. The HUD reports every key it receives (`HUDController.onKeyTaken`), and a take
cancelled by the abort replays those keys once focus is back (`DictationController.cancelStartedByModifier`,
collecting for `keyReplayWindow` so a key that reaches the panel just after the cancel is included). A key the
app receives for no window counts as the panel's: the abort is handled before the queued key event, so by then
the panel has given up focus. Replayed events go to the frontmost app's process (`CGEvent.postToPid`), not to the
focused window, because keyboard focus stays with this app for a moment after the panel gives it up and a posted
key would come straight back. They carry `KeyReplay.marker`, and the tap callback ignores them, so a replay never
aborts or arms anything.
No other cancel replays keys.
**Mouse and scroll are in the tap mask for the same reason and are NOT symmetric.** A held modifier
followed by a click emits no keyDown at all, so without `leftMouseDown`/`rightMouseDown`/`otherMouseDown`
a `left_command` trigger fires on every ⌘-click, ⌥-drag and ⇧-click. **A click aborts only a set that
carries a chord modifier** (`isModifierOnly`): a click carries the generic modifier flags and nothing
else, so an Fn-only set can never be part of one, and throwing away an Fn user's running dictation
because they clicked to move the caret is pure loss. A *key* still aborts every set — fn+delete is the
whole point. A pending arm is always dropped, click or key, since that costs nothing.
`scrollWheel` **only cancels a pending arm, never aborts a started dictation, and ignores momentum
phase** (`scrollWheelEventMomentumPhase`). Both halves are load-bearing: aborting on scroll would kill
every hold dictation on a stray trackpad flick, and honouring momentum would silently eat a trigger
pressed in the second after a flick — `cancelPendingArm` suppresses until release, so that press is
lost outright, not merely delayed. The tap stays `.listenOnly`. **Unverified:** `otherMouseDown`
delivery to a listen-only tap under Accessibility alone is measured (see `MouseEventTap`), but
`leftMouseDown`/`rightMouseDown` are only inferred from it — confirm on a machine with no Input
Monitoring grant before relying on it. The failure mode is "clicks never abort", not a crash. Once Accessibility is granted, that session tap runs on **Accessibility alone**
(we never request Input Monitoring) and never
consumes a keystroke. `.listenOnly` (not `.defaultTap`) because we never modify/consume the event:
a listen-only tap is delivered async, so the window server does NOT block the system input stream on
our callback — a busy/wedged main thread can never hold global input hostage, it only delays our own
observation.

### Double-tap

`PressStyle.doubleTap` is limited to a single-member modifier set (`PressStyle.supports`). Where it differs
from the other styles, each rule is load-bearing:

- **One resolution.** `Mode.TriggerKey.effectivePressStyle` is what every reader uses — the bindings, the
  picker, the summaries, first run — so a file pairing double-tap with another key runs, and shows, the
  default style. `Mode.setPrimaryTriggerKey` resets it when the shortcut changes.
- **It starts on the second RELEASE, not a press.** The down skips the chord grace and never calls
  `onEngage`: a first tap opens no mic, and a press is only known to be a standalone tap once it ends. Any
  later lone press-and-release stops the take, however long it was held, like the other latched styles.
- **Interruption is `PressGesture.interrupt()`, never `abort()`.** A key, click, user-driven scroll, or
  foreign modifier (including both sides of a sideless member) ends the current press and the pending
  first tap but leaves a recording running, so ⌘C mid-take neither stops nor cancels it. Routing it
  through `abort` would fire `onCancel` and throw the take away.
- **Both starting taps come from the same physical key.** The monitor keeps the side of a sideless
  member's last press (`Binding.lastPressSide`, from `ModifierMatcher.pressedSide`) and interrupts when it
  changes, so left ⌘ then right ⌘ is not a double-tap.
- **The recording HUD never takes key focus for a double-tap take.** Typing during the take goes to the
  app untouched, so shortcuts, input methods, and secure fields behave as they do without us. Escape is
  claimed instead as a Carbon hot key while the HUD is cancellable (`HUDController.setKeyFocusFree`, the
  same `EscapeClaim` the speaking panel uses). Focus is given up only while that claim holds: if the
  registration is refused, the HUD takes key focus like any other take, so Escape still cancels and only
  typing during that take is lost to the panel. Do not reintroduce re-sending the keys the panel took:
  posting each key to "the frontmost app" lost keys aimed at another process's panel and doubled keys in
  our own windows.

### Tap authorization

**Footgun — the authorization is one-directional, so `start()` gates `tapCreate` on
`AXIsProcessTrusted()`:** calling `tapCreate` *before* the grant not only fails, it makes tccd write
a *denied* `ListenEvent` (Input Monitoring) record and pop a spurious Input Monitoring prompt; that
denied record then suppresses the tap **permanently** — even after Accessibility is later granted —
until ListenEvent is reset. The gate (`HotkeyMonitor.start()`) makes that impossible, and
`relaunchForPermissionSetup()` runs `tccutil reset ListenEvent` (via `ResetTool.resetInputMonitoring`)
before the permission relaunch to heal installs poisoned by a pre-gate build (harmless no-op on a
clean machine). Never call `tapCreate` untrusted, and never "simplify" the gate away.
Verified fact (macOS 26.5, 2026-07-12): **Accessibility subsumes listen-event access** — a
`.listenOnly` session tap DOES receive `.keyDown` with only Accessibility granted and **no**
Input Monitoring grant (`CGPreflightListenEventAccess()` reads `true` from the Accessibility grant
alone; 65 physical keyDowns delivered to the tap while KeyScribe was absent from the Input
Monitoring list). That is what makes the "chord wins" abort real on every install — it
is NOT dead code. (An earlier note here claimed the tap was "deaf to keyDown without Input
Monitoring"; that was stale — it conflated the *untrusted*-`tapCreate` poisoning above, which is
still real and still gated, with steady-state delivery.) Chords still ride `CarbonHotKeys` and ESC
still rides the HUD local monitor — by design (no permission, guaranteed suppression from the
focused app), not because the tap can't see keyDown. Re-verify if the macOS TCC model changes.

## Chord triggers and keyboard layouts

**Chord triggers + the Add-Dictionary / Add-Replacement action shortcuts** (key + modifiers,
e.g. ⌃⌥E) → **`RegisterEventHotKey`** (Carbon, `CarbonHotKeys`). No permission at all: the OS
dispatches the chord and suppresses it from the focused app. Delivers
`kEventHotKeyPressed`/`Released`, so hold/tap gestures work. **Only a function-row key may be
bound bare** (`BaseKey.isBareable` → `SpecialKey.isFunctionKey`; Carbon itself accepts an
empty modifier mask); every other base key needs ≥1 modifier (`bareNonFunctionKey`), so a
trigger can never swallow ordinary typing or navigation.
**A chord's base key is a CHARACTER resolved through the active keyboard layout's SHORTCUT
table — never a hardcoded printable-key table, and never the plain-typing layer alone.**
`RegisterEventHotKey` takes a key code, but a key code is a *position*: letters move under
Dvorak, the whole number row shifts under AZERTY, and a non-Latin layout puts a Latin letter
nowhere a plain keypress can reach it. So `BaseKey` stores
`.character(Character)` for a printing key and resolves it per-registration via
`KeyDescriptor.chordKeyCode(in:)` → `KeyboardLayoutIndex.shortcutKeyCode(for:)` against
`KeyboardLayout.current()` (`.ansiUS` is the no-OS-layout fallback). Only **non-printing** keys
— `SpecialKey`: F-row, arrows, editing block, keypad — carry a fixed `kVK_` code, because their
position genuinely never moves.
**Shortcut identity is the ⌘ layer, falling back to the plain key** (`UCKeyTranslate` with
`cmdKey`), which is how macOS places a shortcut. This is not a refinement, it is load-bearing:
measured against the real system layouts, **Russian / Ukrainian / Bulgarian / Greek / Hebrew /
Thai reach no Latin letter on ANY unmodified or shifted key** — resolving `command+v` against
the plain layer returns nothing, which silently broke paste, copy and every letter trigger on
those layouts. The ⌘ table maps each position back to its Latin legend (physical V → `v`), and
it is also what makes **Dvorak — QWERTY ⌘** put shortcuts on QWERTY positions while typing
stays Dvorak — the only layout of 251 where both layers reach Latin letters and still disagree,
so a chord WITHOUT ⌘ also lands on the QWERTY position there. **Keep the ⌘ layer OUT of `KeyboardLayoutIndex.strokes`** (it is scanned into a
separate map): `stroke(for:)` drives `insertViaTyping`, which posts a stroke's modifiers as
REAL keys, so a ⌘-layer entry there would type "v" as ⌘V and fire paste in the target. Tests
pin both halves. **The shortcut scan also skips every position `SpecialKey` owns**, or the
numeric keypad — which answers on BOTH layers — becomes the only bare source of a character
the main row shifts, and wins: measured, that put all ten digits plus `/`, `*`, `+` on the
keypad under French and Italian (`=` under German/Swedish, `*`/`+` even under US), so
`control+5` bound to a key a laptop does not have while `control+keypad_5` silently claimed
the same Carbon registration that `collides` reports as free. **Do not extend that skip to the
typing scan**: `strokes` must keep return (36) and tab (48), which are how a transcript's
`"\n"`/`"\t"` reach a VM guest under `insertion = "type"`.
Other load-bearing consequences: the base key is a key's **plain** production, never a shifted
one (⌃~ is `` control+shift+` ``); an unresolvable chord is **skipped, not registered at a
sentinel code** (`HotkeyMonitor.rebuildCarbon` logs it; the Settings well says *Not on your
current keyboard layout*), and `TextInserter.postKey` likewise **returns false rather than
claiming success**, so a chord that cannot be posted surfaces as a failed insert instead of
silent data loss; an input-source change re-registers everything through
**`AppDelegate.rebuildHotkeyMonitor`** — never straight at the monitor, because re-registering
tears down every Carbon hot key and would drop the release edge of a chord being held, so it
must inherit the same busy deferral (`pendingHotkeyRebuild`) as every other rebuild. That rebuild
is **unconditional** — a rebuild is ~90 µs and already carries live gesture state across itself,
so there is deliberately no staleness check to get wrong; an earlier build gated it on a recorded
layout key, which bought nothing and could only fail closed if TIS reported the outgoing source at
notification time. `collides` compares descriptors, **not** resolved key codes, so conflict
detection stays pure and layout-free, and the layout cache is keyed on the input source id alone
(`LMGetKbdType()` is passed to `UCKeyTranslate` but is NOT part of the key — measured, keyboard
type changes no translation on any installed layout except the JIS ¥ key). The
recorder stores `KeyboardLayout.shortcutCharacter(keyCode:)`, so a shifted capture saves the
plain key and a Cyrillic keycap still saves its Latin legend. `ClipboardKeystroke`
(`paste_key`/`copy_key`) shares all of this with no fallback of its own: a chord the live layout
cannot produce is logged and not posted, exactly like a trigger. Grammar:
`docs/reference/config_schema.md` "Key descriptor format".

## Mouse-button triggers

**Mouse-button triggers** (`mouseN`, button ≥ 2 — middle / thumb buttons) → a **`.defaultTap`**
`CGEventTap` watching `.otherMouseDown`/`.otherMouseUp` (`MouseEventTap`). Mouse-button events,
unlike `keyDown`, are delivered under **Accessibility alone** — no Input Monitoring (verified
against VoiceInk/OpenWhispr, both Accessibility-only). It is **active/consuming** (returns `nil`
for a bound button) so the button does not also fire its normal action; the bound button is
therefore swallowed globally while the app runs, the same trade Wispr/Superwhisper make.
**Footgun: this is the ONE consuming tap, and it must NEVER run on the main run loop.** An active
tap is synchronous (the window server blocks on the callback); the original freeze was a
`.defaultTap` on the *main* thread held hostage by a wedged main thread (Bluetooth A2DP→HFP audio
bring-up). `MouseEventTap` runs the tap on a **dedicated run-loop thread**; its callback only reads
a lock-guarded `Set<Int>` and hands the edge to main async — it touches no audio/AX/SwiftUI, so a
wedged main thread (a different thread) can never block it. The button set is emptied while a
`HotkeyRecorder` is capturing, so a mouse button can be recorded as the raw click. Mouse cannot ride
Carbon (keyboard-only) or the modifier tap (listen-only can't consume).

## ESC-to-cancel

**ESC-to-cancel** → handled as a **local** keystroke by the recording HUD, made key only while
the HUD is visible and cancellable (see the HUD-is-key footgun in `insertion-and-hud.md` — arming shows no HUD, so
ESC does not apply there; the trigger cancels instead). A local `NSEvent` monitor needs no
permission, but it only sees keys routed to a key window of THIS process.

**ESC-to-stop a spoken reply** is an exception, because the speaking panel never takes key focus (a
double-tap take's recording HUD claims Escape the same way, through `EscapeClaim`):
`SpeakingHUDController` registers a bare Escape (key code 53, layout-independent) as a Carbon hot key on its
own `CarbonHotKeys` **only while the panel shows**, and unregisters it when the panel hides, so Escape is
consumed then and reaches the foreground app at every other time. This does not loosen the bare-key rule
above, which governs user triggers. Several `CarbonHotKeys` registrars coexist: ids are unique across all of
them, and each one's handler returns `eventNotHandledErr` for an id it does not own so the event reaches the
next handler. Keep both halves, or one registrar silently swallows the other's chords.
`ChordRegistering.update` reports whether every registration succeeded, and the speaking panel drops "Esc to
stop" from its status when the claim failed. Recording releases this claim before the recording HUD takes key
focus for its own local Escape, because `recordingStarted` stops speech first; `CaptureCueOrderingTests` pins
that order.

## TCC verdicts and Accessibility recovery

- **TCC verdicts are read at launch and cached for the process lifetime** — a grant/revoke needs an
  app **relaunch** to take effect. Toggling off→on does **not** rebind a grant's `csreq`; only
  remove+re-add or `tccutil reset <service> com.keyscribe.app` rebinds it to the current signature.
  Accessibility's Allow/Grant does that reset itself (`AccessibilityRecovery`), because a stale row
  still displays as on and suppresses the prompt. Three guards are load-bearing: it re-reads
  `AXIsProcessTrusted()` at click time, it resets **at most once per process** (a later click only
  requests — if this process cannot observe a fresh grant, a second reset would delete it), and it is
  **never** driven from a status poll. Own bundle id only; a missing bundle id skips the reset rather than
  falling back to `com.keyscribe.app`. Getting the user to that button is `AppDelegate.launchAttention`:
  after first run, a launch that finds Accessibility missing when the previous launch had it opens
  Settings on Permissions. It keys on the **grant, never the tap** (granted-but-tap-inactive is the
  just-granted state the pane's relaunch banner owns) and on a per-launch verdict marker
  (`ResetTool.accessibilityAtLastLaunchKey`, written every launch; absent reads as lost, so an upgraded
  install is pointed at the repair once). Once per loss is a product call, not a detection: a previous
  launch already without access opens nothing, and declined vs. not-yet-repaired are indistinguishable
  there. Do not widen it to tap state or to every launch without revisiting that call.
