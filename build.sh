#!/bin/bash
# Builds MultiOutputVolume.app from the Swift sources in ./Sources.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MultiOutputVolume"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "› Cleaning…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

echo "› Compiling…"
swiftc -O \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    -o "${MACOS_DIR}/${APP_NAME}" \
    Sources/*.swift

echo "› Assembling bundle…"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "› Ad-hoc code signing…"
codesign --force --deep --sign - "${APP_DIR}"

echo "✓ Built ${APP_DIR}"
echo "  Run with:  open \"${APP_DIR}\""
