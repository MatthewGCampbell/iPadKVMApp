import Foundation

/// Turns iPad key presses into remote key events, and adds the behaviours that
/// make Mac shortcuts reliable from an iPad keyboard.
///
/// Usages in and out are USB HID usages. Not thread-safe: use from the main thread.
final class KeyInputRouter {
    enum LocalAction {
        /// ⌃⌘V: type the iPad clipboard on the remote computer.
        case typeIPadClipboard
    }

    struct Options {
        /// While ⌘ is down on the remote, send other keys as an instant press+release.
        /// iPadOS can drop key-up events for keys released while ⌘ is held, which
        /// would otherwise leave e.g. "V" stuck down and make the Mac paste repeatedly.
        var commandShortcutsAsTaps = true
        /// For using the iPad keyboard with a Windows/Linux machine, or personal taste.
        var swapCommandAndOption = false
        /// Reserve ⌃⌘V for "type the iPad clipboard on the remote".
        var clipboardShortcut = true
        /// iPadOS keeps ⌘Tab (and often ⌘Space) for itself, so ⌥Tab and ⌥Space
        /// stand in for them: ⌥Space → ⌘Space, and ⌥Tab holds ⌘ down on the remote
        /// until ⌥ is released, so the Mac's app switcher works like the real thing.
        var optionStandsInForCommand = true
    }

    var options = Options()
    var onLocalAction: (LocalAction) -> Void = { _ in }
    /// Characters the US key map can't produce (emoji, accented letters, …).
    var onUnmappedText: (String) -> Void = { _ in }
    var onModifierStateChange: () -> Void = {}

    private let send: (UInt16, Bool) -> Void

    /// Keys currently down on the remote, in the order they were pressed.
    private(set) var down: [UInt16] = []
    /// Modifiers held down from the toolbar until toggled off ("Hold ⌘").
    private(set) var latched: Set<UInt16> = []
    /// Modifiers applied to the next key only (on-screen keyboard bar).
    private(set) var oneShot: Set<UInt16> = []
    /// ⌘ is down on the remote in place of a physically held ⌥ (see `optionStandsInForCommand`).
    private var commandStandIn = false

    init(send: @escaping (UInt16, Bool) -> Void) {
        self.send = send
    }

    var isCommandDown: Bool { down.contains(HIDUsage.leftGUI) || down.contains(HIDUsage.rightGUI) }

    private func isDown(_ usage: UInt16) -> Bool { down.contains(usage) }

    private func isDown(anyOf usages: UInt16...) -> Bool { usages.contains(where: isDown) }

    // MARK: Hardware keyboard

    func hardwareKeyDown(_ rawUsage: UInt16) {
        let usage = translate(rawUsage)
        if HIDUsage.isModifier(usage) {
            press(usage)
            return
        }

        if options.clipboardShortcut, rawUsage == HIDUsage.v,
           isDown(anyOf: HIDUsage.leftControl, HIDUsage.rightControl),
           isDown(anyOf: translate(HIDUsage.leftGUI), translate(HIDUsage.rightGUI)),
           !isDown(anyOf: HIDUsage.leftShift, HIDUsage.rightShift) {
            // Let go of everything first so the typed text isn't interpreted as shortcuts.
            releaseAll()
            onLocalAction(.typeIPadClipboard)
            return
        }

        if options.optionStandsInForCommand, !options.swapCommandAndOption, !isCommandDown,
           usage == HIDUsage.tab || usage == HIDUsage.space,
           isDown(anyOf: HIDUsage.leftAlt, HIDUsage.rightAlt),
           !isDown(anyOf: HIDUsage.leftControl, HIDUsage.rightControl) {
            release(HIDUsage.leftAlt)
            release(HIDUsage.rightAlt)
            press(HIDUsage.leftGUI)
            press(usage)
            release(usage)
            if usage == HIDUsage.space {
                release(HIDUsage.leftGUI)
            } else {
                commandStandIn = true
            }
            return
        }

        if options.commandShortcutsAsTaps && isCommandDown {
            press(usage)
            release(usage)
        } else {
            press(usage)
        }
        releaseOneShots()
    }

    func hardwareKeyUp(_ rawUsage: UInt16) {
        let usage = translate(rawUsage)
        if latched.contains(usage) || oneShot.contains(usage) { return }
        if commandStandIn && (usage == HIDUsage.leftAlt || usage == HIDUsage.rightAlt) {
            commandStandIn = false
            for key in down where !HIDUsage.isModifier(key) { release(key) }
            release(HIDUsage.leftGUI)
            return
        }
        if HIDUsage.isCommand(usage) {
            // Safety net for key-ups iPadOS swallowed while ⌘ was held.
            for key in down where !HIDUsage.isModifier(key) { release(key) }
        }
        release(usage)
    }

    // MARK: Programmatic input

    /// Press and release `usage` with `modifiers` held. Modifiers that are already
    /// down stay down; the others are pressed just for this key.
    func tap(_ usage: UInt16, modifiers: [UInt16] = []) {
        var temporary: [UInt16] = []
        for m in modifiers where !isDown(m) && !isDown(counterpart(of: m)) {
            press(m)
            temporary.append(m)
        }
        press(usage)
        release(usage)
        for m in temporary.reversed() { release(m) }
        releaseOneShots()
    }

    /// Same as `tap`, but `modifiers` are iPad-side keys (subject to ⌘/⌥ swapping).
    func tapFromIPad(_ usage: UInt16, modifiers: [UInt16]) {
        tap(usage, modifiers: modifiers.map(translate))
    }

    /// Types text using the US key map (on-screen keyboard).
    func type(_ text: String) {
        var unmapped = ""
        for character in text {
            guard let (usage, shift) = KeyMap.usage(for: character) else {
                unmapped.append(character)
                continue
            }
            if !unmapped.isEmpty {
                onUnmappedText(unmapped)
                unmapped = ""
            }
            let needShift = shift && !isDown(anyOf: HIDUsage.leftShift, HIDUsage.rightShift)
            tap(usage, modifiers: needShift ? [HIDUsage.leftShift] : [])
        }
        if !unmapped.isEmpty { onUnmappedText(unmapped) }
    }

    func toggleLatch(_ modifier: UInt16) {
        if latched.remove(modifier) != nil {
            release(modifier)
        } else {
            latched.insert(modifier)
            press(modifier)
        }
        onModifierStateChange()
    }

    func toggleOneShot(_ modifier: UInt16) {
        if oneShot.remove(modifier) != nil {
            if !latched.contains(modifier) { release(modifier) }
        } else {
            oneShot.insert(modifier)
            press(modifier)
        }
        onModifierStateChange()
    }

    /// Releases every key held on the remote. Call when the app loses focus so
    /// nothing stays stuck down (e.g. ⌘ after ⌘Tab on the iPad).
    func releaseAll() {
        for key in down.reversed() where !HIDUsage.isModifier(key) { release(key) }
        for key in down.reversed() { release(key) }
        commandStandIn = false
        let hadToggles = !latched.isEmpty || !oneShot.isEmpty
        latched.removeAll()
        oneShot.removeAll()
        if hadToggles { onModifierStateChange() }
    }

    // MARK: Internals

    private func press(_ usage: UInt16) {
        guard !down.contains(usage) else { return }
        down.append(usage)
        send(usage, true)
    }

    private func release(_ usage: UInt16) {
        guard let index = down.firstIndex(of: usage) else { return }
        down.remove(at: index)
        send(usage, false)
    }

    private func releaseOneShots() {
        guard !oneShot.isEmpty else { return }
        for m in oneShot where !latched.contains(m) { release(m) }
        oneShot.removeAll()
        onModifierStateChange()
    }

    private func translate(_ usage: UInt16) -> UInt16 {
        guard options.swapCommandAndOption else { return usage }
        switch usage {
        case HIDUsage.leftGUI: return HIDUsage.leftAlt
        case HIDUsage.leftAlt: return HIDUsage.leftGUI
        case HIDUsage.rightGUI: return HIDUsage.rightAlt
        case HIDUsage.rightAlt: return HIDUsage.rightGUI
        default: return usage
        }
    }

    private func counterpart(of modifier: UInt16) -> UInt16 {
        switch modifier {
        case 0xE0...0xE3: return modifier + 4
        case 0xE4...0xE7: return modifier - 4
        default: return modifier
        }
    }
}
