# Multi-Output Volume

A menu-bar app that gives you a working master volume — including a slider and
the hardware volume keys — for **aggregate / multi-output devices**, which macOS
otherwise leaves with no volume control at all.

## Why
When your default output is a "Multi-Output Device" (created in Audio MIDI
Setup), the volume keys do nothing and there's no system slider, because the
aggregate device exposes no volume of its own. This app sets the volume on each
underlying sub-device instead, so one control moves them all together.

## Features
- Speaker icon + **slider** in the menu bar.
- **Volume Up / Down / Mute** hardware keys work (and the broken system handling
  is suppressed).
- On-screen HUD when you use the keys.
- Follows the default output device automatically; works for normal devices too.

## Build
```sh
./build.sh
open build/MultiOutputVolume.app
```
Requires the Swift toolchain (Xcode or Command Line Tools).

## Permissions
The slider works immediately. The **keyboard volume keys** need Accessibility
access: System Settings → Privacy & Security → Accessibility → enable
*MultiOutputVolume*. The keys start working the instant you flip the switch —
the app polls for the grant, so **no relaunch is needed**. (It prompts on first
launch if the permission is missing.)

The grant **persists across rebuilds**: `build.sh` signs every build with a
stable, self-signed identity (created automatically on the first build and kept
in a dedicated `multioutputvolume-signing` keychain), so macOS keeps recognising
the app. You only need to grant Accessibility once — after the *first* build
that introduces the new signature.

## Notes
- Some sub-devices (e.g. certain digital/HDMI outputs) expose no volume control;
  those are left untouched and the rest still track the slider.
- For aggregates without a hardware mute, Mute is emulated by dropping volume to
  zero.
- To launch automatically at login: System Settings → General → Login Items →
  add the app.
