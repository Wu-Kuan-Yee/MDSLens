#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *)
    echo "Unsupported Web Gateway build architecture: $(uname -m)" >&2
    exit 2
    ;;
esac

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *)
    echo "Unsupported Web Gateway build platform: $(uname -s)" >&2
    exit 2
    ;;
esac

version="${MDSLENS_VERSION:-}"
if [[ -z "$version" ]]; then
  version="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
  version="${version#v}"
fi
version="${version:-0.0.1}"

git_version="${MDSLENS_GIT_VERSION:-}"
if [[ -z "$git_version" ]]; then
  describe="$(git describe --tags --match 'v[0-9]*' --long --always 2>/dev/null || true)"
  if [[ "$describe" =~ ^v?([0-9][0-9.]*)-([0-9]+)-g([0-9a-f]+)$ ]]; then
    git_version="${BASH_REMATCH[1]}.r${BASH_REMATCH[2]}.g${BASH_REMATCH[3]}"
  else
    git_version="${describe:-$version}"
  fi
fi

flutter pub get
flutter build web --wasm --no-web-resources-cdn \
  --dart-define="MDSLENS_VERSION=$version" \
  --dart-define="MDSLENS_GIT_VERSION=$git_version"
cargo build --manifest-path rust/Cargo.toml \
  -p mdslens-web-gateway --release --locked

stage="build/web-package/mdslens-web-$platform-$arch"
dist="build/dist"
rm -rf "$stage"
mkdir -p "$stage"
cp rust/target/release/mdslens-web-gateway "$stage/"
cp -R build/web "$stage/web"
cp docs/WEB_DEPLOYMENT.md "$stage/README.md"
cp LICENSE "$stage/LICENSE"
cp assets/fonts/OFL.txt "$stage/NOTO_SANS_SC_LICENSE.txt"
mkdir -p "$stage/deploy"
cp -R deploy/container "$stage/deploy/container"

mkdir -p "$dist"
tar -C "$(dirname "$stage")" -czf \
  "$dist/mdslens-web-$platform-$arch.tar.gz" "$(basename "$stage")"

echo "Built $dist/mdslens-web-$platform-$arch.tar.gz"
