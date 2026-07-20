#!/bin/sh
# Copy libmds_bridge.dylib into the app bundle Frameworks
DYLIB="$SRCROOT/../../rust/target/debug/libmds_bridge.dylib"
if [ -f "$DYLIB" ]; then
  mkdir -p "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
  cp "$DYLIB" "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/"
  echo "Copied libmds_bridge.dylib to Frameworks"
fi
