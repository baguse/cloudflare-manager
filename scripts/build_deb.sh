#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && cd .. && pwd)"

BUILD_DIR="$PROJECT_DIR/build/linux/x64/release/bundle"
DEB_ROOT="$PROJECT_DIR/build/deb"
DEB_CONTROL="$DEB_ROOT/DEBIAN"
DEB_OUT="$PROJECT_DIR/build"
VERSION=$(grep '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | tr -d '"')
BINARY=$(grep '^name:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}')
NAME="cloudflare-manager"
ARCH="amd64"

echo "=== Building Flutter Linux release ==="
cd "$PROJECT_DIR"
flutter build linux --release

if [ ! -d "$BUILD_DIR" ]; then
  echo "ERROR: Build directory not found: $BUILD_DIR"
  exit 1
fi

echo "=== Preparing .deb structure ==="
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_CONTROL"
mkdir -p "$DEB_ROOT/usr/lib/$NAME"
mkdir -p "$DEB_ROOT/usr/bin"
mkdir -p "$DEB_ROOT/usr/share/applications"
mkdir -p "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$DEB_ROOT/usr/share/doc/$NAME"

echo "=== Copying application files ==="
cp -r "$BUILD_DIR"/* "$DEB_ROOT/usr/lib/$NAME/"

echo "=== Copying icon ==="
ICON_DIR="$PROJECT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_DIR" ]; then
  declare -A SIZE_MAP=(
    [16]="app_icon_16.png"
    [32]="app_icon_32.png"
    [64]="app_icon_64.png"
    [128]="app_icon_128.png"
    [256]="app_icon_256.png"
  )
  for size in "${!SIZE_MAP[@]}"; do
    src="$ICON_DIR/${SIZE_MAP[$size]}"
    if [ -f "$src" ]; then
      mkdir -p "$DEB_ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
      cp "$src" "$DEB_ROOT/usr/share/icons/hicolor/${size}x${size}/apps/$NAME.png"
      echo "  Copied ${size}x${size}"
    fi
  done
else
  echo "  WARNING: No macOS icon set found, menu entry will be blank"
fi

echo "=== Creating launch script ==="
cat > "$DEB_ROOT/usr/bin/$NAME" << LAUNCH
#!/bin/sh
exec /usr/lib/$NAME/$BINARY "\$@"
LAUNCH
chmod +x "$DEB_ROOT/usr/bin/$NAME"

echo "=== Creating .desktop entry ==="
cat > "$DEB_ROOT/usr/share/applications/$NAME.desktop" << DESKTOP
[Desktop Entry]
Name=Cloudflare Manager
Comment=Manage Cloudflare Zero Trust tunnels
Exec=$NAME
Icon=$NAME
Type=Application
Categories=Network;
StartupWMClass=$NAME
StartupNotify=true
DESKTOP

echo "=== Creating control file ==="
INSTALLED_SIZE=$(du -sk "$DEB_ROOT/usr" | cut -f1)
cat > "$DEB_CONTROL/control" << CONTROL
Package: $NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Depends: libgtk-3-0 (>= 3.22), libwebkit2gtk-4.1-0 (>= 2.40), cloudflared
Recommends: lsof, curl
Maintainer: Cloudflare Manager Team
Description: Cloudflare Tunnel Manager
 A desktop application to manage Cloudflare Zero Trust tunnels.
 Features include:
   - Create, bind, and manage Cloudflare tunnels
   - HTTP request inspector with body capture and HAR export
   - Live tunnel health monitoring with latency sparklines
   - Auto-reconnect watcher with exponential backoff
   - DNS record editor
   - Webhook notifications for tunnel events
   - QR code generation for tunnel URLs
   - System tray support
CONTROL

  cat > "$DEB_CONTROL/postinst" << POSTINST
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache /usr/share/icons/hicolor/ || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
POSTINST
  chmod +x "$DEB_CONTROL/postinst"

echo "=== Building .deb package ==="
DEB_FILE="$DEB_OUT/${NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build "$DEB_ROOT" "$DEB_FILE"

echo ""
echo "=== Done ==="
echo "Package: $DEB_FILE"
echo "Size:    $(du -h "$DEB_FILE" | cut -f1)"
echo ""
echo "Install with: sudo dpkg -i $DEB_FILE"
echo "Uninstall with: sudo dpkg -r $NAME"
