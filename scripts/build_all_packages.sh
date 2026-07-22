#!/usr/bin/env bash
set -e

VERSION="7.0.0"
APP_NAME="mdsscope"
DIST_DIR="build/dist"
mkdir -p "$DIST_DIR"

log() { echo -e "\031[32m[BUILD]\031[0m $1"; }

detect_platform() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*) echo "linux" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

PLATFORM=$(detect_platform)
ARCH=$(detect_arch)
base_name="${APP_NAME}-${PLATFORM}-${ARCH}"

log "Building Rust engine static/cdylib..."
cargo build --release --manifest-path rust/mds-bridge/Cargo.toml

log "Building Flutter application for ${PLATFORM} (${ARCH})..."
flutter build ${PLATFORM} --release

case "$PLATFORM" in
  macos)
    APP_PATH="build/macos/Build/Products/Release/mdsscope.app"
    mkdir -p "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/MacOS"
    cp rust/target/release/libmds_bridge.dylib "$APP_PATH/Contents/Frameworks/" 2>/dev/null || true
    cp rust/target/release/libmds_bridge.dylib "$APP_PATH/Contents/MacOS/" 2>/dev/null || true
    
    cp -R "$APP_PATH" "$DIST_DIR/${base_name}.app"
    (cd build/macos/Build/Products/Release && zip -rq "../../../dist/${base_name}.zip" mdsscope.app)
    (cd build/macos/Build/Products/Release && tar -czf "../../../dist/${base_name}.tar.gz" mdsscope.app)
    (cd build/macos/Build/Products/Release && tar -cJf "../../../dist/${base_name}.tar.xz" mdsscope.app)
    (cd build/macos/Build/Products/Release && tar -cjf "../../../dist/${base_name}.tar.bz2" mdsscope.app)
    hdiutil create -volname "MdsScope" -srcfolder "$APP_PATH" -ov -format UDZO "$DIST_DIR/${base_name}.dmg"
    pkgbuild --component "$APP_PATH" --install-location /Applications "$DIST_DIR/${base_name}.pkg"
    ;;
  linux)
    BUNDLE="build/linux/x64/release/bundle"
    mkdir -p "$BUNDLE/lib"
    cp rust/target/release/libmds_bridge.so "$BUNDLE/lib/" 2>/dev/null || true
    cp rust/target/release/libmds_bridge.so "$BUNDLE/" 2>/dev/null || true

    (cd "$BUNDLE" && tar -czf "../../../../$DIST_DIR/${base_name}.tar.gz" *)
    (cd "$BUNDLE" && tar -cJf "../../../../$DIST_DIR/${base_name}.tar.xz" *)
    (cd "$BUNDLE" && tar -cjf "../../../../$DIST_DIR/${base_name}.tar.bz2" *)
    (cd "$BUNDLE" && zip -rq "../../../../$DIST_DIR/${base_name}.zip" *)
    (cd "$BUNDLE" && tar -c --zstd -f "../../../../$DIST_DIR/${base_name}.pkg.tar.zst" *)

    DEB_DIR="build/deb/${base_name}"
    mkdir -p "$DEB_DIR/usr/bin" "$DEB_DIR/usr/lib/mdsscope" "$DEB_DIR/DEBIAN"
    cp -R "$BUNDLE/"* "$DEB_DIR/usr/lib/mdsscope/"
    ln -sf /usr/lib/mdsscope/mdsscope "$DEB_DIR/usr/bin/mdsscope"
    cat <<EOF > "$DEB_DIR/DEBIAN/control"
Package: mdsscope
Version: ${VERSION}
Architecture: amd64
Maintainer: MdsScope Contributors
Description: Signal data plotting for MDSplus experiments
EOF
    chmod 755 "$DEB_DIR/DEBIAN" "$DEB_DIR/DEBIAN/control"
    dpkg-deb --build "$DEB_DIR" "$DIST_DIR/${base_name}.deb"
    ;;
  windows)
    BUNDLE="build/windows/x64/runner/Release"
    cp rust/target/release/mds_bridge.dll "$BUNDLE/" 2>/dev/null || true
    cp "$BUNDLE/mdsscope.exe" "$DIST_DIR/${base_name}-portable.exe"
    (cd "$BUNDLE" && zip -rq "../../../../../$DIST_DIR/${base_name}.zip" *)
    ;;
esac

log "Build complete! Packages saved in $DIST_DIR"
