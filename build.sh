#!/bin/bash

# Clean rebuild script for WattBar
# Uses xcodebuild (not swiftc) because the app depends on the Sparkle package

echo "Building WattBar..."

xcodebuild -project WattBar.xcodeproj -scheme WattBar -configuration Release \
    -derivedDataPath build/DerivedData -quiet

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "Run with: open build/DerivedData/Build/Products/Release/WattBar.app"
else
    echo "❌ Build failed"
    exit 1
fi
