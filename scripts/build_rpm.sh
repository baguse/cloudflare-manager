#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && cd .. && pwd)"

BUILD_DIR="$PROJECT_DIR/build/linux/x64/release/bundle"
RPM_BUILD_ROOT="$HOME/rpmbuild"
RPM_SOURCES="$RPM_BUILD_ROOT/SOURCES"
RPM_DEPS_DIR="$RPM_SOURCES/cloudflare-manager-deps"
RAW_VERSION=$(grep '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | tr -d '"')
VERSION=$(echo "$RAW_VERSION" | cut -d'+' -f1)
BUILD_NUM=$(echo "$RAW_VERSION" | cut -sd'+' -f2 || echo "1")
BINARY=$(grep '^name:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}')
NAME="cloudflare-manager"
ARCH="x86_64"

echo "=== Building Flutter Linux release ==="
cd "$PROJECT_DIR"
flutter build linux --release

if [ ! -d "$BUILD_DIR" ]; then
  echo "ERROR: Build directory not found: $BUILD_DIR"
  exit 1
fi

echo "=== Preparing RPM build structure ==="
rm -rf "$RPM_DEPS_DIR"
mkdir -p "$RPM_DEPS_DIR/usr/lib/$NAME"
mkdir -p "$RPM_DEPS_DIR/usr/bin"
mkdir -p "$RPM_DEPS_DIR/usr/share/applications"
mkdir -p "$RPM_DEPS_DIR/usr/share/icons/hicolor"
mkdir -p "$RPM_DEPS_DIR/usr/share/doc/$NAME"

echo "=== Copying application files ==="
cp -r "$BUILD_DIR"/* "$RPM_DEPS_DIR/usr/lib/$NAME/"

echo "=== Creating launch script ==="
cat > "$RPM_DEPS_DIR/usr/bin/$NAME" << LAUNCH
#!/bin/sh
exec /usr/lib/$NAME/$BINARY "\$@"
LAUNCH
chmod +x "$RPM_DEPS_DIR/usr/bin/$NAME"

echo "=== Copying icon ==="
ICON_DIR="$PROJECT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset"
declare -A SIZE_MAP=(
  [16]="app_icon_16.png"
  [32]="app_icon_32.png"
  [64]="app_icon_64.png"
  [128]="app_icon_128.png"
  [256]="app_icon_256.png"
)
if [ -d "$ICON_DIR" ]; then
  for size in "${!SIZE_MAP[@]}"; do
    src="$ICON_DIR/${SIZE_MAP[$size]}"
    if [ -f "$src" ]; then
      mkdir -p "$RPM_DEPS_DIR/usr/share/icons/hicolor/${size}x${size}/apps"
      cp "$src" "$RPM_DEPS_DIR/usr/share/icons/hicolor/${size}x${size}/apps/$NAME.png"
    fi
  done
  echo "  Icons copied"
else
  echo "  WARNING: No icon set found"
fi

echo "=== Creating .desktop entry ==="
cat > "$RPM_DEPS_DIR/usr/share/applications/$NAME.desktop" << DESKTOP
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

echo "=== Creating .spec file ==="
mkdir -p "$RPM_BUILD_ROOT/SPECS"
SPEC_FILE="$RPM_BUILD_ROOT/SPECS/$NAME.spec"

cat > "$SPEC_FILE" << SPEC
Name:           $NAME
Version:        $VERSION
Release:        ${BUILD_NUM:-1}%{?dist}
Summary:        Cloudflare Zero Trust Tunnel Manager
License:        MIT
URL:            https://github.com/your-org/$NAME
Source0:        %{name}-deps.tar.gz

BuildArch:      $ARCH

Requires:       gtk3 >= 3.22
Requires:       webkit2gtk4.1 >= 2.40
Requires:       libayatana-appindicator
Requires:       libsecret
Requires:       cloudflared
Recommends:     lsof
Recommends:     curl
Requires:       hicolor-icon-theme

%description
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

%prep
%setup -q -c -T -n %{name}-deps
cp -r %{_sourcedir}/%{name}-deps/* .

%build
# Nothing to build - prebuilt binary from Flutter

%install
rm -rf \$RPM_BUILD_ROOT
mkdir -p \$RPM_BUILD_ROOT/usr/lib/%{name}
mkdir -p \$RPM_BUILD_ROOT/usr/bin
mkdir -p \$RPM_BUILD_ROOT/usr/share/applications
mkdir -p \$RPM_BUILD_ROOT/usr/share/icons
cp -r usr/* \$RPM_BUILD_ROOT/usr/

%clean
rm -rf \$RPM_BUILD_ROOT

%files
/usr/lib/%{name}/
/usr/bin/%{name}
/usr/share/applications/%{name}.desktop
/usr/share/icons/hicolor/*/apps/%{name}.png

%post
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache /usr/share/icons/hicolor/ || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

%postun
if [ \$1 -eq 0 ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache /usr/share/icons/hicolor/ || true
fi
if [ \$1 -eq 0 ] && command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

%changelog
* $(date +"%a %b %d %Y") Cloudflare Manager Team - $VERSION-1
- Initial RPM package
SPEC

echo "=== Creating source tarball ==="
cd "$RPM_SOURCES"
tar -czf "$RPM_SOURCES/$NAME-deps.tar.gz" -C "$RPM_DEPS_DIR" .

echo "=== Building RPM ==="
rpmbuild -bb "$SPEC_FILE" --define "_topdir $RPM_BUILD_ROOT"

RPM_GLOB="$RPM_BUILD_ROOT/RPMS/$ARCH/${NAME}-${VERSION}-*.rpm"
RPM_FILE=$(ls $RPM_GLOB 2>/dev/null | head -1)

if [ -n "$RPM_FILE" ] && [ -f "$RPM_FILE" ]; then
  cp "$RPM_FILE" "$PROJECT_DIR/build/"
  RPM_OUT="$PROJECT_DIR/build/$(basename "$RPM_FILE")"
  echo ""
  echo "=== Done ==="
  echo "Package: $RPM_OUT"
  echo "Size:    $(du -h "$RPM_OUT" | cut -f1)"
  echo ""
  echo "Install with: sudo dnf install '$RPM_OUT'"
  echo "Uninstall with: sudo dnf remove $NAME"
else
  echo "ERROR: RPM build failed, no .rpm found"
  exit 1
fi
