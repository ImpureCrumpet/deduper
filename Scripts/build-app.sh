#!/bin/bash
# Build Deduper.app macOS application bundle from SPM.
# Usage: ./Scripts/build-app.sh [--release]
#
# Output: build/Deduper.app

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
fi

echo "Building DeduperApp ($CONFIG)..."
swift build --configuration "$CONFIG" --product DeduperApp

# Locate the built executable
EXEC=".build/$CONFIG/DeduperApp"
if [[ ! -f "$EXEC" ]]; then
    echo "Error: $EXEC not found"
    exit 1
fi

# Assemble .app bundle
APP_DIR="build/Deduper.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp "$EXEC" "$MACOS/DeduperApp"

# Copy Info.plist
cp Info.plist "$CONTENTS/Info.plist"

# Copy icon if it exists
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy dSYM for crash symbolication (optional)
DSYM=".build/$CONFIG/DeduperApp.dSYM"
if [[ -d "$DSYM" ]]; then
    cp -R "$DSYM" "build/DeduperApp.dSYM"
fi

echo ""
echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
