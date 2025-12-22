#!/bin/bash

# Clean rebuild script for WattBar

echo "Building WattBar..."

swiftc -o WattBar \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework IOKit \
    WattBar/WattBarApp.swift \
    WattBar/SMC.swift

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "Run with: ./WattBar"
else
    echo "❌ Build failed"
    exit 1
fi
