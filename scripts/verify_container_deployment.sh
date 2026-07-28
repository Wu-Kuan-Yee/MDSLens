#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="${1:-$repo_root/build/web-package/mdslens-web-linux-x64}"
image="mdslens-web-gateway:test"
container="mdslens-web-gateway-test-$$"
port="${MDSLENS_CONTAINER_TEST_PORT:-18089}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
  --file "$repo_root/deploy/container/Dockerfile" \
  --tag "$image" \
  "$package_dir"

docker run --detach \
  --name "$container" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --publish "127.0.0.1:$port:8088" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if curl --fail --silent --show-error \
    "http://127.0.0.1:$port/gateway/v1/health" >/dev/null; then
    echo "Container deployment verified."
    exit 0
  fi
  sleep 1
done

docker logs "$container"
exit 1
