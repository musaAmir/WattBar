# WattBar

macOS menu bar app for power usage and battery monitoring.

## What it does

- Shows real-time system or battery wattage in the menu bar
- Optional battery icon and/or battery percentage (hidden on Macs without a battery)
- Each item can be shown or hidden independently, per Mac
- Updates itself via [Sparkle](https://sparkle-project.org) (menu → Check for Updates...)

## Install

Download the latest `WattBar-x.y.z.zip` from [Releases](https://github.com/musaAmir/WattBar/releases),
unzip, and move `WattBar.app` to Applications. The app isn't notarized, so the first launch is blocked:
open System Settings → Privacy & Security and click "Open Anyway".

## Build

Open `WattBar.xcodeproj` in Xcode and run (⌘R), or run `./build.sh`.

## Release a new version

1. In Xcode, bump Version and Build (the Build number must go up every release).
2. Commit and push.
3. `./release.sh "What changed"`

Updates are signed with a Sparkle key stored in the Keychain of the Mac that created it.
Without that key, installed copies will reject new updates, so keep a backup
(`generate_keys -x backup-file`, from Sparkle's `bin` folder).

## Credits

- Power reading based on [WattSec](https://github.com/beutton/wattsec) by Ben Beutton (MIT License)
- SMC code originally by Serhiy Mytrovtsiy, [Stats](https://github.com/exelban/stats) (MIT License)
