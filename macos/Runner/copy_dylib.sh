#!/bin/sh
# Copy libmds_bridge.dylib into the app bundle Frameworks
RELEASE="$SRCROOT/../../rust/target/release/libmds_bridge.dylib"
DEBUG="$SRCROOT/../../rust/target/debug/libmds_bridge.dylib"
DYLIB=""
if [ "$CONFIGURATION" = "Release" ] && [ -f "$RELEASE" ]; then
  DYLIB="$RELEASE"
elif [ -f "$DEBUG" ]; then
  DYLIB="$DEBUG"
elif [ -f "$RELEASE" ]; then
  DYLIB="$RELEASE"
fi
if [ -n "$DYLIB" ] && [ -f "$DYLIB" ]; then
  mkdir -p "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
  cp "$DYLIB" "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"
  echo "Copied $DYLIB to Frameworks"
else
  echo "WARNING: libmds_bridge.dylib not found (debug or release)"
fi
