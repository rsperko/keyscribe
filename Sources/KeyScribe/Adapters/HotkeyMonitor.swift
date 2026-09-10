import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import KeyScribeKit
import os

private let hotkeyLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

@MainActor
final class HotkeyMonitor {
    // A watched key. `triggerKey` is nil for the global default (→ context-based mode resolution)
    // or a canonical key descriptor string for a mode-specific key (→ that mode via Phase A).
    struct Binding {
        let triggerKey: String?
        let descriptor: KeyDescriptor
        var gesture: PressGesture
        // Whether the binding's modifier set was engaged as of the last flagsChanged. Arming keys off the
        // TRANSITION into engagement, so a second modifier joining an already-engaged set is not a fresh press.
        var engaged = false
        // Set when a modifier-only gesture aborts as part of a chord. While set, the key is barred from
        // re-arming a fresh dictation even if it momentarily looks like a new press while still held — the
        // suppression persists until every member is released (see resolveModifierSet). Without it, releasing
        // a chord like ⌃⌥⇧⌘D built with the right Option re-engages the bare ⌥ on the way up and tap-latches.
        var suppressedUntilRelease = false
        // A modifier-only .down held back for the chord grace: the modifiers are engaged but nothing has
        // started yet, so a key arriving inside the window discards the arm SILENTLY — no mic, no cue, no
        // HUD. `armGeneration` is bumped on every arm and every cancel so a scheduled arm that lost its
        // race (cancelled, released, or rebuilt onto a different binding) recognises itself as stale.
        var pendingArm = false
        var armGeneration = 0

        init(triggerKey: String?, descriptor: KeyDescriptor, style: PressStyle, tapThreshold: Double) {
            self.triggerKey = triggerKey
            self.descriptor = descriptor
            self.gesture = PressGesture(style: style, tapThreshold: tapThreshold)
        }
    }

    // A global chord that fires a one-shot action (e.g. open the Add-Dictionary panel) rather than
    // driving a dictation gesture. Only chord descriptors are accepted; a modifier-only named key
    // makes no sense as a discrete action trigger.
    struct ActionBinding {
        let id: String
        let descriptor: KeyDescriptor
    }

    private var bindings: [Binding]
    private var actionBindings: [ActionBinding]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let carbon: ChordRegistering
    private let mouseTap: MouseTapping
    var layout: () -> KeyboardLayoutIndex = { KeyboardLayout.current() }
    private let isProcessTrusted: () -> Bool
    // How long a modifier-only trigger waits before arming, so the key of a chord built on it lands first.
    // Arming is not cheap — it runs the synchronous secure-field probe, opens the mic, and (once ready)
    // plays the start cue — so an eager arm makes every fn+delete or ⌃⌥⇧⌘X audibly start-then-cancel a
    // dictation. Only latency is traded: nothing is recorded until admission opens at cue end regardless.
    // A chord slower than the grace still falls through to the keyDown abort, cues and all.
    private let chordGraceSeconds: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    let onStart: (String?, PressStyle) -> Void
    let onCommit: (String?) -> Void
    let onAction: (String) -> Void
    // Fired when a bare modifier-only start turns out to be part of a chord (a foreign modifier or a key
    // joined the held trigger key) — the "chord wins" rule discards the just-started dictation. Carries the
    // aborting binding's triggerKey so the controller cancels only a dictation THIS key started, never an
    // unrelated in-flight one another trigger committed.
    let onCancel: (String?) -> Void

    init(
        bindings: [Binding], actionBindings: [ActionBinding] = [],
        onStart: @escaping (String?, PressStyle) -> Void, onCommit: @escaping (String?) -> Void,
        onAction: @escaping (String) -> Void = { _ in },
        onCancel: @escaping (String?) -> Void = { _ in },
        carbon: ChordRegistering = CarbonHotKeys(),
        mouseTap: MouseTapping = MouseEventTap(),
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        chordGraceSeconds: TimeInterval = 0.15,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        }
    ) {
        self.chordGraceSeconds = chordGraceSeconds
        self.schedule = schedule
        self.bindings = bindings
        self.actionBindings = actionBindings
        self.onStart = onStart
        self.onCommit = onCommit
        self.onAction = onAction
        self.onCancel = onCancel
        self.carbon = carbon
        self.mouseTap = mouseTap
        self.isProcessTrusted = isProcessTrusted
        self.mouseTap.onEdge = { [weak self] button, edge in self?.fireMouse(button: button, edge: edge) }
    }

    func update(bindings: [Binding], actionBindings: [ActionBinding] = []) {
        // Carry live gesture state across a rebuild for any binding whose descriptor + press style are
        // unchanged, so a held/latched key keeps its in-progress gesture; otherwise its release edge is
        // dropped (a tap-to-toggle "stop" misread as a new "start"), stranding the recording.
        let previous = self.bindings
        self.bindings = bindings.map { incoming in
            guard let match = previous.first(where: {
                $0.descriptor == incoming.descriptor
                    && $0.gesture.style == incoming.gesture.style
                    && $0.gesture.tapThreshold == incoming.gesture.tapThreshold
            }) else { return incoming }
            var carried = incoming
            carried.gesture = match.gesture
            carried.engaged = match.engaged
            carried.suppressedUntilRelease = match.suppressedUntilRelease
            carried.pendingArm = match.pendingArm
            carried.armGeneration = match.armGeneration
            return carried
        }
        self.actionBindings = actionBindings
        rebuildCarbon()
        rebuildMouse()
    }

    func cancelGestures() {
        for i in bindings.indices {
            bindings[i].gesture.cancel()
            bindings[i].engaged = false
            bindings[i].suppressedUntilRelease = false
            bindings[i].pendingArm = false
            bindings[i].armGeneration &+= 1
        }
    }

    // A pending arm counts: the key IS physically down, its gesture just has not been told yet. Without it the
    // idle resync (AppDelegate.onBecameIdle) would see "nothing held" and cancelGestures() a press that is
    // still inside its grace, silently dropping a dictation the user had already begun.
    var hasPhysicallyDownGesture: Bool {
        bindings.contains { $0.gesture.isPhysicallyDown || $0.pendingArm }
    }

    // The tap watches modifier-only triggers (any set of sided/sideless modifiers) via `.flagsChanged`; once
    // Accessibility is granted a `.listenOnly` modifier-only tap runs on Accessibility alone — KeyScribe never
    // requests Input Monitoring. Footgun: `tapCreate` *before* the grant fails AND makes tccd write a *denied*
    // ListenEvent record that then suppresses the tap permanently, even after Accessibility is later granted,
    // until ListenEvent is reset — so `start()` gates on `isProcessTrusted()` and never touches it untrusted.
    // `.listenOnly` (not `.defaultTap`): we never consume an event, and it is delivered async, so a wedged
    // main thread can never hold global input hostage. Chords → `CarbonHotKeys`; ESC-to-cancel → the HUD.
    // isTapActive false while Accessibility reads granted means a launch-cached denied verdict or a suppressing
    // ListenEvent record, both repaired by the permission relaunch — the readiness signal AppDelegate/Settings
    // surface (live `AXIsProcessTrusted` would wrongly say "Ready").
    var isTapActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        defer { rebuildCarbon(); rebuildMouse() }
        if tap != nil { return true }
        // Never create the tap untrusted: it fails AND can leave a denied ListenEvent record that suppresses
        // it for good (see isTapActive). The post-grant relaunch re-invokes start() with the verdict present.
        // Carbon chords register via the defer with no permission; the mouse tap self-gates on the same trust
        // check in MouseEventTap.ensureRunning.
        guard isProcessTrusted() else {
            hotkeyLog.info("modifier-key event tap deferred until Accessibility is granted")
            return false
        }
        // Mouse and scroll join keyDown as "this press is a gesture, not a dictation": a held modifier
        // followed by a click sends no keyDown at all, so without them a `left_command` trigger would fire
        // on every ⌘-click, ⌥-drag and ⇧-click.
        let mask = HotkeyMonitor.watchedEventTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = makeTap(mask: mask, options: .listenOnly) else {
            hotkeyLog.error("modifier-key event tap not created despite Accessibility granted; a denied ListenEvent record may be suppressing it — relaunch to repair")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        activeHotkeyMonitor = self
        hotkeyLog.info("modifier-key event tap active")
        return true
    }

    private func makeTap(mask: CGEventMask, options: CGEventTapOptions) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
            eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: nil)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        carbon.stop()
        mouseTap.stop()
        activeHotkeyMonitor = nil
    }

    // macOS disables a tap (emitting one of these events) when its callback is slow or under certain
    // input conditions; it must be re-enabled or the monitor goes permanently deaf — dictation gets
    // stuck "listening" because the release edge never arrives.
    fileprivate func reEnable(reason: CGEventType) {
        guard let tap else { return }
        hotkeyLog.error("event tap disabled (type=\(reason.rawValue, privacy: .public)); re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Suspended while a HotkeyRecorder is capturing in Settings, so pressing a chord to record it can't
    // also fire an existing global shortcut or mode trigger. The tap goes quiet, and the Carbon chords
    // unregister so the recorder's local monitor sees the raw keystroke; both are restored on resume.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended { carbon.update([]) } else { rebuildCarbon() }
            rebuildMouse()
        }
    }

    static let watchedEventTypes: [CGEventType] = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    // Modifier-only triggers only. Chord triggers and action chords are handled by `CarbonHotKeys`.
    // Never consumes — a bare modifier types nothing, so there is nothing to swallow. "Chord wins" applies to
    // EVERY modifier-only trigger: a keyDown or a click while one is held aborts it, so the user's own mapping
    // (fn+delete, ⌃⌥⇧⌘D, ⌘-click) reaches the focused app instead of being swallowed by the recording HUD's
    // key focus. Scroll only discards an arm that has not started anything yet — a stray trackpad or momentum
    // scroll must never kill a dictation already running.
    // A trackpad emits scrollWheel events for things that are not scrolling: `mayBegin` when two fingers
    // merely touch it, `ended`/`cancelled` when they lift, all with zero deltas. Only a phase the user is
    // driving counts; a legacy wheel carries no phase at all, so it is judged by its delta.
    nonisolated static func scrollIsUserDriven(
        momentumPhase: Int64, scrollPhase: Int64, deltaAxis1: Int64, deltaAxis2: Int64
    ) -> Bool {
        guard momentumPhase == 0 else { return false }
        if scrollPhase != 0 {
            return scrollPhase == Int64(CGScrollPhase.began.rawValue)
                || scrollPhase == Int64(CGScrollPhase.changed.rawValue)
        }
        return deltaAxis1 != 0 || deltaAxis2 != 0
    }

    func handle(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, scrollIsUserDriven: Bool = true
    ) {
        guard !isSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click carries the generic modifier flags and nothing else, so a set of only Fn can never be
            // part of one — throwing away an Fn user's running dictation because they clicked to move the
            // caret is pure loss. A key still aborts any set: fn+delete is the whole point of "chord wins".
            let click = type != .keyDown
            for i in bindings.indices where bindings[i].descriptor.isModifierSet {
                if bindings[i].pendingArm {
                    cancelPendingArm(index: i)
                } else if bindings[i].gesture.isPhysicallyDown,
                          !click || bindings[i].descriptor.carriesChordModifier {
                    abort(index: i)
                }
            }
        case .scrollWheel:
            // Only a scroll the user is actually driving counts. Momentum keeps arriving for a second after
            // the fingers lift, and a resting hand emits `mayBegin` with zero deltas; either one would eat a
            // trigger pressed nearby — and `cancelPendingArm` suppresses until release, so it is lost
            // outright, not merely delayed.
            guard scrollIsUserDriven else { return }
            for i in bindings.indices where bindings[i].descriptor.isModifierSet {
                if bindings[i].pendingArm { cancelPendingArm(index: i) }
            }
        case .flagsChanged:
            for i in bindings.indices {
                guard case .modifiers(let set) = bindings[i].descriptor else { continue }
                resolveModifierSet(binding: i, set: set, flags: flags, now: now)
            }
        default:
            break
        }
    }

    private func rebuildCarbon() {
        guard !isSuspended else { carbon.update([]); return }
        let index = layout()
        var registrations: [CarbonHotKeys.Registration] = []
        for i in bindings.indices {
            guard case .chord = bindings[i].descriptor else { continue }
            guard let keyCode = bindings[i].descriptor.chordKeyCode(in: index) else {
                logOffLayout(bindings[i].descriptor)
                continue
            }
            registrations.append(.init(
                keyCode: keyCode,
                modifiers: bindings[i].descriptor.requiredModifierMask,
                onPressed: { [weak self] in self?.carbonEdge(index: i, edge: .down) },
                onReleased: { [weak self] in self?.carbonEdge(index: i, edge: .up) }))
        }
        for action in actionBindings {
            let id = action.id
            guard let keyCode = action.descriptor.chordKeyCode(in: index) else {
                logOffLayout(action.descriptor)
                continue
            }
            registrations.append(.init(
                keyCode: keyCode,
                modifiers: action.descriptor.requiredModifierMask,
                onPressed: { [weak self] in self?.dispatchSideEffect { self?.onAction(id) } },
                onReleased: nil))
        }
        carbon.update(registrations)
    }

    private func logOffLayout(_ descriptor: KeyDescriptor) {
        hotkeyLog.notice(
            "not registering \(descriptor.canonical, privacy: .public) — absent from the active keyboard layout")
    }

    private func carbonEdge(index: Int, edge: TriggerEdge) {
        guard bindings.indices.contains(index) else { return }
        fire(index: index, edge: edge, now: ProcessInfo.processInfo.systemUptime)
    }

    // Mouse-button triggers ride a separate consuming tap (`MouseEventTap`), not the modifier tap or
    // Carbon — a mouse button is neither a `keyDown` chord nor a bare modifier. Empty set while
    // suspended so a recorder capturing a mouse button sees the raw click.
    private func rebuildMouse() {
        guard !isSuspended else { mouseTap.setConsumedButtons([]); return }
        var buttons: Set<Int> = []
        for binding in bindings {
            if case .mouseButton(let n) = binding.descriptor { buttons.insert(n) }
        }
        mouseTap.setConsumedButtons(buttons)
    }

    private func fireMouse(button: Int, edge: TriggerEdge) {
        guard let index = bindings.firstIndex(where: {
            if case .mouseButton(let n) = $0.descriptor { return n == button }
            return false
        }) else { return }
        fire(index: index, edge: edge, now: ProcessInfo.processInfo.systemUptime)
    }

    private func fire(index: Int, edge: TriggerEdge, now: TimeInterval) {
        let key = bindings[index].triggerKey
        let style = bindings[index].gesture.style
        switch bindings[index].gesture.handle(edge, at: now) {
        case .start: dispatchSideEffect { self.onStart(key, style) }
        case .commit: dispatchSideEffect { self.onCommit(key) }
        case .none: break
        }
    }

    // The one matching rule for every modifier-only trigger. `engaged` is an EXACT match of the normalized
    // modifier state against the binding's set, so any foreign modifier disengages it — that is "chord wins",
    // applied uniformly instead of per-named-key. What separates the two ways to disengage is whether the
    // set is still WHOLLY held: every member still down means something foreign joined (a chord is forming
    // → abort); a member having lifted means the user let go (→ commit).
    private func resolveModifierSet(
        binding i: Int, set: ModifierKeySet, flags: CGEventFlags, now: TimeInterval
    ) {
        let engaged = ModifierMatcher.engaged(set, in: flags)
        let wholeSetHeld = ModifierMatcher.allMembersDown(set, in: flags)

        if !ModifierMatcher.anyMemberDown(set, in: flags) {
            // A full physical release lifts the suppression: nothing is down, so the next press may arm.
            bindings[i].suppressedUntilRelease = false
        } else if !engaged, ModifierMatcher.foreignModifierHeld(set, in: flags) {
            // A member that went down BESIDE a foreign modifier is spent until fully released. Without this
            // the foreign modifier's release leaves the set alone and reads as a fresh engage — ⇧⌘4 then
            // lifting ⇧ starts a dictation, and on hold-or-tap the ⌘ release latches an unseen open mic.
            // Nothing armed in that sequence, so no abort ever ran; the suppression has to come from the
            // flags. A pair is unaffected: ⌘ then ⌃ has no foreign modifier at any point.
            bindings[i].suppressedUntilRelease = true
        }

        let wasEngaged = bindings[i].engaged
        bindings[i].engaged = engaged

        if engaged {
            // Arm on the TRANSITION only. Re-arming off an already-engaged set is how an aborted chord
            // re-fired on every later flagsChanged while its modifiers stayed held.
            guard !wasEngaged, !bindings[i].suppressedUntilRelease else { return }
            guard !bindings[i].gesture.isPhysicallyDown, !bindings[i].pendingArm else { return }
            beginArm(index: i, now: now)
            return
        }

        guard wasEngaged else { return }
        if wholeSetHeld {
            // Still down, but a foreign modifier joined → it's a chord. Inside the grace nothing started, so
            // drop the arm silently rather than starting and cancelling a dictation the user never asked for.
            if bindings[i].pendingArm { cancelPendingArm(index: i); return }
            guard bindings[i].gesture.isPhysicallyDown else { return }
            abort(index: i)
        } else {
            flushPendingArm(index: i, now: now) // released inside the grace → still a tap
            guard bindings[i].gesture.isPhysicallyDown else { return }
            fire(index: i, edge: .up, now: now) // physically released → normal commit/latch path
        }
    }

    // Hold the .down for the grace instead of firing it. A grace of 0 arms inline, which is the pre-grace
    // behaviour and what the edge-semantics tests pin.
    private func beginArm(index i: Int, now: TimeInterval) {
        guard chordGraceSeconds > 0 else { fire(index: i, edge: .down, now: now); return }
        bindings[i].armGeneration &+= 1
        bindings[i].pendingArm = true
        let generation = bindings[i].armGeneration
        schedule(chordGraceSeconds) { [weak self] in
            guard let self, self.bindings.indices.contains(i),
                  self.bindings[i].pendingArm, self.bindings[i].armGeneration == generation else { return }
            self.bindings[i].pendingArm = false
            self.fire(index: i, edge: .down, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    // The chord won inside the grace: drop the arm with no onStart, so there is nothing to cancel and the
    // user hears nothing. Barred from re-arming until the key is fully released, exactly like a real abort.
    private func cancelPendingArm(index i: Int) {
        guard bindings[i].pendingArm else { return }
        bindings[i].pendingArm = false
        bindings[i].armGeneration &+= 1
        bindings[i].suppressedUntilRelease = true
    }

    // Released inside the grace — a genuine fast tap, not a chord. Fire the held-back .down now so the
    // caller's .up still reads as a tap; dropping it instead would swallow short taps entirely.
    private func flushPendingArm(index i: Int, now: TimeInterval) {
        guard bindings[i].pendingArm else { return }
        bindings[i].pendingArm = false
        bindings[i].armGeneration &+= 1
        fire(index: i, edge: .down, now: now)
    }

    // `engaged` is deliberately NOT cleared here: it mirrors the flags, and clearing it would make the very
    // next flagsChanged read as a fresh engage. Suppression is what bars the re-arm until a full release.
    private func abort(index i: Int) {
        bindings[i].gesture.cancel()
        bindings[i].suppressedUntilRelease = true
        let key = bindings[i].triggerKey
        dispatchSideEffect { self.onCancel(key) }
    }

    // Run a gesture/action callback off the event-tap delivery context: `onStart`/`onCommit`/`onAction` do
    // real work (engine resolve, audio start, HUD) that inline would risk a `tapDisabledByTimeout`. Gesture
    // state already advanced synchronously; only the side-effect is deferred, FIFO so a start precedes its commit.
    private func dispatchSideEffect(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

}

// Matching a modifier-only trigger against live event flags. Normalization is load-bearing: `CGEventFlags`
// also carries Caps Lock (`maskAlphaShift`), the numeric-pad and non-coalesced bits and the device-dependent
// left/right bits, so comparing raw flags would make every trigger silently dead while Caps Lock is lit.
private enum ModifierMatcher {
    static let genericMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// Exactly this set is held: the four chord modifiers match bit for bit, Fn matches presence, and every
    /// sided member's key is down with the OPPOSITE side up. Requiring the opposite side up is what makes
    /// `left_command` and `right_command` mutually exclusive in fact as well as in `canEngageTogether` —
    /// without it, holding both ⌘ keys engages both bindings and runs two dictations.
    static func engaged(_ set: ModifierKeySet, in flags: CGEventFlags) -> Bool {
        guard flags.intersection(genericMask) == genericFlags(set) else { return false }
        guard flags.contains(.maskSecondaryFn) == set.contains(.fn) else { return false }
        return set.members.allSatisfy { member in
            guard let bit = deviceBit(member), let opposite = deviceBit(member.flipped) else { return true }
            return flags.rawValue & bit != 0 && flags.rawValue & opposite == 0
        }
    }

    /// Every member still physically down. A disengaged-but-whole set means a foreign modifier joined.
    static func allMembersDown(_ set: ModifierKeySet, in flags: CGEventFlags) -> Bool {
        set.members.allSatisfy { isDown($0, in: flags) }
    }

    /// A modifier key the set does not name is held — either a modifier it lacks entirely, or the OPPOSITE
    /// key of one of its sided members. The second half matters as much as the first: right ⌘ held while a
    /// `left_command` trigger is bound is foreign participation, so releasing it must not leave the left ⌘
    /// looking freshly pressed and arm a dictation nobody triggered.
    static func foreignModifierHeld(_ set: ModifierKeySet, in flags: CGEventFlags) -> Bool {
        ModifierKey.allCases.contains { modifier in
            guard let member = set.member(for: modifier) else {
                guard let flag = genericFlag(modifier) else { return flags.contains(.maskSecondaryFn) }
                return flags.contains(flag)
            }
            guard let opposite = deviceBit(member.flipped) else { return false }
            return flags.rawValue & opposite != 0
        }
    }

    /// Any member still physically down. Lifts the suppression only on a full release.
    static func anyMemberDown(_ set: ModifierKeySet, in flags: CGEventFlags) -> Bool {
        set.members.contains { isDown($0, in: flags) }
    }

    private static func isDown(_ member: SidedModifier, in flags: CGEventFlags) -> Bool {
        if let bit = deviceBit(member) { return flags.rawValue & bit != 0 }
        guard let flag = genericFlag(member.modifier) else { return flags.contains(.maskSecondaryFn) }
        return flags.contains(flag)
    }

    private static func genericFlags(_ set: ModifierKeySet) -> CGEventFlags {
        set.members.reduce(into: CGEventFlags()) { result, member in
            if let flag = genericFlag(member.modifier) { result.insert(flag) }
        }
    }

    private static func genericFlag(_ modifier: ModifierKey) -> CGEventFlags? {
        switch modifier {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .shift: return .maskShift
        case .command: return .maskCommand
        case .fn: return nil
        }
    }

    private static func deviceBit(_ member: SidedModifier) -> UInt64? {
        guard let side = member.side else { return nil }
        switch (member.modifier, side) {
        case (.control, .left): return UInt64(NX_DEVICELCTLKEYMASK)
        case (.control, .right): return UInt64(NX_DEVICERCTLKEYMASK)
        case (.option, .left): return UInt64(NX_DEVICELALTKEYMASK)
        case (.option, .right): return UInt64(NX_DEVICERALTKEYMASK)
        case (.shift, .left): return UInt64(NX_DEVICELSHIFTKEYMASK)
        case (.shift, .right): return UInt64(NX_DEVICERSHIFTKEYMASK)
        case (.command, .left): return UInt64(NX_DEVICELCMDKEYMASK)
        case (.command, .right): return UInt64(NX_DEVICERCMDKEYMASK)
        case (.fn, _): return nil
        }
    }
}

extension KeyDescriptor {
    var isModifierSet: Bool {
        if case .modifiers = self { return true }
        return false
    }
}

nonisolated(unsafe) private weak var activeHotkeyMonitor: HotkeyMonitor?

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { activeHotkeyMonitor?.reEnable(reason: type) }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let rawFlags = event.flags.rawValue
    let scrollIsUserDriven = type != .scrollWheel || HotkeyMonitor.scrollIsUserDriven(
        momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
        scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
        deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
        deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    MainActor.assumeIsolated {
        activeHotkeyMonitor?.handle(
            type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: rawFlags),
            scrollIsUserDriven: scrollIsUserDriven)
    }
    return Unmanaged.passUnretained(event)
}
