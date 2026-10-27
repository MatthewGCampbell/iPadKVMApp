import Foundation

/// Shortcuts offered in the session toolbar, mostly ones iPadOS keeps for itself.
enum RemoteShortcut: String, CaseIterable, Identifiable {
    case spotlight, appSwitcher, missionControl, appWindows, emoji
    case quitApp, closeWindow, hideApp, forceQuit
    case screenshotArea, screenshotScreen, screenshotTools
    case lockScreen, escape, ctrlAltDelete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotlight: return "Spotlight"
        case .appSwitcher: return "Switch to Last App"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App Windows"
        case .emoji: return "Emoji & Symbols"
        case .quitApp: return "Quit App"
        case .closeWindow: return "Close Window"
        case .hideApp: return "Hide App"
        case .forceQuit: return "Force Quit…"
        case .screenshotArea: return "Screenshot of Area"
        case .screenshotScreen: return "Screenshot of Screen"
        case .screenshotTools: return "Screenshot Tools"
        case .lockScreen: return "Lock Screen"
        case .escape: return "Escape"
        case .ctrlAltDelete: return "Ctrl-Alt-Delete (PC)"
        }
    }

    var keys: String {
        switch self {
        case .spotlight: return "⌘Space"
        case .appSwitcher: return "⌘Tab"
        case .missionControl: return "⌃↑"
        case .appWindows: return "⌃↓"
        case .emoji: return "⌃⌘Space"
        case .quitApp: return "⌘Q"
        case .closeWindow: return "⌘W"
        case .hideApp: return "⌘H"
        case .forceQuit: return "⌥⌘Esc"
        case .screenshotArea: return "⇧⌘4"
        case .screenshotScreen: return "⇧⌘3"
        case .screenshotTools: return "⇧⌘5"
        case .lockScreen: return "⌃⌘Q"
        case .escape: return "Esc"
        case .ctrlAltDelete: return "⌃⌥⌦"
        }
    }

    var systemImage: String {
        switch self {
        case .spotlight: return "magnifyingglass"
        case .appSwitcher: return "square.on.square"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .emoji: return "face.smiling"
        case .quitApp: return "xmark.square"
        case .closeWindow: return "xmark.rectangle"
        case .hideApp: return "eye.slash"
        case .forceQuit: return "exclamationmark.octagon"
        case .screenshotArea: return "crop"
        case .screenshotScreen: return "camera.viewfinder"
        case .screenshotTools: return "camera.aperture"
        case .lockScreen: return "lock"
        case .escape: return "escape"
        case .ctrlAltDelete: return "pc"
        }
    }

    /// (key, modifiers) as HID usages on the remote side.
    var combo: (key: UInt16, modifiers: [UInt16]) {
        let cmd = HIDUsage.leftGUI, ctrl = HIDUsage.leftControl
        let opt = HIDUsage.leftAlt, shift = HIDUsage.leftShift
        switch self {
        case .spotlight: return (HIDUsage.space, [cmd])
        case .appSwitcher: return (HIDUsage.tab, [cmd])
        case .missionControl: return (HIDUsage.upArrow, [ctrl])
        case .appWindows: return (HIDUsage.downArrow, [ctrl])
        case .emoji: return (HIDUsage.space, [ctrl, cmd])
        case .quitApp: return (HIDUsage.q, [cmd])
        case .closeWindow: return (HIDUsage.w, [cmd])
        case .hideApp: return (HIDUsage.h, [cmd])
        case .forceQuit: return (HIDUsage.escape, [opt, cmd])
        case .screenshotArea: return (HIDUsage.digit4, [shift, cmd])
        case .screenshotScreen: return (HIDUsage.digit3, [shift, cmd])
        case .screenshotTools: return (HIDUsage.digit5, [shift, cmd])
        case .lockScreen: return (HIDUsage.q, [ctrl, cmd])
        case .escape: return (HIDUsage.escape, [])
        case .ctrlAltDelete: return (HIDUsage.deleteForward, [ctrl, opt])
        }
    }

    static let macGroups: [[RemoteShortcut]] = [
        [.spotlight, .appSwitcher, .missionControl, .appWindows, .emoji],
        [.quitApp, .closeWindow, .hideApp, .forceQuit],
        [.screenshotArea, .screenshotScreen, .screenshotTools],
        [.lockScreen, .escape, .ctrlAltDelete],
    ]
}
