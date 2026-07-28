#!/usr/bin/env bash
set -euo pipefail

deploy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$deploy_dir"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker or Synology Container Manager is required." >&2
  exit 2
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is required." >&2
  exit 2
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created $deploy_dir/.env with safe defaults."
fi

docker compose pull
docker compose up --detach --remove-orphans

endpoint="$(docker compose port mdslens 8088 2>/dev/null || true)"
echo
echo "MDSLens is listening only on http://${endpoint:-127.0.0.1:18088}."
echo "Configure the Synology HTTPS reverse proxy before opening it in a browser."
