#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="cloudflare-manager-server"
VERSION=$(grep '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | tr -d '"')
ARCH="amd64"

usage() {
  echo "Usage: $0 [deb|rpm|tarball]"
  echo "  deb     — Build .deb package"
  echo "  rpm     — Build .rpm package"
  echo "  tarball — Build .tar.gz (default)"
  exit 1
}

FORMAT="${1:-tarball}"

echo "=== Building web dashboard ==="
if [ -d "$PROJECT_DIR/web" ]; then
  cd "$PROJECT_DIR/web"
  if command -v npm &>/dev/null; then
    npm install --silent 2>/dev/null || true
    npm run build 2>/dev/null || true
  fi
  cd "$PROJECT_DIR"
fi

echo "=== Preparing server build environment ==="
SERVER_BUILD="$PROJECT_DIR/build/server_build"
rm -rf "$SERVER_BUILD"
mkdir -p "$SERVER_BUILD"

# Create minimal pubspec for AOT (no Flutter, no FFI deps)
cat > "$SERVER_BUILD/pubspec.yaml" << PUBSPEC
name: cfm_server
publish_to: none
environment:
  sdk: ^3.0.0
dependencies:
  http: ^1.0.0
  crypto: ^3.0.0
  uuid: ^4.0.0
PUBSPEC

cd "$SERVER_BUILD"
dart pub get 2>/dev/null

# Create entry point that imports the daemon
cat > "$SERVER_BUILD/main.dart" << 'DART'
import '../../lib/daemon/server_main.dart' as s;
void main(List<String> args) => s.main(args);
DART

echo "=== Compiling server binary (AOT) ==="
dart compile exe main.dart -o "$NAME" 2>&1 | grep -v "^#" | grep -v "^$" || true
if [ ! -f "$NAME" ]; then
  echo "ERROR: AOT compilation failed"
  echo "Falling back to JIT snapshot..."
  dart compile jit-snapshot main.dart -o "$NAME.jit" 2>/dev/null || true
fi

BINARY="$SERVER_BUILD/$NAME"
echo "  Binary: $BINARY ($(du -h "$BINARY" 2>/dev/null | cut -f1 || echo 'N/A'))"
cd "$PROJECT_DIR"

# Create output directory
OUTDIR="$PROJECT_DIR/build/$NAME-$VERSION"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/usr/lib/$NAME"
mkdir -p "$OUTDIR/usr/bin"
mkdir -p "$OUTDIR/usr/lib/$NAME/web/dist"

cp "$BINARY" "$OUTDIR/usr/lib/$NAME/"
if [ -d "$PROJECT_DIR/web/dist/browser" ]; then
  cp -r "$PROJECT_DIR/web/dist/browser/"* "$OUTDIR/usr/lib/$NAME/web/dist/"
fi

# Launch script
cat > "$OUTDIR/usr/bin/$NAME" << LAUNCH
#!/bin/sh
exec /usr/lib/$NAME/$NAME "\$@"
LAUNCH
chmod +x "$OUTDIR/usr/bin/$NAME"

# systemd service
mkdir -p "$OUTDIR/usr/lib/systemd/user"
cat > "$OUTDIR/usr/lib/systemd/user/$NAME.service" << SERVICE
[Unit]
Description=Cloudflare Tunnel Manager Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/$NAME/$NAME
Restart=always
RestartSec=5
Environment=HOME=%h
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE

echo "=== Building package ==="
case "$FORMAT" in
  deb)
    DEB_CONTROL="$OUTDIR/DEBIAN"
    mkdir -p "$DEB_CONTROL"
    INSTALLED_SIZE=$(du -sk "$OUTDIR/usr" | cut -f1)
    cat > "$DEB_CONTROL/control" << CONTROL
Package: $NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Recommends: cloudflared, curl
Maintainer: Cloudflare Manager
Description: Cloudflare Tunnel Manager (Server)
  Headless daemon + web dashboard for managing Cloudflare Zero Trust tunnels.
  Self-contained binary — no GUI dependencies.
  Manage via browser at http://localhost:9845 or CLI commands.
CONTROL
    DEB_FILE="$PROJECT_DIR/build/${NAME}_${VERSION}_${ARCH}.deb"
    dpkg-deb --build "$OUTDIR" "$DEB_FILE"
    echo "Done: $DEB_FILE"
    ;;
  rpm)
    RPM_BUILD_ROOT="$HOME/rpmbuild"
    rm -rf "$RPM_BUILD_ROOT"
    mkdir -p "$RPM_BUILD_ROOT/BUILD" "$RPM_BUILD_ROOT/RPMS" "$RPM_BUILD_ROOT/SPECS" "$RPM_BUILD_ROOT/SRPMS"
    cat > "$RPM_BUILD_ROOT/SPECS/$NAME.spec" << SPEC
Name:           $NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        Cloudflare Tunnel Manager (Server)
License:        MIT
URL:            https://github.com/cloudflare-manager
Recommends:     cloudflared, curl

# Disable automatic stripping — dart compile exe binary is already stripped
%global __strip /bin/true
%global __debug_install_post %{nil}

%description
Headless daemon + web dashboard for managing Cloudflare Zero Trust tunnels.
Self-contained binary — no GUI dependencies.
Manage via browser at http://localhost:9845 or CLI commands.

%install
mkdir -p %{buildroot}/usr/lib/$NAME
mkdir -p %{buildroot}/usr/bin
cp -r $OUTDIR/usr/lib/$NAME/* %{buildroot}/usr/lib/$NAME/
cp $OUTDIR/usr/bin/$NAME %{buildroot}/usr/bin/
chmod +x %{buildroot}/usr/lib/$NAME/$NAME
chmod +x %{buildroot}/usr/bin/$NAME

%files
/usr/lib/$NAME
/usr/bin/$NAME

%changelog
* $(date "+%a %b %d %Y") Cloudflare Manager Team - $VERSION-1
- Initial release
SPEC
    rpmbuild -bb "$RPM_BUILD_ROOT/SPECS/$NAME.spec" 2>&1 | tail -3
    echo "Done: $RPM_BUILD_ROOT/RPMS/$ARCH"
    ;;
  *)
    cd "$PROJECT_DIR/build"
    tar czf "$NAME-v${VERSION}.tar.gz" "$NAME-$VERSION"
    echo "Done: $PROJECT_DIR/build/$NAME-v${VERSION}.tar.gz"
    ;;
esac
