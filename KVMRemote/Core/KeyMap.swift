import Foundation

/// USB HID keyboard usages (page 7). iPadOS reports these as `UIKey.keyCode`.
enum HIDUsage {
    static let a: UInt16 = 0x04
    static let c: UInt16 = 0x06
    static let d: UInt16 = 0x07
    static let h: UInt16 = 0x0B
    static let n: UInt16 = 0x11
    static let p: UInt16 = 0x13
    static let q: UInt16 = 0x14
    static let v: UInt16 = 0x19
    static let w: UInt16 = 0x1A
    static let digit3: UInt16 = 0x20
    static let digit4: UInt16 = 0x21
    static let digit5: UInt16 = 0x22
    static let returnKey: UInt16 = 0x28
    static let escape: UInt16 = 0x29
    static let backspace: UInt16 = 0x2A
    static let tab: UInt16 = 0x2B
    static let space: UInt16 = 0x2C
    static let f3: UInt16 = 0x3C
    static let f11: UInt16 = 0x44
    static let deleteForward: UInt16 = 0x4C
    static let rightArrow: UInt16 = 0x4F
    static let leftArrow: UInt16 = 0x50
    static let downArrow: UInt16 = 0x51
    static let upArrow: UInt16 = 0x52

    static let leftControl: UInt16 = 0xE0
    static let leftShift: UInt16 = 0xE1
    static let leftAlt: UInt16 = 0xE2      // ⌥ Option
    static let leftGUI: UInt16 = 0xE3      // ⌘ Command
    static let rightControl: UInt16 = 0xE4
    static let rightShift: UInt16 = 0xE5
    static let rightAlt: UInt16 = 0xE6
    static let rightGUI: UInt16 = 0xE7

    static func isModifier(_ usage: UInt16) -> Bool { (0xE0...0xE7).contains(usage) }
    static func isCommand(_ usage: UInt16) -> Bool { usage == leftGUI || usage == rightGUI }
}

struct KeyInfo {
    /// AT set-1 ("XT") scancode as used by QEMU extended key events.
    /// Extended (E0-prefixed) keys have the high bit set, e.g. E0 48 (Up) → 0xC8.
    let scancode: UInt16
    /// X11 keysym for servers without extended key events.
    let keysym: UInt32
    let shiftedKeysym: UInt32?
}

enum KeyMap {
    static func info(for usage: UInt16) -> KeyInfo? { table[usage] }

    /// US-layout lookup used to type text (on-screen keyboard, shortcuts).
    static func usage(for character: Character) -> (usage: UInt16, shift: Bool)? {
        characterTable[character]
    }

    private static let table: [UInt16: KeyInfo] = {
        var t: [UInt16: KeyInfo] = [:]
        func add(_ usage: UInt16, _ scancode: UInt16, _ keysym: UInt32, _ shifted: UInt32? = nil) {
            t[usage] = KeyInfo(scancode: scancode, keysym: keysym, shiftedKeysym: shifted)
        }

        // Letters a–z (HID 0x04–0x1D).
        let letterScancodes: [UInt16] = [
            0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
            0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
        ]
        for (i, sc) in letterScancodes.enumerated() {
            add(0x04 + UInt16(i), sc, 0x61 + UInt32(i), 0x41 + UInt32(i))
        }

        // Digits 1–9, 0 (HID 0x1E–0x27) with their US shifted symbols.
        let digitKeysyms: [UInt32] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30]
        let digitShifted: [UInt32] = [0x21, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28, 0x29]
        for i in 0..<10 {
            add(0x1E + UInt16(i), 0x02 + UInt16(i), digitKeysyms[i], digitShifted[i])
        }

        add(0x28, 0x1C, 0xFF0D)            // Return
        add(0x29, 0x01, 0xFF1B)            // Escape
        add(0x2A, 0x0E, 0xFF08)            // Backspace (Mac "delete")
        add(0x2B, 0x0F, 0xFF09)            // Tab
        add(0x2C, 0x39, 0x20)              // Space
        add(0x2D, 0x0C, 0x2D, 0x5F)        // - _
        add(0x2E, 0x0D, 0x3D, 0x2B)        // = +
        add(0x2F, 0x1A, 0x5B, 0x7B)        // [ {
        add(0x30, 0x1B, 0x5D, 0x7D)        // ] }
        add(0x31, 0x2B, 0x5C, 0x7C)        // \ |
        add(0x32, 0x2B, 0x5C, 0x7C)        // Non-US # (same position as \)
        add(0x33, 0x27, 0x3B, 0x3A)        // ; :
        add(0x34, 0x28, 0x27, 0x22)        // ' "
        add(0x35, 0x29, 0x60, 0x7E)        // ` ~
        add(0x36, 0x33, 0x2C, 0x3C)        // , <
        add(0x37, 0x34, 0x2E, 0x3E)        // . >
        add(0x38, 0x35, 0x2F, 0x3F)        // / ?
        add(0x39, 0x3A, 0xFFE5)            // Caps Lock

        // F1–F10, F11, F12
        for i in 0..<10 { add(0x3A + UInt16(i), 0x3B + UInt16(i), 0xFFBE + UInt32(i)) }
        add(0x44, 0x57, 0xFFC8)
        add(0x45, 0x58, 0xFFC9)

        add(0x46, 0x54, 0xFF61)            // Print Screen
        add(0x47, 0x46, 0xFF14)            // Scroll Lock
        add(0x48, 0xC6, 0xFF13)            // Pause
        add(0x49, 0xD2, 0xFF63)            // Insert
        add(0x4A, 0xC7, 0xFF50)            // Home
        add(0x4B, 0xC9, 0xFF55)            // Page Up
        add(0x4C, 0xD3, 0xFFFF)            // Forward Delete
        add(0x4D, 0xCF, 0xFF57)            // End
        add(0x4E, 0xD1, 0xFF56)            // Page Down
        add(0x4F, 0xCD, 0xFF53)            // Right
        add(0x50, 0xCB, 0xFF51)            // Left
        add(0x51, 0xD0, 0xFF54)            // Down
        add(0x52, 0xC8, 0xFF52)            // Up

        // Keypad
        add(0x53, 0x45, 0xFF7F)            // Num Lock / Clear
        add(0x54, 0xB5, 0xFFAF)            // KP /
        add(0x55, 0x37, 0xFFAA)            // KP *
        add(0x56, 0x4A, 0xFFAD)            // KP -
        add(0x57, 0x4E, 0xFFAB)            // KP +
        add(0x58, 0x9C, 0xFF8D)            // KP Enter
        let keypadScancodes: [UInt16] = [0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49, 0x52]
        for i in 0..<10 {
            // HID 0x59–0x62 = KP1…KP9, KP0
            let keysym: UInt32 = i == 9 ? 0xFFB0 : 0xFFB1 + UInt32(i)
            add(0x59 + UInt16(i), keypadScancodes[i], keysym)
        }
        add(0x63, 0x53, 0xFFAE)            // KP .
        add(0x64, 0x56, 0x3C, 0x3E)        // ISO key between Shift and Z (§ on Mac ISO)
        add(0x65, 0xDD, 0xFF67)            // Menu / Application
        add(0x66, 0xDE, 0x1008FF2A)        // Power

        // F13–F24
        let fHighScancodes: [UInt16] = [0x5D, 0x5E, 0x5F, 0x55, 0x83, 0xF7, 0x84, 0x5A, 0x74, 0xF9, 0x6D, 0x6F]
        for i in 0..<12 { add(0x68 + UInt16(i), fHighScancodes[i], 0xFFCA + UInt32(i)) }

        add(0x7F, 0xA0, 0x1008FF12)        // Mute
        add(0x80, 0xB0, 0x1008FF13)        // Volume Up
        add(0x81, 0xAE, 0x1008FF11)        // Volume Down

        // International (JIS) keys
        add(0x87, 0x73, 0x5F)              // Ro
        add(0x88, 0x70, 0xFF2E)            // Katakana/Hiragana
        add(0x89, 0x7D, 0xA5)              // Yen
        add(0x8A, 0x79, 0xFF23)            // Henkan
        add(0x8B, 0x7B, 0xFF22)            // Muhenkan

        // Modifiers
        add(HIDUsage.leftControl, 0x1D, 0xFFE3)
        add(HIDUsage.leftShift, 0x2A, 0xFFE1)
        add(HIDUsage.leftAlt, 0x38, 0xFFE9)
        add(HIDUsage.leftGUI, 0xDB, 0xFFEB)
        add(HIDUsage.rightControl, 0x9D, 0xFFE4)
        add(HIDUsage.rightShift, 0x36, 0xFFE2)
        add(HIDUsage.rightAlt, 0xB8, 0xFFEA)
        add(HIDUsage.rightGUI, 0xDC, 0xFFEC)
        return t
    }()

    private static let characterTable: [Character: (usage: UInt16, shift: Bool)] = {
        var t: [Character: (UInt16, Bool)] = [:]
        // Prefer the main keyboard over the keypad and the ISO key when characters collide.
        let preferred: [UInt16] = Array(0x04...0x38).filter { $0 != 0x32 } + [0x64]
        for usage in preferred {
            guard let info = table[usage], info.keysym < 0x7F || info.keysym == 0x20 else { continue }
            if info.keysym >= 0x20, let scalar = Unicode.Scalar(info.keysym) {
                let c = Character(scalar)
                if t[c] == nil { t[c] = (usage, false) }
            }
            if let s = info.shiftedKeysym, s >= 0x20, s < 0x7F, let scalar = Unicode.Scalar(s) {
                let c = Character(scalar)
                if t[c] == nil { t[c] = (usage, true) }
            }
        }
        t["\n"] = (HIDUsage.returnKey, false)
        t["\r"] = (HIDUsage.returnKey, false)
        t["\t"] = (HIDUsage.tab, false)
        return t
    }()
}

enum VNCAuth {
    /// The classic VNC DES challenge response. The password's bits are mirrored
    /// per byte and used as the DES key (max 8 characters).
    static func response(challenge: Data, password: String) -> Data? {
        #if canImport(CommonCrypto)
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in Array(password.utf8.prefix(8)).enumerated() {
            var b = byte
            var r: UInt8 = 0
            for _ in 0..<8 {
                r = (r << 1) | (b & 1)
                b >>= 1
            }
            key[i] = r
        }
        return desEncrypt(challenge, key: key)
        #else
        return nil
        #endif
    }
}
