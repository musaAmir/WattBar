# WattBar

Minimal rebuild based on [WattSec](https://github.com/beutton/wattsec) implementation.

## Build with Xcode

1. Open `WattBar.xcodeproj` in Xcode
2. Select the `WattBar` scheme
3. Build and Run (⌘R)

Project files live in `WattBar/`.

## What it does

- Displays real-time wattage (PSTR SMC key) in the menu bar
- Updates every 1 second
- Uses WattSec's exact SMC reading method

## Next steps

Once this works, we can add:
- Battery icon
- Charging detection
- Preferences
- Multiple refresh intervals
- Custom styling
