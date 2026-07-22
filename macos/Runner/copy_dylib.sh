#!/bin/sh
set -eu

# Build and bundle the same architectures as Flutter's universal macOS runner.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
case "${CONFIGURATION:-Debug}" in
  Release|Profile) PROFILE=release ;;
  *) PROFILE=debug ;;
esac

DYLIB="$BASE/rust/target/macos-universal/$PROFILE/libmds_bridge.dylib"
"$BASE/scripts/build_macos_rust.sh" "$PROFILE" "$DYLIB"

DESTINATION="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
BUNDLED="$DESTINATION/libmds_bridge.dylib"
mkdir -p "$DESTINATION"
CHANGED=0
if ! cmp -s "$DYLIB" "$BUNDLED"; then
  cp "$DYLIB" "$BUNDLED"
  CHANGED=1
fi

# Vendored OpenSSL/libssh2 leaves only Apple system-library dependencies.
if otool -L "$BUNDLED" | awk '/^[[:space:]]/{print $1}' | \
    grep -Evq '^(@|/usr/lib/|/System/Library/)'; then
  echo "The bundled Rust library contains a non-system dependency:" >&2
  otool -L "$BUNDLED" >&2
  exit 1
fi

# Nested Mach-O code must be signed before Xcode seals the outer .app. Avoid
# touching an unchanged valid library so incremental builds retain a valid
# outer resource seal.
if [ "$CHANGED" -eq 1 ] || ! codesign --verify --strict "$BUNDLED" 2>/dev/null; then
  SIGN_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:--}
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=-
  fi
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLED"
fi

echo "Bundled universal libmds_bridge.dylib in $DESTINATION"
