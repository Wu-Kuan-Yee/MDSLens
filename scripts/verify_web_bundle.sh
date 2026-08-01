#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

gateway="${1:-rust/target/release/mdslens-web-gateway}"
web_root="${2:-build/web}"
port="${MDSLENS_WEB_TEST_PORT:-18089}"
cookie_file="$(mktemp)"
log_file="$(mktemp)"

cleanup() {
  if [[ -n "${gateway_pid:-}" ]]; then
    kill "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
  rm -f "$cookie_file" "$log_file"
}
trap cleanup EXIT

MDSLENS_WEB_BIND="127.0.0.1:$port" \
MDSLENS_WEB_ROOT="$web_root" \
MDSLENS_WEB_SECURE_COOKIE=0 \
  "$gateway" >"$log_file" 2>&1 &
gateway_pid=$!

for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:$port/gateway/v1/health" >/dev/null; then
    break
  fi
  sleep 0.1
done

curl -fsS "http://127.0.0.1:$port/" | grep -q 'MDSLens'
curl -fsS "http://127.0.0.1:$port/startup.js" |
  grep -q "window.location.protocol === 'file:'"
session_headers="$(curl -fsS -D - -o /dev/null -c "$cookie_file" \
  "http://127.0.0.1:$port/gateway/v1/session")"
grep -qi 'HttpOnly' <<<"$session_headers"
grep -qi 'SameSite=Strict' <<<"$session_headers"
curl -fsS -b "$cookie_file" \
  "http://127.0.0.1:$port/gateway/v1/session" |
  grep -q '"authenticated":false'
test -s "$web_root/canvaskit/canvaskit.js"
test -s "$web_root/canvaskit/canvaskit.wasm"
test -f "$web_root/main.dart.wasm"
test -f "$web_root/canvaskit/skwasm.wasm"
test -f "$web_root/startup.js"

echo "Web bundle smoke test passed."
