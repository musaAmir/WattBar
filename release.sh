#!/bin/bash

# Publish a new WattBar version that installed copies will pick up via "Check for Updates..."
#
# Before running:
#   1. In Xcode, bump Version (MARKETING_VERSION, e.g. 1.0.3) and Build (CURRENT_PROJECT_VERSION, e.g. 4).
#      Sparkle compares the Build number, so it must go up every release.
#   2. Commit and push to GitHub.
#
# Usage: ./release.sh "What changed in this version"

set -euo pipefail

REPO="musaAmir/WattBar"
NOTES="${1:-}"
DERIVED="build/DerivedData"
OUT="build/release"

echo "Building WattBar (Release)..."
xcodebuild -project WattBar.xcodeproj -scheme WattBar -configuration Release \
    -derivedDataPath "$DERIVED" clean build -quiet

APP="$DERIVED/Build/Products/Release/WattBar.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
TAG="v$VERSION"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "❌ Release $TAG already exists. Bump the version in Xcode first."
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/WattBar-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# Signs the zip with the private key stored in your Keychain and writes appcast.xml next to it
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    "$OUT"

gh release create "$TAG" -R "$REPO" \
    --title "WattBar $VERSION" \
    --notes "$NOTES" \
    "$ZIP" "$OUT/appcast.xml"

echo "✅ Released $TAG"
