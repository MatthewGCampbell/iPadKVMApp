# KVM Remote

An iPad app for controlling a computer through a **PiKVM** over VNC. It's built so that a hardware keyboard on the iPad behaves like a keyboard plugged into the remote Mac: ⌘C, ⌘V, ⌘Z and the rest go to the Mac, not the iPad.

## Features

- **Keyboard passthrough.** Every key goes to the remote as its raw USB scancode (QEMU extended key events), so ⌘C/⌘V copy and paste with the Mac's own clipboard, and the keyboard layout never gets in the way.
- **Shortcuts iPadOS normally takes.** The app asks iPadOS for priority on ⌘Space, ⌘H, ⇧⌘3/4/5, ⌘W, ⌘Q and others. iPadOS always keeps ⌘Tab (and sometimes ⌘Space), so **⌥Tab** gives you the Mac's real app switcher (hold ⌥, tap Tab to move through it) and **⌥Space** opens Spotlight. The toolbar's ⌘ menu also has Spotlight, Mission Control, Force Quit, screenshots, Lock Screen and more.
- **No stuck keys.** Keys pressed while ⌘ is down are sent as quick taps, and everything is released when you switch away from the app.
- **Clipboard, iPad → Mac:** press **⌃⌘V** (or use the clipboard button). PiKVM types the iPad's clipboard text wherever the Mac's cursor is.
- **Clipboard, Mac → iPad:** *Copy Text from Screen Area* lets you drag a box over text on the remote screen. On-device OCR reads it and puts it on the iPad clipboard.
- **Trackpad and mouse:** the iPad pointer drives the remote's pointer directly (absolute positioning, so there's no drift). Click, right-click and two-finger scroll all work.
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

The app is a Swift Playgrounds app package (`KVMRemote.swiftpm`), which works with both tools below. It needs iPadOS 17 or later.

**With a Mac (Xcode 15 or later):**

1. Open `KVMRemote.swiftpm` in Xcode.
2. Under *Signing & Capabilities*, pick your team. A free Apple ID works, but the app then has to be reinstalled every 7 days.
3. Connect the iPad, select it as the run destination, and press Run.

**On the iPad with Swift Playgrounds:**

1. Copy the `KVMRemote.swiftpm` folder to the iPad (iCloud Drive or Files).
2. Open it in Swift Playgrounds and tap Run.

   While the app runs *inside* Playgrounds, Playgrounds may grab some ⌘ shortcuts itself. Playgrounds can also upload the app to App Store Connect, so you can install it as a standalone app through TestFlight.

Before the first build, change `bundleIdentifier` in `KVMRemote.swiftpm/Package.swift` to something unique, such as `com.yourname.kvmremote`.

## Project layout

```
KVMRemote.swiftpm/
  Core/      VNC protocol, transports (plain TCP and TLS), key mapping and keyboard logic
  Session/   Remote screen view, input capture, toolbar, framebuffer, OCR
  App/       Host list, host settings, help, saved hosts and Keychain
DevTools/    Mock PiKVM server and an end-to-end test of Core/ (runs on Linux or macOS)
```

`DevTools/run_core_test.sh` compiles `Core/` with `swiftc` and runs it against `mock_pikvm.py`. The mock follows the same wire protocol as PiKVM's `kvmd-vnc`: VeNCrypt login, Tight-JPEG frames, resolution changes, extended key events and clipboard text. The test checks the exact key sequences sent for ⌘C, ⌘Space, ⌥Tab, ⌃⌘V and typed text.
