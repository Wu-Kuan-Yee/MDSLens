#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <configuration> <output-library>" >&2
  exit 2
fi

CONFIGURATION=$1
OUTPUT=$2
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "$CONFIGURATION" in
  Release|Profile|release|profile)
    CARGO_PROFILE_FLAG=--release
    CARGO_PROFILE_DIR=release
    ;;
  Debug|debug)
    CARGO_PROFILE_FLAG=
    CARGO_PROFILE_DIR=debug
    ;;
  *)
    echo "Unsupported Rust configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac

if command -v rustup >/dev/null 2>&1; then
  CARGO_BIN=$(rustup which cargo)
  RUSTC_BIN=$(rustup which rustc)
else
  CARGO_BIN=$(command -v cargo || true)
  RUSTC_BIN=$(command -v rustc || true)
fi
if [ -z "$CARGO_BIN" ] || [ -z "$RUSTC_BIN" ]; then
  echo "Cargo is required to build the Linux native library." >&2
  exit 1
fi

# OpenSSL and zlib are compiled into the bridge. This keeps the application
# independent of developer-machine package-manager paths and versions.
# Intentional word splitting: Debug has no Cargo profile flag.
# shellcheck disable=SC2086
env -u CPATH -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
  -u LIBRARY_PATH -u LD_LIBRARY_PATH -u PKG_CONFIG_PATH \
  LIBZ_SYS_STATIC=1 RUSTC="$RUSTC_BIN" "$CARGO_BIN" build \
    --manifest-path "$ROOT_DIR/rust/Cargo.toml" \
    -p mds-bridge $CARGO_PROFILE_FLAG

LIBRARY="$ROOT_DIR/rust/target/$CARGO_PROFILE_DIR/libmds_bridge.so"
if [ ! -f "$LIBRARY" ]; then
  echo "Rust build did not produce $LIBRARY" >&2
  exit 1
fi

EXPORTED_SYMBOLS=$(nm -D --defined-only "$LIBRARY")
for symbol in mds_bridge_abi_version mds_parse_environment mds_encode_environment mds_fetch_signals mds_free_string; do
  if ! printf '%s\n' "$EXPORTED_SYMBOLS" | grep -q " T ${symbol}$"; then
    echo "Linux Rust library is missing required symbol: $symbol" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUTPUT")"
cp "$LIBRARY" "$OUTPUT"
echo "Built Linux Rust library: $OUTPUT"
