#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <ndk-dir> <jni-output-dir> [flutter-target-platforms]" >&2
  exit 2
fi

ndk_dir="$1"
output_dir="$2"
flutter_targets="${3:-android-arm64}"
api_level="${ANDROID_API_LEVEL:-24}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  Darwin*) host_tag="darwin-x86_64" ;;
  Linux*) host_tag="linux-x86_64" ;;
  CYGWIN*|MINGW*|MSYS*) host_tag="windows-x86_64" ;;
  *) echo "Unsupported Android Rust build host: $(uname -s)" >&2; exit 1 ;;
esac

toolchain="$ndk_dir/toolchains/llvm/prebuilt/$host_tag"
if [[ ! -d "$toolchain" ]]; then
  echo "Android NDK LLVM toolchain not found: $toolchain" >&2
  exit 1
fi

if command -v rustup >/dev/null 2>&1; then
  cargo_bin="$(rustup which cargo)"
  rustc_bin="$(rustup which rustc)"
else
  cargo_bin="$(command -v cargo)"
  rustc_bin="$(command -v rustc)"
fi

build_target() {
  local rust_target="$1"
  local android_abi="$2"
  local clang_prefix="$3"
  local target_key
  target_key="$(printf '%s' "$rust_target" | tr '[:lower:]-' '[:upper:]_')"
  local cc_key
  cc_key="$(printf '%s' "$rust_target" | tr '-' '_')"
  local clang="$toolchain/bin/${clang_prefix}${api_level}-clang"
  local llvm_ar="$toolchain/bin/llvm-ar"
  local llvm_ranlib="$toolchain/bin/llvm-ranlib"

  if [[ "$host_tag" == "windows-x86_64" ]]; then
    clang="${clang}.cmd"
    llvm_ar="${llvm_ar}.exe"
    llvm_ranlib="${llvm_ranlib}.exe"
  fi
  if [[ ! -f "$clang" ]]; then
    echo "Android compiler not found: $clang" >&2
    exit 1
  fi

  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$rust_target" >/dev/null
  fi

  env \
    "PATH=$toolchain/bin:$PATH" \
    "RUSTC=$rustc_bin" \
    "CARGO_TARGET_${target_key}_LINKER=$clang" \
    "CARGO_TARGET_${target_key}_AR=$llvm_ar" \
    "CC_${cc_key}=$clang" \
    "AR_${cc_key}=$llvm_ar" \
    "RANLIB_${cc_key}=$llvm_ranlib" \
    "$cargo_bin" build \
      --manifest-path "$project_root/rust/Cargo.toml" \
      -p mds-bridge \
      --target "$rust_target" \
      --release

  local library="$project_root/rust/target/$rust_target/release/libmds_bridge.so"
  local llvm_nm="$toolchain/bin/llvm-nm"
  if [[ "$host_tag" == "windows-x86_64" ]]; then
    llvm_nm="${llvm_nm}.exe"
  fi
  local exported_symbols
  exported_symbols="$($llvm_nm -D --defined-only "$library")"
  for symbol in \
    mds_bridge_abi_version \
    mds_parse_environment \
    mds_write_environment \
    mds_encode_environment \
    mds_request_login \
    mds_fetch_shot \
    mds_fetch_shot_info \
    mds_prepare_url \
    mds_ssh_test \
    mds_fetch_signals \
    mds_fetch_signals_ssh; do
    if ! grep -q " T ${symbol}$" <<< "$exported_symbols"; then
      echo "Rust Android library is missing required symbol: $symbol" >&2
      exit 1
    fi
  done

  mkdir -p "$output_dir/$android_abi"
  cp "$library" "$output_dir/$android_abi/libmds_bridge.so"
}

built_any=false
IFS=',' read -r -a requested_targets <<< "$flutter_targets"
for flutter_target in "${requested_targets[@]}"; do
  case "$flutter_target" in
    android-arm)
      build_target "armv7-linux-androideabi" "armeabi-v7a" "armv7a-linux-androideabi"
      built_any=true
      ;;
    android-arm64)
      build_target "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android"
      built_any=true
      ;;
    android-x64)
      build_target "x86_64-linux-android" "x86_64" "x86_64-linux-android"
      built_any=true
      ;;
    android-x86)
      build_target "i686-linux-android" "x86" "i686-linux-android"
      built_any=true
      ;;
  esac
done

if [[ "$built_any" != true ]]; then
  build_target "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android"
fi
