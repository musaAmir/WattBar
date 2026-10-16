#!/bin/bash
# Shared paths; source this file from the release scripts.
WATTBAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"
SPARKLE_TOOLS="$WATTBAR_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

resolve_sparkle() {
  xcodebuild -resolvePackageDependencies -project "$WATTBAR_ROOT/WattBar.xcodeproj" -scheme WattBar -clonedSourcePackagesDirPath "$WATTBAR_ROOT/build/SourcePackages" >/dev/null
  if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
    echo "Sparkle's release tools are missing from the SwiftPM artifact." >&2
    exit 1
  fi
}

check_update_key() {
  local public_key configured_key
  if ! public_key="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"; then
    echo "Restore this app's existing update key from your secure backup. See docs/updates.md; do not generate a replacement for an already published app." >&2
    exit 1
  fi
  configured_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$WATTBAR_ROOT/WattBar/Info.plist")"
  if [[ "$public_key" != "$configured_key" ]]; then
    echo "The Keychain signing key does not match WattBar/Info.plist. Do not rotate a published key accidentally." >&2
    exit 1
  fi
}
