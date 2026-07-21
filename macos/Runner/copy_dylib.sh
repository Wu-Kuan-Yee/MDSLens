#!/bin/sh
# Copy libmds_bridge.dylib into the app bundle Frameworks
# SRCROOT may not be set in all build phases; compute base from script location
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE="$BASE/rust/target/release/libmds_bridge.dylib"
DEBUG="$BASE/rust/target/debug/libmds_bridge.dylib"
DYLIB=""
if [ "$CONFIGURATION" = "Release" ] && [ -f "$RELEASE" ]; then
  DYLIB="$RELEASE"
elif [ -f "$DEBUG" ]; then
  DYLIB="$DEBUG"
elif [ -f "$RELEASE" ]; then
  DYLIB="$RELEASE"
fi
echo "copy_dylib: SRCROOT=$SRCROOT BASE=$BASE CONFIG=$CONFIGURATION RELEASE=$RELEASE"
if [ -n "$DYLIB" ] && [ -f "$DYLIB" ]; then
  mkdir -p "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
  cp "$DYLIB" "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"
  BUNDLED="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/libmds_bridge.dylib"
  FW="@executable_path/../Frameworks"
  # Fix hardcoded dev-machine dependency paths to use relative bundle paths
  install_name_tool -id "$FW/libmds_bridge.dylib" "$BUNDLED" 2>/dev/null
  # Fix OpenSSL (may be /opt/homebrew/ on Apple Silicon or /usr/local/ on Intel)
  for lib in libssl.4.dylib libcrypto.4.dylib; do
    OLD=$(otool -L "$BUNDLED" 2>/dev/null | grep "$lib" | awk '{print $1}')
    if [ -n "$OLD" ]; then
      install_name_tool -change "$OLD" "$FW/$lib" "$BUNDLED" 2>/dev/null
      # Copy the lib from the original path if available
      if [ -f "$OLD" ]; then cp "$OLD" "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"; fi
    fi
  done
  # Fix zlib custom path
  ZLIB=$(otool -L "$BUNDLED" 2>/dev/null | grep "libz.*dylib" | grep -v "/usr/lib" | awk '{print $1}')
  if [ -n "$ZLIB" ]; then
    install_name_tool -change "$ZLIB" "$FW/libz.1.dylib" "$BUNDLED" 2>/dev/null
  fi
  echo "Copied libmds_bridge.dylib to Frameworks and fixed deps"
else
  echo "WARNING: libmds_bridge.dylib not found (tried $RELEASE $DEBUG)"
fi
