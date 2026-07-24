#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE=${1:-release}
OUTPUT=${2:-"$ROOT_DIR/rust/target/macos-universal/$PROFILE/libmds_bridge.dylib"}

case "$PROFILE" in
  release)
    CARGO_PROFILE_FLAG=--release
    CARGO_PROFILE_DIR=release
    ;;
  debug)
    CARGO_PROFILE_FLAG=
    CARGO_PROFILE_DIR=debug
    ;;
  *)
    echo "Unsupported Rust profile: $PROFILE" >&2
    exit 2
    ;;
esac

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required to build the macOS native library." >&2
  exit 1
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "Xcode command-line tools are required to create a universal library." >&2
  exit 1
fi

MANIFEST="$ROOT_DIR/rust/Cargo.toml"
ARM_TARGET=aarch64-apple-darwin
INTEL_TARGET=x86_64-apple-darwin
RUSTC_BIN=$(rustup which rustc)
CARGO_BIN=$(rustup which cargo)

for target in "$ARM_TARGET" "$INTEL_TARGET"; do
  if ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
  fi
  # Use rustup's matching Cargo and rustc even when a package-manager Rust is
  # earlier on PATH; otherwise rustup may report a target that rustc cannot see.
  # Intentional word splitting: the debug profile has no Cargo flag.
  # shellcheck disable=SC2086
  # Do not inherit developer-machine package search paths. zlib is built
  # statically so the app never records a Homebrew or custom absolute path.
  env -u CPATH -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
    -u LIBRARY_PATH -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
    -u PKG_CONFIG_PATH LIBZ_SYS_STATIC=1 RUSTC="$RUSTC_BIN" \
    "$CARGO_BIN" build \
    --manifest-path "$MANIFEST" -p mds-bridge \
    --target "$target" $CARGO_PROFILE_FLAG
done

mkdir -p "$(dirname "$OUTPUT")"
lipo -create \
  "$ROOT_DIR/rust/target/$ARM_TARGET/$CARGO_PROFILE_DIR/libmds_bridge.dylib" \
  "$ROOT_DIR/rust/target/$INTEL_TARGET/$CARGO_PROFILE_DIR/libmds_bridge.dylib" \
  -output "$OUTPUT"
install_name_tool -id \
  "@executable_path/../Frameworks/libmds_bridge.dylib" "$OUTPUT"

for symbol in mds_bridge_abi_version mds_parse_environment mds_encode_environment mds_fetch_signals mds_free_string; do
  if ! nm -gU "$OUTPUT" 2>/dev/null | grep -q "_${symbol}$"; then
    echo "macOS Rust library is missing required symbol: $symbol" >&2
    exit 1
  fi
done

echo "Built universal macOS Rust library: $OUTPUT"
