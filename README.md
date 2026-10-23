# WattBar

Power usage and battery status in your Mac’s menu bar.

[Website](https://musaamir.github.io/WattBar/) · [Download](https://github.com/musaAmir/WattBar/releases/latest) · [Report an issue](https://github.com/musaAmir/WattBar/issues)

macOS 13+ · Apple silicon & Intel · Free

Unzip and move WattBar.app to Applications. Current builds are **not Apple-notarized**; see the release notes. Sensor availability varies by Mac.

## What’s in it

- **Menu bar:** power usage, a battery icon, a battery percentage, or any combination. Battery options appear only on Macs with a battery.
- **Menu dashboard:** live chart of the last 60 seconds, average and peak draw, and recorded energy for the past minute, hour, day, week (7 days), month (30 days), and 3 months (90 days).
- **Energy & Apps…:** Overview, Applications, and History pages with interactive charts, plus per-app CPU energy (or CPU time where unsupported) with search and sorting. [How measurements and coverage work](docs/energy-tracking.md).
- **History:** up to 90 days, stored only on your Mac in `~/Library/Application Support/WattBar/`.
- **Preferences:** General, Menu Bar, Monitoring, and Updates tabs with a live menu preview.
- **Updates:** menu → **Check for Updates…**. Automatic checks can be changed in Preferences.

Per-app figures are CPU energy only (no display, GPU, or network), so they aren’t a breakdown of whole-Mac use.

Build: `./build.sh release universal` · Test: `swift test`

[Release guide](docs/updates.md) · [Third-party credits](THIRD-PARTY-NOTICES.md)
