#!/bin/bash

# Clean rebuild script for WattBar

echo "Building WattBar..."

swiftc -o WattBarApp \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework IOKit \
    WattBar/PowerData.swift \
    WattBar/PreferencesView.swift \
    WattBar/WattBarApp.swift \
    WattBar/SMC.swift

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "Run with: ./WattBarApp"
else
    echo "❌ Build failed"
    exit 1
fi
