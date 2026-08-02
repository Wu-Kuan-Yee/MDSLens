#!/usr/bin/env bash
set -u

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <cargo-command> [arguments...]" >&2
  exit 2
fi

# Cargo downloads are an unavoidable part of a clean cross-platform build.
# A temporary registry/CDN timeout must not turn into a permanently failed
# release, so retry the complete command while preserving Cargo's partial
# downloads between attempts.
attempts="${MDSLENS_CARGO_ATTEMPTS:-5}"
if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "MDSLENS_CARGO_ATTEMPTS must be a positive integer." >&2
  exit 2
fi

status=1
for ((attempt = 1; attempt <= attempts; attempt++)); do
  echo "[MDSLens] Cargo attempt ${attempt}/${attempts}: $*"
  if env \
    CARGO_NET_RETRY="${CARGO_NET_RETRY:-10}" \
    CARGO_HTTP_TIMEOUT="${CARGO_HTTP_TIMEOUT:-120}" \
    CARGO_HTTP_MULTIPLEXING="${CARGO_HTTP_MULTIPLEXING:-false}" \
    "$@"; then
    exit 0
  else
    status=$?
  fi

  if (( attempt < attempts )); then
    delay=$((attempt * 5))
    echo "[MDSLens] Cargo failed with exit code ${status}; retrying in ${delay}s..." >&2
    sleep "$delay"
  fi
done

echo "[MDSLens] Cargo failed after ${attempts} attempts." >&2
exit "$status"
