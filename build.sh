#!/bin/bash
# ./build.sh [debug|release] [native|universal]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
ARCHITECTURES="${2:-native}"
case "$CONFIG" in debug) XCODE_CONFIG=Debug ;; release) XCODE_CONFIG=Release ;; *) exit 2 ;; esac
ARGS=()
case "$ARCHITECTURES" in native) ARGS+=("ARCHS=$(uname -m)") ;; universal) ARGS+=("ARCHS=arm64 x86_64") ;; *) exit 2 ;; esac
[[ -z "${VERSION:-}" ]] || ARGS+=("MARKETING_VERSION=$VERSION")
[[ -z "${BUILD_NUMBER:-}" ]] || ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
mkdir -p build
if ! xcodebuild -project WattBar.xcodeproj -scheme WattBar -configuration "$XCODE_CONFIG" \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES "${ARGS[@]}" build > build/xcodebuild.log 2>&1; then
  tail -80 build/xcodebuild.log >&2
  exit 1
fi
STAGING="$(mktemp -d "$PWD/build/.WattBar.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/WattBar.app"
ditto "build/DerivedData/Build/Products/$XCODE_CONFIG/WattBar.app" "$APP"
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
  echo 'Sparkle was not embedded in the app.' >&2; exit 1
fi
cp build/SourcePackages/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
# Optional sandbox services are unused by this non-sandboxed app.
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
[[ "$CONFIG" != release ]] || strip -x "$APP/Contents/MacOS/WattBar"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == - ]]; then
  SIGN_ARGS=(--force --sign - --timestamp=none)
else
  SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --entitlements WattBar/WattBar.entitlements "$APP"
codesign --verify --deep --strict "$APP"
rm -rf build/WattBar.app
mv "$APP" build/WattBar.app
echo "Built build/WattBar.app ($CONFIG, $ARCHITECTURES)"
