#!/usr/bin/env bash
# MdsScope Multi-Platform Automated Package Builder
# Naming Convention: mdsscope-<platform>-<arch>.<extension>

set -e

VERSION="3.0.0"
DIST_DIR="build/dist"
mkdir -p "$DIST_DIR"

detect_os() {
  case "$(uname -s)" in
    Darwin*)  echo "macos" ;;
    Linux*)   echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686)    echo "x86" ;;
    *)            echo "x64" ;;
  esac
}

PLATFORM="$(detect_os)"
ARCH="$(detect_arch)"

echo "=== Building MdsScope Packages for $PLATFORM ($ARCH) ==="

if [ "$PLATFORM" = "macos" ]; then
  echo "--> Building macOS Release Bundle..."
  cargo build --release --manifest-path rust/mds-bridge/Cargo.toml
  flutter build macos --release

  APP_PATH="build/macos/Build/Products/Release/mdsscope.app"

  echo "--> Generating macOS Formats..."
  # 1. Portable .app
  cp -R "$APP_PATH" "$DIST_DIR/mdsscope-macos-$ARCH.app"
  
  # 2. Archives (.zip, .tar.gz, .tar.xz, .tar.bz2)
  (cd build/macos/Build/Products/Release && zip -r "../../../dist/mdsscope-macos-$ARCH.zip" mdsscope.app)
  (cd build/macos/Build/Products/Release && tar -czf "../../../dist/mdsscope-macos-$ARCH.tar.gz" mdsscope.app)
  (cd build/macos/Build/Products/Release && tar -cJf "../../../dist/mdsscope-macos-$ARCH.tar.xz" mdsscope.app)
  (cd build/macos/Build/Products/Release && tar -cjf "../../../dist/mdsscope-macos-$ARCH.tar.bz2" mdsscope.app)

  # 3. .dmg Image
  hdiutil create -volname "MdsScope" -srcfolder "$APP_PATH" -ov -format UDZO "$DIST_DIR/mdsscope-macos-$ARCH.dmg"

  # 4. .pkg Installer
  pkgbuild --component "$APP_PATH" --install-location /Applications "$DIST_DIR/mdsscope-macos-$ARCH.pkg"

elif [ "$PLATFORM" = "linux" ]; then
  echo "--> Building Linux Release Bundle..."
  cargo build --release --manifest-path rust/mds-bridge/Cargo.toml
  flutter build linux --release

  BUNDLE="build/linux/$ARCH/release/bundle"

  echo "--> Generating Linux Formats..."
  # Archives
  (cd "$BUNDLE" && tar -czf "../../../../$DIST_DIR/mdsscope-linux-$ARCH.tar.gz" *)
  (cd "$BUNDLE" && tar -cJf "../../../../$DIST_DIR/mdsscope-linux-$ARCH.tar.xz" *)
  (cd "$BUNDLE" && tar -cjf "../../../../$DIST_DIR/mdsscope-linux-$ARCH.tar.bz2" *)
  (cd "$BUNDLE" && zip -r "../../../../$DIST_DIR/mdsscope-linux-$ARCH.zip" *)

  # Arch Linux .pkg.tar.zst & .pkg.tar.xz
  (cd "$BUNDLE" && tar -c --zstd -f "../../../../$DIST_DIR/mdsscope-linux-$ARCH.pkg.tar.zst" *)
  (cd "$BUNDLE" && tar -c --xz -f "../../../../$DIST_DIR/mdsscope-linux-$ARCH.pkg.tar.xz" *)

  # .deb Package
  DEB_DIR="build/deb/mdsscope-linux-$ARCH"
  mkdir -p "$DEB_DIR/usr/bin" "$DEB_DIR/usr/lib/mdsscope" "$DEB_DIR/DEBIAN"
  cp -R "$BUNDLE/"* "$DEB_DIR/usr/lib/mdsscope/"
  ln -sf /usr/lib/mdsscope/mdsscope "$DEB_DIR/usr/bin/mdsscope"
  cat <<EOF > "$DEB_DIR/DEBIAN/control"
Package: mdsscope
Version: $VERSION
Architecture: amd64
Maintainer: MdsScope Contributors
Description: Signal data plotting for MDSplus experiments
EOF
  dpkg-deb --build "$DEB_DIR" "$DIST_DIR/mdsscope-linux-$ARCH.deb"

  # .rpm Package
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t rpm -n mdsscope -v "$VERSION" -C "$BUNDLE" -p "$DIST_DIR/mdsscope-linux-$ARCH.rpm" .
  fi
fi

echo "=== All Packages Generated Successfully in $DIST_DIR ==="
ls -lh "$DIST_DIR"
