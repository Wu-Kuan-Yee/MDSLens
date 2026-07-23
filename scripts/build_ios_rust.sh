#!/bin/sh
set -eu

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <sdk-name> <configuration> <archs> <output-library>" >&2
  exit 2
fi

SDK_NAME=$1
CONFIGURATION=$2
ARCHS=$3
OUTPUT=$4
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT_DIR/rust/Cargo.toml"
IOS_TARGET_DIR="$ROOT_DIR/rust/target/ios"
DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-13.0}

case "$CONFIGURATION" in
  Release|Profile)
    CARGO_PROFILE_FLAG=--release
    CARGO_PROFILE_DIR=release
    ;;
  *)
    CARGO_PROFILE_FLAG=
    CARGO_PROFILE_DIR=debug
    ;;
esac

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required to build the iOS native library." >&2
  exit 1
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "Xcode command-line tools are required to build for iOS." >&2
  exit 1
fi

case "$SDK_NAME" in
  iphoneos*) PLATFORM=device ;;
  iphonesimulator*) PLATFORM=simulator ;;
  *) echo "Unsupported Apple SDK: $SDK_NAME" >&2; exit 1 ;;
esac

RUSTC_BIN=$(rustup which rustc)
CARGO_BIN=$(rustup which cargo)
LIBRARIES=
for arch in $ARCHS; do
  if [ "$PLATFORM" = device ]; then
    case "$arch" in
      arm64) RUST_TARGET=aarch64-apple-ios ;;
      *) echo "Unsupported iOS device architecture: $arch" >&2; exit 1 ;;
    esac
  else
    case "$arch" in
      arm64) RUST_TARGET=aarch64-apple-ios-sim ;;
      x86_64) RUST_TARGET=x86_64-apple-ios ;;
      *) echo "Unsupported iOS simulator architecture: $arch" >&2; exit 1 ;;
    esac
  fi

  if ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
    rustup target add "$RUST_TARGET"
  fi
  # Prevent absolute Homebrew/custom package paths from leaking into the
  # archive. OpenSSL/libssh2/zlib are built as static Rust dependencies.
  # Intentional word splitting: Debug has no Cargo profile flag.
  # shellcheck disable=SC2086
  env -u CPATH -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
    -u LIBRARY_PATH -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
    -u PKG_CONFIG_PATH LIBZ_SYS_STATIC=1 RUSTC="$RUSTC_BIN" \
    CARGO_TARGET_DIR="$IOS_TARGET_DIR" \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    IPHONESIMULATOR_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    "$CARGO_BIN" rustc \
      --manifest-path "$MANIFEST" -p mds-bridge \
      --target "$RUST_TARGET" $CARGO_PROFILE_FLAG --lib -- \
      --crate-type=staticlib
  LIBRARY="$IOS_TARGET_DIR/$RUST_TARGET/$CARGO_PROFILE_DIR/libmds_bridge.a"
  LIBRARIES="$LIBRARIES $LIBRARY"
done

if [ -z "$LIBRARIES" ]; then
  echo "Xcode supplied no supported architectures." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
# lipo also handles a single archive and gives every configuration one stable
# link path, independent of whether Xcode is building a device or simulator.
# shellcheck disable=SC2086
lipo -create $LIBRARIES -output "$OUTPUT"

for symbol in mds_parse_environment mds_encode_environment mds_request_login mds_fetch_signals mds_free_string; do
  if ! nm -gU "$OUTPUT" 2>/dev/null | grep -q "_${symbol}$"; then
    echo "iOS Rust library is missing required symbol: $symbol" >&2
    exit 1
  fi
done

echo "Built iOS Rust library for $SDK_NAME ($ARCHS): $OUTPUT"
