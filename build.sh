#!/bin/bash

# Clean rebuild script for WattBarClean

echo "Building WattBarClean..."

swiftc -o WattBarClean \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework IOKit \
    WattBarClean/WattBarApp.swift \
    WattBarClean/SMC.swift

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "Run with: ./WattBarClean"
else
    echo "❌ Build failed"
    exit 1
fi
