#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Manager — macOS release build script
# Produces: build/cloudflare_manager_<version>.dmg

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Read version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//' | tr '+' '-')
APP_NAME="Cloudflare Manager"
DMG_NAME="cloudflare_manager_${VERSION}"
BUILD_DIR="build/macos/Build/Products/Release"

echo "==================================================================="
echo " Building ${APP_NAME} v${VERSION}"
echo "==================================================================="

# 1. Clean
echo ""
echo "[1/6] Cleaning previous builds..."
flutter clean > /dev/null 2>&1

# 2. Get dependencies
echo "[2/6] Resolving dependencies..."
flutter pub get > /dev/null 2>&1

# 3. Build release
echo "[3/6] Building macOS release (this takes a few minutes)..."
flutter build macos --release

# 4. Verify app exists
APP_PATH="${BUILD_DIR}/Cloudflare Manager.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="${BUILD_DIR}/cloudflare_manager.app"
fi
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — .app not found at ${BUILD_DIR}/"
    exit 1
fi

APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
echo "[4/6] Build complete — ${APP_PATH} (${APP_SIZE})"

# 5. Remove any quarantine xattr (local dev builds often get flagged)
echo "[5/6] Removing quarantine flags..."
xattr -cr "$APP_PATH" 2>/dev/null || true

# 6. Create DMG
echo "[6/6] Creating DMG..."
DMG_PATH="build/${DMG_NAME}.dmg"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH" > /dev/null

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)

echo ""
echo "==================================================================="
echo " Done!"
echo "==================================================================="
echo "  DMG:  ${DMG_PATH}   (${DMG_SIZE})"
echo "  App:  ${APP_PATH}"
echo ""
echo " Distribution notes:"
echo "  - The app is unsigned. Users must right-click → Open to bypass"
echo "    Gatekeeper on first launch, or run:"
echo "      xattr -cr /Applications/cloudflare_manager.app"
echo "  - To sign & notarize: open macos/Runner.xcworkspace in Xcode,"
echo "    set your Team in Signing & Capabilities, and rebuild."
echo ""
