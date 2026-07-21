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
  echo "Copied $DYLIB to $BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"
else
  echo "WARNING: libmds_bridge.dylib not found (tried $RELEASE $DEBUG)"
fi
