# DockMute

**DockMute** is a lightweight, zero-dependency native macOS menu bar app that **merges two everyday Mac utilities into one**:

1. **Auto-Mute Guard** — automatically mutes your Mac whenever you open the laptop lid, wake the system or display, or disconnect AirPods / Bluetooth headphones.
2. **Three-Mode Dock Controller** — puts a clean Dock control button in the top menu bar so you can switch the macOS Dock between **Full Show**, **Hover Show** (1-second edge hover), and **Activate Show** (a dedicated green/red show-or-hide toggle that prevents accidental hover pop-ups while hidden).

## Why it is a merge of two tools

On macOS, solving accidental speaker noise and taming the Dock normally means running two separate background utilities (or juggling shell scripts and System Settings). Both are tiny system-level quality-of-life fixes that belong together: one quiet background Swift app (~10 MB RAM, 0% idle CPU, zero third-party frameworks, and no Accessibility, Screen Recording, or Bluetooth permission prompts).

---

## Part 1: Auto-Mute Guard

Mutes audio cleanly through CoreAudio (`kAudioDevicePropertyMute`, keeping your volume slider intact for when you unmute) whenever any of the following happen:

- **Opening the laptop screen (lid open)** — observes `IOPMrootDomain` `AppleClamshellState` transitions and built-in display reactivation, so it triggers even when `caffeinate` or `AppleClamshellCausesSleep = No` keeps the Mac awake while closed.
- **Waking the Mac or display** — listens to `IORegisterForSystemPower`, `NSWorkspace.didWakeNotification`, and `NSWorkspace.screensDidWakeNotification`, plus a short 0.5-second follow-up check so `coreaudiod` cannot restore an unmuted state during wake.
- **Disconnecting AirPods or Bluetooth audio** — watches CoreAudio device removals, `kAudioDevicePropertyDeviceIsAlive`, and default-output switches away from Bluetooth / Bluetooth LE headphones or earbuds. It immediately mutes built-in speakers and guards against delayed route switches for 3 seconds so audio never leaks out of laptop speakers.

You can toggle auto-mute on/off, view the last trigger and timestamp, or trigger a manual mute straight from the menu.

## Part 2: Three-Mode Dock Controller

Click the Dock icon in the menu bar to switch between three modes:

| Mode | Behavior |
| --- | --- |
| **Full Show** *(default)* | Keeps the Dock always visible and restores your original `autohide-delay`. |
| **Hover Show** | Auto-hides the Dock and brings it back only after hovering at the Dock edge for **1.0 second**. |
| **Activate Show** | Adds a dedicated **Green / Red** toggle button right next to the Dock icon. **Green** shows the Dock instantly (no Dock restart). **Red** hides the Dock completely with a `100,000`-second hover delay so brushing the bottom of the screen never pops it back up. |

### Menu Bar Placement

- **Left Side *(default)*** — sits cleanly in the open space to the left of the MacBook notch (or center-left on non-notched displays), staying clear of app menus and right-side icon crowding. Hold **⌘ (Command) and drag** to slide it horizontally; reset anytime from the menu.
- **Right Side (Standard Menu Bar)** — switches to native `NSStatusItem` icons on the right side for auto-hidden menu bars, Bartender/Ice setups, or multi-display menu bars.

---

## Works on any modern macOS

Built as a **Universal 2 binary (`arm64` + `x86_64`)** using only native Apple system frameworks (`AppKit`, `CoreAudio`, `AudioToolbox`, `CoreGraphics`, `IOKit`, `OSLog`):

- **macOS versions:** macOS 11 Big Sur through macOS 27+ (prebuilt universal binary supports Apple Silicon macOS 11+ and Intel macOS 13+; building from source on Intel/older SDKs supports Intel macOS 11+ too)
- **Architectures:** Apple Silicon (M1–M5+) and Intel Macs
- **Form factors:** Notched MacBooks, non-notched MacBooks, external monitors, and desktop Macs (iMac, Mac mini, Mac Studio, Mac Pro — lid detection safely no-ops on desktops while wake and Bluetooth auto-mute remain active)
- **Permissions:** Zero TCC prompts required

---

## Install

### Build and install from source (recommended)

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/zandenkane/dockmute.git
cd dockmute
./scripts/install.sh
```

This builds a Universal `DockMute.app`, copies it to `~/Applications/DockMute.app`, registers a login LaunchAgent at `~/Library/LaunchAgents/com.zandenkane.dockmute.plist`, and launches it immediately.

### Or download the prebuilt Universal app

Download `DockMute-macOS-universal.zip` from [Releases](https://github.com/zandenkane/dockmute/releases), unzip it, and move `DockMute.app` to `/Applications` or `~/Applications`.

Because the prebuilt bundle is ad-hoc signed rather than Apple notarized, clear quarantine once if macOS prompts on first open:

```bash
xattr -dr com.apple.quarantine ~/Applications/DockMute.app
open ~/Applications/DockMute.app
```

### Build without installing a LaunchAgent

```bash
./scripts/build.sh
open build/DockMute.app
```

---

## Uninstall

```bash
./scripts/uninstall.sh
```

Stops DockMute, removes the LaunchAgent and app bundle, and restores standard visible Dock settings.

## License

MIT
