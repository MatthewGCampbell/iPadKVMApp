# KVM Remote

An iPad app for controlling a computer through a **PiKVM** over VNC. It's built so that a hardware keyboard on the iPad behaves like a keyboard plugged into the remote Mac: ⌘C, ⌘V, ⌘Z and the rest go to the Mac, not the iPad.

## Features

- **Keyboard passthrough.** Every key goes to the remote as its raw USB scancode (QEMU extended key events), so ⌘C/⌘V copy and paste with the Mac's own clipboard, and the keyboard layout never gets in the way.
- **Shortcuts iPadOS normally takes.** The app asks iPadOS for priority on ⌘Space, ⌘H, ⇧⌘3/4/5, ⌘W, ⌘Q and others. iPadOS always keeps ⌘Tab (and sometimes ⌘Space), so **⌥Tab** gives you the Mac's real app switcher (hold ⌥, tap Tab to move through it) and **⌥Space** opens Spotlight. The toolbar's ⌘ menu also has Spotlight, Mission Control, Force Quit, screenshots, Lock Screen and more.
- **No stuck keys.** Keys pressed while ⌘ is down are sent as quick taps, and everything is released when you switch away from the app.
- **Clipboard, iPad → Mac:** press **⌃⌘V** (or use the clipboard button). PiKVM types the iPad's clipboard text wherever the Mac's cursor is.
- **Clipboard, Mac → iPad:** *Copy Text from Screen Area* lets you drag a box over text on the remote screen. On-device OCR reads it and puts it on the iPad clipboard.
- **Trackpad and mouse:** the iPad pointer drives the remote's pointer directly (absolute positioning, so there's no drift). Buttons press and release exactly when you do, so click-and-hold, drags and right-click work like a real mouse, along with two-finger scrolling.
- **Touch:** tap to click, two-finger tap to right-click, drag with one finger to click-and-drag, scroll with two fingers.
- **On-screen keyboard** for when there's no hardware keyboard, with a bar of Esc, ⌘, ⌥, ⌃, ⇧ and arrow keys.
- **TLS encryption** (PiKVM's default VeNCrypt X.509). The server's certificate is remembered on first connect and you get a warning if it ever changes. The password is kept in the Keychain.
- Also works with other VNC servers (choose "Other VNC server"; uses Raw/CopyRect encoding).

### About the clipboard

PiKVM is a hardware KVM. It only sees the HDMI picture, and it acts as a USB keyboard and mouse, so it can't read or write the Mac's clipboard. That's why:

- iPad → Mac works by having PiKVM *type* the text. This uses kvmd-vnc's built-in "print clipboard" feature, which the app triggers for you. It handles plain text that the PiKVM keyboard map can type. Emoji and other unusual characters get skipped.
- Mac → iPad works by reading the screen (OCR).
- **For full two-way clipboard, including images:** sign the iPad and the Mac mini into the same Apple Account, and turn on Handoff on both (Mac: System Settings › General › AirDrop & Handoff; iPad: Settings › General › AirPlay & Continuity). Universal Clipboard then syncs copy and paste between them on its own, alongside this app. The two devices need to be near each other with Bluetooth and Wi-Fi on.

## PiKVM setup

PiKVM's VNC server is off by default. In the PiKVM web UI, open **Terminal** (or SSH in) and run:

```
su -
rw
systemctl enable --now kvmd-vnc
ro
```

In the app, tap **+** and fill in:

- **Address:** for example `pikvm.local` or the PiKVM's IP
- **Port:** 5900
- **Server Type:** PiKVM
- **Login:** your PiKVM web username and password (default `admin` / `admin`). If two-factor authentication is on, type the password followed immediately by the current 6-digit code.
- **Encryption:** TLS

## Building and installing

Open **`KVMRemote.xcodeproj`** in Xcode 16 or later (Xcode 26 recommended). The app needs iPadOS 17 or later.

1. In the project navigator, select **KVMRemote** › target **KVMRemote** › **Signing & Capabilities**, and pick your **Team**. If Xcode says the bundle identifier is taken, change `com.matthewcampbell.KVMRemote` to something unique.
2. Plug in the iPad, trust the Mac, and turn on **Developer Mode** (Settings › Privacy & Security) if asked.
3. Choose the iPad as the run destination and press **Run** (⌘R).

With a free Apple ID, apps installed this way stop working after 7 days and need to be run from Xcode again. With a paid Apple Developer membership they last a year, and you can use **Product › Archive** to send builds to TestFlight.

The shared scheme runs the **Release** configuration, because Debug builds feel noticeably slower when streaming video. To debug with breakpoints, choose Product › Scheme › Edit Scheme › Run and switch to Debug.

Press **⌘U** to run the unit tests: keyboard routing, ⌘ shortcut handling and the scancode table.

## Project layout

```
KVMRemote.xcodeproj
KVMRemote/
  App/        Host list, host settings, help, saved hosts and Keychain
  Core/       VNC protocol, transports (plain TCP and TLS), key mapping and keyboard logic
  Session/    Remote screen view, input capture, toolbar, framebuffer, OCR
  Assets.xcassets
KVMRemoteTests/  XCTest unit tests
DevTools/        Mock PiKVM server and an end-to-end protocol test (runs on Linux or macOS)
```

The Xcode project uses folder-synced groups, so new files you add under `KVMRemote/` are picked up automatically.

`DevTools/run_core_test.sh` compiles `Core/` with `swiftc` and runs it against `mock_pikvm.py`. The mock follows the same wire protocol as PiKVM's `kvmd-vnc`: VeNCrypt login, Tight-JPEG frames, resolution changes, extended key events and clipboard text. The test checks the exact key sequences sent for ⌘C, ⌘Space, ⌥Tab, ⌃⌘V and typed text.
